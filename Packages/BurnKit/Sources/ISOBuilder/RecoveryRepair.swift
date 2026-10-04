import CryptoKit
import Foundation

/// What a repair found and did. Paths are from the disc's root.
public struct RepairReport: Sendable, Equatable {
    /// Files that were already intact, and were copied as they are.
    public var intact: [String] = []
    /// Files rebuilt from the recovery data.
    public var repaired: [String] = []
    /// Files that couldn't be rebuilt, because the damage is more than the recovery data covers.
    public var unrepairable: [String] = []
    public var damagedSlices = 0
    public var recoverySlices = 0

    public var isComplete: Bool { unrepairable.isEmpty }
}

public enum RecoveryRepairError: Error, Sendable, Equatable, CustomStringConvertible {
    case noRecoveryData
    case unsafeName(String)

    public var description: String {
        switch self {
        case .noRecoveryData: return "This disc has no readable PAR2 recovery data in its \(DiscChecksums.folderName) folder."
        case .unsafeName(let name): return "The recovery data names a file outside the disc: \(name)"
        }
    }
}

/// Repairs a disc's files from the PAR2 recovery data in its `.burn` folder (decision D15).
///
/// The disc is only read. Every file is copied into another folder, those it protects slice by slice;
/// slices that fail their checksum, can't be read or are missing are rebuilt from the recovery
/// slices. The `.burn` folder is copied too, so the copy can be checked and repaired again.
public enum RecoveryRepair {
    /// True when `root` has PAR2 files in its `.burn` folder.
    public static func hasRecovery(at root: URL) -> Bool {
        !par2Files(root).isEmpty
    }

    /// Reads the disc, and writes every protected file, repaired where it can be, under
    /// `destination`. Blocks until done, so call it off the main thread. Throws
    /// `CancellationError` if the calling task is cancelled.
    public static func repair(root: URL, into destination: URL,
                              progress: @Sendable (Double) -> Void = { _ in }) throws -> RepairReport {
        let set = try RecoverySet(files: par2Files(root))
        var report = RepairReport(recoverySlices: set.recovery.count)
        let onDisc = ChecksumVerifier.filesOnDisc(root)
        let sliceSize = set.sliceSize
        let logs = GF16.inputLogs(count: set.files.reduce(0) { $0 + $1.sliceCount })
        let work = Double(max(1, set.files.reduce(0) { $0 + $1.length })) * 2
        var done = 0.0

        // Copy each file slice by slice, keeping the slices that match their checksums.
        var damaged: [(file: Int, slice: Int)] = []
        var firstSlices: [Int] = []
        var outputs: [URL] = []
        for (number, file) in set.files.enumerated() {
            try Task.checkCancellation()
            let output = destination.appendingPathComponent(file.name)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                throw ISOBuilderError.unreadable(output.path)
            }
            outputs.append(output)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            let reader = onDisc[file.name.precomposedStringWithCanonicalMapping].flatMap { try? FileHandle(forReadingFrom: $0.url) }
            defer { try? reader?.close() }
            for slice in 0..<file.sliceCount {
                let offset = UInt64(slice) * UInt64(sliceSize)
                let count = Int(min(UInt64(sliceSize), file.length - offset))
                // A slice that can't be read counts as damaged, like one that fails its checksum.
                var data: [UInt8]?
                if let reader {
                    do {
                        try reader.seek(toOffset: offset)
                        data = try reader.read(upToCount: count).map { [UInt8]($0) }
                    } catch {
                        data = nil
                    }
                }
                if let bytes = data, bytes.count == count,
                   PAR2.md5((bytes + [UInt8](repeating: 0, count: sliceSize - count))[...]) == file.sliceMD5s[slice] {
                    try writer.seek(toOffset: offset)
                    try writer.write(contentsOf: Data(bytes))
                } else {
                    damaged.append((number, slice))
                }
                done += Double(count)
                progress(done / work)
            }
            try writer.truncate(atOffset: file.length)
            firstSlices.append((firstSlices.last ?? 0) + (number == 0 ? 0 : set.files[number - 1].sliceCount))
        }
        report.damagedSlices = damaged.count
        let damagedFiles = Set(damaged.map(\.file))
        report.intact = set.files.indices.filter { !damagedFiles.contains($0) }.map { set.files[$0].name }
        try copyBurnFolder(root, into: destination)
        // Files the recovery data doesn't cover, such as empty ones, are copied as they are.
        let protected = Set(set.files.map { $0.name.precomposedStringWithCanonicalMapping })
        for (path, entry) in onDisc where !protected.contains(path) {
            let target = destination.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: entry.url, to: target)
        }

        guard !damaged.isEmpty else {
            progress(1)
            return report
        }
        guard damaged.count <= set.recovery.count else {
            report.unrepairable = damagedFiles.sorted().map { set.files[$0].name }
            return report
        }

        // The recovery slices hold every input slice; take away the good ones to leave the damaged.
        let chosen = Array(set.recovery.keys.sorted().prefix(damaged.count))
        let damagedSet = Set(damaged.map { firstSlices[$0.file] + $0.slice })
        let known = PAR2Encoder(sliceSize: sliceSize, exponents: chosen)
        for (number, file) in set.files.enumerated() {
            try Task.checkCancellation()
            let reader = try FileHandle(forReadingFrom: outputs[number])
            defer { try? reader.close() }
            for slice in 0..<file.sliceCount where !damagedSet.contains(firstSlices[number] + slice) {
                try reader.seek(toOffset: UInt64(slice) * UInt64(sliceSize))
                let bytes = [UInt8](try reader.read(upToCount: sliceSize) ?? Data())
                bytes.withUnsafeBytes { known.add($0, inputLog: logs[firstSlices[number] + slice]) }
                done += Double(bytes.count)
                progress(done / work)
            }
        }
        var remainders: [[UInt8]] = []
        for exponent in chosen {
            let recovery = try set.recoveryData(exponent: exponent)
            remainders.append(zip(recovery, known.slice(exponent: exponent)).map { $0 ^ $1 })
        }

        // remainder[j] = Σ over damaged slices k of coefficient(k, exponent j) × slice k. Invert that.
        let matrix = chosen.map { exponent in
            damaged.map { GF16.coefficient(inputLog: logs[firstSlices[$0.file] + $0.slice], exponent: exponent) }
        }
        guard let inverse = GF16.invert(matrix) else {
            report.unrepairable = damagedFiles.sorted().map { set.files[$0].name }
            return report
        }
        for (k, place) in damaged.enumerated() {
            var words = [UInt16](repeating: 0, count: sliceSize / 2)
            words.withUnsafeMutableBufferPointer { destination in
                for (j, remainder) in remainders.enumerated() {
                    remainder.withUnsafeBytes { GF16.multiplyAdd(inverse[k][j], $0, into: destination) }
                }
            }
            let file = set.files[place.file]
            let offset = UInt64(place.slice) * UInt64(sliceSize)
            let count = Int(min(UInt64(sliceSize), file.length - offset))
            let bytes = words.withUnsafeBytes { Array($0.prefix(count)) }
            let writer = try FileHandle(forWritingTo: outputs[place.file])
            try writer.seek(toOffset: offset)
            try writer.write(contentsOf: Data(bytes))
            try writer.close()
        }

        // Check each rebuilt file against the MD5 the recovery data recorded for it.
        for number in damagedFiles.sorted() {
            let file = set.files[number]
            if try md5(of: outputs[number]) == file.md5 {
                report.repaired.append(file.name)
            } else {
                report.unrepairable.append(file.name)
            }
        }
        progress(1)
        return report
    }

    // MARK: - Helpers

    static func par2Files(_ root: URL) -> [URL] {
        let folder = root.appendingPathComponent(DiscChecksums.folderName)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".par2") }.sorted().map { folder.appendingPathComponent($0) }
    }

    private static func copyBurnFolder(_ root: URL, into destination: URL) throws {
        let source = root.appendingPathComponent(DiscChecksums.folderName)
        let target = destination.appendingPathComponent(DiscChecksums.folderName)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? [] {
            let to = target.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: source.appendingPathComponent(name), to: to)
        }
    }

    private static func md5(of url: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Array(hasher.finalize())
    }
}

/// The packets of one PAR2 recovery set, read from its files. Packets that fail their MD5 are
/// skipped, so a damaged recovery file still gives up what it can.
struct RecoverySet {
    struct File {
        let id: [UInt8]
        let name: String
        let length: UInt64
        let md5: [UInt8]
        let sliceMD5s: [[UInt8]]
        let sliceCount: Int
    }

    let sliceSize: Int
    /// In the main packet's order, which numbers the input slices.
    let files: [File]
    /// Where each recovery slice's data is, by exponent.
    let recovery: [Int: (url: URL, offset: UInt64)]

    init(files urls: [URL]) throws {
        var descriptions: [[UInt8]: [UInt8]] = [:]
        var checksums: [[UInt8]: [UInt8]] = [:]
        var recovery: [Int: (url: URL, offset: UInt64)] = [:]
        var packets: [(setID: [UInt8], type: [UInt8], body: [UInt8], url: URL, offset: UInt64)] = []
        for url in urls {
            packets += Self.packets(in: url)
        }
        guard let mainPacket = packets.first(where: { $0.type == PAR2.mainType }), mainPacket.body.count >= 12 else {
            throw RecoveryRepairError.noRecoveryData
        }
        let main = (setID: mainPacket.setID, body: mainPacket.body)
        for packet in packets where packet.setID == main.setID {
            switch packet.type {
            case PAR2.fileDescriptionType:
                if packet.body.count >= 56 { descriptions[Array(packet.body[0..<16])] = packet.body }
            case PAR2.sliceChecksumType:
                if packet.body.count >= 16 { checksums[Array(packet.body[0..<16])] = packet.body }
            case PAR2.recoverySliceType:
                let body = packet.body
                if body.count >= 4 {
                    let exponent = Int(UInt32(body[0]) | UInt32(body[1]) << 8 | UInt32(body[2]) << 16 | UInt32(body[3]) << 24)
                    recovery[exponent] = (packet.url, packet.offset + UInt64(PAR2.headerSize) + 4)
                }
            default:
                break
            }
        }

        var sliceSize = 0
        for index in 0..<8 { sliceSize |= Int(main.body[index]) << (8 * index) }
        let count = Int(UInt32(main.body[8]) | UInt32(main.body[9]) << 8 | UInt32(main.body[10]) << 16 | UInt32(main.body[11]) << 24)
        guard sliceSize > 0, sliceSize % 4 == 0, main.body.count >= 12 + 16 * count else {
            throw RecoveryRepairError.noRecoveryData
        }
        var files: [File] = []
        for index in 0..<count {
            let id = Array(main.body[(12 + 16 * index)..<(28 + 16 * index)])
            guard let description = descriptions[id], let sums = checksums[id] else { throw RecoveryRepairError.noRecoveryData }
            var length: UInt64 = 0
            for byte in 0..<8 { length |= UInt64(description[48 + byte]) << (8 * UInt64(byte)) }
            let name = String(decoding: description[56...].prefix { $0 != 0 }, as: UTF8.self)
            let parts = name.split(separator: "/")
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else { throw RecoveryRepairError.unsafeName(name) }
            let sliceCount = PAR2.sliceCount(length, sliceSize: sliceSize)
            guard sums.count >= 16 + 20 * sliceCount else { throw RecoveryRepairError.noRecoveryData }
            files.append(File(id: id, name: name, length: length, md5: Array(description[16..<32]),
                              sliceMD5s: (0..<sliceCount).map { Array(sums[(16 + 20 * $0)..<(32 + 20 * $0)]) },
                              sliceCount: sliceCount))
        }
        self.sliceSize = sliceSize
        self.files = files
        self.recovery = recovery
    }

    func recoveryData(exponent: Int) throws -> [UInt8] {
        guard let place = recovery[exponent] else { throw RecoveryRepairError.noRecoveryData }
        let handle = try FileHandle(forReadingFrom: place.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: place.offset)
        let bytes = [UInt8](try handle.read(upToCount: sliceSize) ?? Data())
        guard bytes.count == sliceSize else { throw RecoveryRepairError.noRecoveryData }
        return bytes
    }

    /// Every packet in a file whose MD5 checks out. Of a recovery slice, only its exponent is kept,
    /// and where it is. After a bad packet, the search goes on four bytes at a time.
    static func packets(in url: URL) -> [(setID: [UInt8], type: [UInt8], body: [UInt8], url: URL, offset: UInt64)] {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else { return [] }
        defer { try? handle.close() }
        var result: [(setID: [UInt8], type: [UInt8], body: [UInt8], url: URL, offset: UInt64)] = []
        var offset: UInt64 = 0
        while offset + UInt64(PAR2.headerSize) <= size {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: PAR2.headerSize), data.count == PAR2.headerSize,
                  Array(data.prefix(8)) == PAR2.magic else {
                offset += 4
                continue
            }
            let header = [UInt8](data)
            var length: UInt64 = 0
            for index in 0..<8 { length |= UInt64(header[8 + index]) << (8 * UInt64(index)) }
            guard length >= UInt64(PAR2.headerSize), length % 4 == 0, offset + length <= size else {
                offset += 4
                continue
            }
            // Check the MD5 while reading, so large recovery slices needn't be held.
            var hasher = Insecure.MD5()
            hasher.update(data: header[32...])
            let type = Array(header[48..<64])
            let keepBody = type != PAR2.recoverySliceType
            var body: [UInt8] = []
            var remaining = length - UInt64(PAR2.headerSize)
            var readable = true
            while remaining > 0 {
                guard let chunk = try? handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
                    readable = false
                    break
                }
                hasher.update(data: chunk)
                if keepBody {
                    body += chunk
                } else if body.count < 4 {
                    body += chunk.prefix(4 - body.count) // a recovery slice's exponent
                }
                remaining -= UInt64(chunk.count)
            }
            guard readable, Array(hasher.finalize()) == Array(header[16..<32]) else {
                offset += 4
                continue
            }
            result.append((Array(header[32..<48]), type, body, url, offset))
            offset += length
        }
        return result
    }
}

extension GF16 {
    /// The inverse of a square matrix, by Gauss-Jordan elimination, or nil if it has none.
    static func invert(_ matrix: [[UInt16]]) -> [[UInt16]]? {
        let size = matrix.count
        var left = matrix
        var right = (0..<size).map { row in (0..<size).map { $0 == row ? UInt16(1) : 0 } }
        for column in 0..<size {
            guard let pivot = (column..<size).first(where: { left[$0][column] != 0 }) else { return nil }
            left.swapAt(column, pivot)
            right.swapAt(column, pivot)
            let scale = divide(1, left[column][column])
            for index in 0..<size {
                left[column][index] = multiply(left[column][index], scale)
                right[column][index] = multiply(right[column][index], scale)
            }
            for row in 0..<size where row != column && left[row][column] != 0 {
                let factor = left[row][column]
                for index in 0..<size {
                    left[row][index] ^= multiply(factor, left[column][index])
                    right[row][index] ^= multiply(factor, right[column][index])
                }
            }
        }
        return right
    }
}

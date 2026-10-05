import CryptoKit
import Foundation
import MMC
import Synchronization

/// A disc image made on demand, block by block, from its layout and the files it lists. Nothing
/// is written to disk first, so a 100 GB Blu-ray needs no 100 GB of free space (decision D14).
///
/// Any block can be read at any time, in any order, and reads the same each time, so a burn can
/// write the image and then read it again to verify the disc. Files are hashed as the image is
/// read in order, and `.burn/SHA256SUMS` comes last, once every file has been read. A file that
/// was skipped is hashed on its own when the list is made.
///
/// PAR2 recovery data needs every file read first, so an image with it must be prepared before
/// the burn: `prepare(progress:)` reads the files, hashes them, and keeps the recovery data in a
/// temporary file of about a tenth of their size. Reading the recovery data prepares the image
/// if that hasn't been done.
///
/// Reads are serialised with a lock, so it can be shared between threads.
public final class DiscImage: @unchecked Sendable {
    public let blockCount: Int
    /// Most memory used for recovery slices at once. More recovery data than this takes several
    /// passes over the files.
    var recoveryMemory = 512 << 20

    private enum Content {
        case zeros
        /// Structures made in one piece, such as a folder's records.
        case bytes(() -> [UInt8])
        /// One UDF File Entry per block, for `udfNodes` from `first`.
        case fileEntries(first: Int)
        case file(Node)
        case generated(Node)
    }

    private struct Region {
        let start: Int
        let blocks: Int
        let content: Content
    }

    private let layout: Layout
    private var regions: [Region] = []
    private let lock = NSLock()

    // Guarded by `lock`.
    private var cached: (index: Int, bytes: [UInt8])?
    private var openFile: (node: Node, handle: FileHandle)?
    private var hashing: (node: Node, hasher: SHA256, position: UInt64)?
    private var digests: [String: String] = [:]
    private var checksums: [UInt8]?
    private var recovery: (index: [UInt8], volume: URL)?
    private let cancelled = Atomic<Bool>(false)

    init(layout: Layout, volumeName: String, date: Date) {
        self.layout = layout
        blockCount = layout.totalBlocks
        let stamp = Timestamp(date)

        var next = 0
        func add(_ start: Int, _ blocks: Int, _ content: Content) {
            precondition(start >= next, "Image regions overlap at block \(start)")
            if start > next { regions.append(Region(start: next, blocks: start - next, content: .zeros)) }
            if blocks > 0 { regions.append(Region(start: start, blocks: blocks, content: content)) }
            next = start + blocks
        }
        func blocks(_ bytes: Int) -> Int { (bytes + sectorSize - 1) / sectorSize }

        add(16, 3, .bytes { layout.isoDescriptors(volumeName: volumeName, stamp: stamp) })
        if layout.includesUDF {
            add(Int(UDF.volumeRecognition), 3, .bytes { UDF.recognitionSequence() })
            add(Int(UDF.mainSequence), Int(UDF.sequenceBlocks), .bytes {
                layout.udfVolumeSequence(start: UDF.mainSequence, volumeName: volumeName, stamp: stamp)
            })
            add(Int(UDF.reserveSequence), Int(UDF.sequenceBlocks), .bytes {
                layout.udfVolumeSequence(start: UDF.reserveSequence, volumeName: volumeName, stamp: stamp)
            })
            add(Int(UDF.integritySequence), 2, .bytes { layout.udfIntegritySequence(stamp: stamp) })
            add(Int(UDF.anchor), 1, .bytes { layout.udfAnchor(location: UDF.anchor) })
            add(Int(UDF.partitionStart), 2, .bytes { layout.udfFileSet(volumeName: volumeName, stamp: stamp) })
            // File Entries in runs of 512, so a disc of many files isn't one huge region.
            var first = 0
            while first < layout.udfNodes.count {
                let count = min(512, layout.udfNodes.count - first)
                add(Int(UDF.partitionStart + layout.udfNodes[first].udfEntry), count, .fileEntries(first: first))
                first += count
            }
            for directory in layout.udfNodes where directory.isDirectory {
                add(Int(UDF.partitionStart + directory.udfDirectoryBlock), blocks(directory.udfDirectorySize), .bytes {
                    layout.udfDirectoryContents(directory)
                })
            }
        }
        let tableBlocks = (iso: blocks(layout.isoPathTableSize), joliet: blocks(layout.jolietPathTableSize))
        add(Int(layout.isoPathTableL), tableBlocks.iso, .bytes { layout.pathTable(joliet: false, bigEndian: false) })
        add(Int(layout.isoPathTableM), tableBlocks.iso, .bytes { layout.pathTable(joliet: false, bigEndian: true) })
        add(Int(layout.jolietPathTableL), tableBlocks.joliet, .bytes { layout.pathTable(joliet: true, bigEndian: false) })
        add(Int(layout.jolietPathTableM), tableBlocks.joliet, .bytes { layout.pathTable(joliet: true, bigEndian: true) })
        for directory in layout.isoDirectories {
            add(Int(directory.isoExtent), blocks(directory.isoSize), .bytes {
                layout.directoryContents(directory, joliet: false)
            })
        }
        for directory in layout.jolietDirectories {
            add(Int(directory.jolietExtent), blocks(directory.jolietSize), .bytes {
                layout.directoryContents(directory, joliet: true)
            })
        }
        for file in layout.files {
            add(Int(file.fileExtent), blocks(Int(file.size)), file.generated == nil ? .file(file) : .generated(file))
        }
        precondition(next == Int(layout.dataEnd), "Image layout out of step at block \(next)")
        if layout.includesUDF {
            add(blockCount - 1, 1, .bytes { layout.udfAnchor(location: UInt32(layout.totalBlocks - 1)) })
        } else {
            add(blockCount, 0, .zeros)
        }
    }

    deinit {
        try? openFile?.handle.close()
        if let recovery { try? FileManager.default.removeItem(at: recovery.volume) }
    }

    /// True when the image has recovery data still to make.
    public var needsPreparing: Bool {
        lock.withLock { layout.recovery != nil && recovery == nil }
    }

    /// Reads every file to hash it and make the recovery data, reporting the fraction done.
    /// Blocks until done, so call it off the main thread. Does nothing without recovery data.
    public func prepare(progress: ((Double) -> Void)? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareLocked(progress: progress)
    }

    /// Stops `prepare(progress:)`, which then throws `CancellationError`.
    public func cancelPreparing() {
        cancelled.store(true, ordering: .relaxed)
    }

    /// Reads `count` blocks from `block`: exactly `count * 2048` bytes.
    public func read(block: Int, count: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        precondition(block >= 0 && count >= 0 && block + count <= blockCount, "Read past the end of the image")
        var result: [UInt8] = []
        result.reserveCapacity(count * sectorSize)
        var current = block
        var index = regionIndex(containing: block)
        while current < block + count {
            let region = regions[index]
            let from = current - region.start
            let upTo = min(block + count, region.start + region.blocks) - region.start
            result += try bytes(of: region, index: index, blocks: from..<upTo)
            current = region.start + upTo
            index += 1
        }
        return result
    }

    /// What a block holds, for the log: a file and the byte offset in it, or a structure's name.
    public func describe(block: Int) -> String? {
        guard block >= 0, block < blockCount else { return nil }
        let region = lock.withLock { regions[regionIndex(containing: block)] }
        let offset = (block - region.start) * sectorSize
        switch region.content {
        case .zeros: return "padding"
        case .bytes: return "disc structures (blocks \(region.start) to \(region.start + region.blocks - 1))"
        case .fileEntries: return "UDF file entries"
        case .file(let node), .generated(let node):
            return "\(layout.discPath(node)) from byte \(offset) of \(node.size)"
        }
    }

    /// Writes the whole image to a file, reporting the fraction done.
    func write(to url: URL, progress: ((Double) -> Void)?) throws {
        try prepare()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ISOBuilderError.unreadable(url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = 0
        while block < blockCount {
            let count = min(512, blockCount - block)
            try handle.writeBytes(read(block: block, count: count))
            block += count
            progress?(Double(block) / Double(max(1, blockCount)))
        }
    }

    // MARK: - Regions

    private func regionIndex(containing block: Int) -> Int {
        var low = 0
        var high = regions.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if regions[middle].start <= block { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func bytes(of region: Region, index: Int, blocks: Range<Int>) throws -> [UInt8] {
        let length = blocks.count * sectorSize
        switch region.content {
        case .zeros:
            return [UInt8](repeating: 0, count: length)
        case .bytes(let make):
            if cached?.index != index { cached = (index, padded(make(), blocks: region.blocks)) }
            return slice(cached?.bytes ?? [], blocks)
        case .fileEntries(let first):
            return blocks.flatMap { layout.udfFileEntry(layout.udfNodes[first + $0]) }
        case .generated(let node):
            if case .recoveryVolume? = node.generated {
                return try readRecoveryVolume(node, offset: UInt64(blocks.lowerBound * sectorSize), length: length)
            }
            return try slice(padded(generatedContent(node), blocks: region.blocks), blocks)
        case .file(let node):
            let offset = UInt64(blocks.lowerBound * sectorSize)
            let wanted = Int(min(UInt64(length), node.size - offset))
            var data = try readFile(node, offset: offset, length: wanted)
            data += [UInt8](repeating: 0, count: length - data.count)
            return data
        }
    }

    private func padded(_ bytes: [UInt8], blocks: Int) -> [UInt8] {
        precondition(bytes.count <= blocks * sectorSize, "A structure outgrew its place in the image")
        return bytes + [UInt8](repeating: 0, count: blocks * sectorSize - bytes.count)
    }

    private func slice(_ bytes: [UInt8], _ blocks: Range<Int>) -> [UInt8] {
        Array(bytes[(blocks.lowerBound * sectorSize)..<(blocks.upperBound * sectorSize)])
    }

    // MARK: - Files

    private func readFile(_ node: Node, offset: UInt64, length: Int) throws -> [UInt8] {
        guard let source = node.source else { throw ISOBuilderError.notFound(node.name) }
        let handle = try self.handle(for: node)
        try handle.seek(toOffset: node.sourceOffset + offset)
        let data = try handle.readBytes(length)
        guard data.count == length else { throw ISOBuilderError.changedWhileWriting(source.path) }

        // Hash the file when it's read in order from the start, as a burn does.
        guard layout.checksumsNode != nil else { return data }
        if offset == 0 { hashing = (node, SHA256(), 0) }
        if var state = hashing, state.node === node, state.position == offset {
            state.hasher.update(data: data)
            state.position += UInt64(length)
            hashing = state
            if state.position == node.size {
                // A part ends inside its file, so only a whole file must end where it did.
                if node.partOf == nil, try !handle.readBytes(1).isEmpty {
                    throw ISOBuilderError.changedWhileWriting(source.path)
                }
                // A file that changed since the image was prepared no longer matches its checksum.
                let digest = DiscChecksums.hex(state.hasher.finalize())
                let path = layout.discPath(node)
                if let earlier = digests[path], earlier != digest {
                    throw ISOBuilderError.changedWhileWriting(source.path)
                }
                digests[path] = digest
                hashing = nil
            }
        }
        return data
    }

    private func handle(for node: Node) throws -> FileHandle {
        if let openFile, openFile.node === node { return openFile.handle }
        try? openFile?.handle.close()
        openFile = nil
        guard let source = node.source, let handle = try? FileHandle(forReadingFrom: source) else {
            throw ISOBuilderError.unreadable(node.source?.path ?? node.name)
        }
        openFile = (node, handle)
        return handle
    }

    private func generatedContent(_ node: Node) throws -> [UInt8] {
        let content: [UInt8]
        switch node.generated {
        case .checksums?:
            if let checksums { return checksums }
            for file in layout.files where file.generated == nil && digests[layout.discPath(file)] == nil {
                digests[layout.discPath(file)] = try hashWhole(file)
            }
            content = Array(DiscChecksums.render(digests).utf8)
            checksums = content
        case .content(let bytes)?:
            content = bytes
        case .recoveryIndex?:
            try prepareLocked(progress: nil)
            content = recovery?.index ?? []
        case .recoveryVolume?, nil:
            content = []
        }
        precondition(content.count == Int(node.size), "Generated file \(node.name) changed size")
        return content
    }

    /// Hashes a file the image hasn't read in order, such as when a burn starts partway through.
    private func hashWhole(_ node: Node) throws -> String {
        guard let source = node.source else { throw ISOBuilderError.notFound(node.name) }
        let handle = try self.handle(for: node)
        try handle.seek(toOffset: node.sourceOffset)
        var hasher = SHA256()
        var remaining = node.size
        while remaining > 0 {
            let chunk = try handle.readBytes(Int(min(remaining, 1024 * 1024)))
            if chunk.isEmpty { throw ISOBuilderError.changedWhileWriting(source.path) }
            hasher.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        if node.partOf == nil, try !handle.readBytes(1).isEmpty {
            throw ISOBuilderError.changedWhileWriting(source.path)
        }
        return DiscChecksums.hex(hasher.finalize())
    }
}

// MARK: - Recovery data (decision D15)

private extension DiscImage {
    /// Makes the PAR2 packets and recovery slices. The caller holds the lock.
    func prepareLocked(progress: ((Double) -> Void)?) throws {
        guard let plan = layout.recovery, recovery == nil else { return }
        let files = layout.recoveryFiles
        let sliceSize = plan.sliceSize
        let changed = { (file: Node) in ISOBuilderError.changedWhileWriting(file.source?.path ?? file.name) }

        // Each file's ID comes from its first 16 KB, its length and its name. The main packet
        // lists the IDs in order, and input slices are numbered in that order.
        var ids: [[UInt8]] = []
        var first16K: [[UInt8]] = []
        var names: [[UInt8]] = []
        for file in files {
            let handle = try self.handle(for: file)
            try handle.seek(toOffset: file.sourceOffset)
            let head = try handle.readBytes(16384)
            guard head.count == Int(min(16384, file.size)) else { throw changed(file) }
            let name = Array(layout.discPath(file).utf8)
            let hash = PAR2.md5(head[...])
            first16K.append(hash)
            names.append(name)
            ids.append(PAR2.fileID(md5First16K: hash, length: file.size, name: name))
        }
        let order = files.indices.sorted { PAR2.idOrder(ids[$0], ids[$1]) }
        var firstSlice = [Int](repeating: 0, count: files.count)
        var sliceTotal = 0
        for index in order {
            firstSlice[index] = sliceTotal
            sliceTotal += PAR2.sliceCount(files[index].size, sliceSize: sliceSize)
        }
        let logs = GF16.inputLogs(count: sliceTotal)
        let setID = PAR2.md5(PAR2.mainBody(sliceSize: sliceSize, fileIDs: order.map { ids[$0] })[...])

        let volume = FileManager.default.temporaryDirectory.appendingPathComponent("Burn-\(UUID().uuidString).par2")
        guard FileManager.default.createFile(atPath: volume.path, contents: nil) else {
            throw ISOBuilderError.unreadable(volume.path)
        }
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: volume) } }
        let output = try FileHandle(forWritingTo: volume)
        defer { try? output.close() }

        // As many recovery slices as fit in memory at once; each batch reads the files again.
        let perBatch = max(1, recoveryMemory / sliceSize)
        let batches = stride(from: 0, to: plan.recoveryCount, by: perBatch).map {
            $0..<min($0 + perBatch, plan.recoveryCount)
        }
        let work = Double(max(1, files.reduce(0) { $0 + $1.size })) * Double(batches.count)
        var done = 0.0
        var md5s = [[UInt8]](repeating: [], count: files.count)
        var sliceSums = [[UInt8]](repeating: [], count: files.count)
        var index: [UInt8] = []

        for (pass, batch) in batches.enumerated() {
            let encoder = PAR2Encoder(sliceSize: sliceSize, exponents: Array(batch))
            for (number, file) in files.enumerated() {
                let handle = try self.handle(for: file)
                try handle.seek(toOffset: file.sourceOffset)
                var sha = SHA256()
                var md5 = Insecure.MD5()
                var sums: [UInt8] = []
                var remaining = file.size
                var slice = 0
                while remaining > 0 {
                    if cancelled.load(ordering: .relaxed) { throw CancellationError() }
                    let count = Int(min(remaining, UInt64(sliceSize)))
                    let chunk = try handle.readBytes(count)
                    guard chunk.count == count else { throw changed(file) }
                    chunk.withUnsafeBytes { encoder.add($0, inputLog: logs[firstSlice[number] + slice]) }
                    if pass == 0 {
                        sha.update(data: chunk)
                        md5.update(data: chunk)
                        // Slice checksums cover the last slice padded with zeros.
                        let padded = chunk + [UInt8](repeating: 0, count: sliceSize - count)
                        sums += PAR2.md5(padded[...]) + PAR2.le32(padded.withUnsafeBytes { PAR2.crc32($0) })
                    }
                    remaining -= UInt64(count)
                    slice += 1
                    done += Double(count)
                    progress?(done / work)
                }
                if pass == 0 {
                    if file.partOf == nil, try !handle.readBytes(1).isEmpty { throw changed(file) }
                    digests[layout.discPath(file)] = DiscChecksums.hex(sha.finalize())
                    md5s[number] = Array(md5.finalize())
                    sliceSums[number] = sums
                }
            }
            if pass == 0 {
                index = PAR2.packet(type: PAR2.mainType, setID: setID,
                                    body: PAR2.mainBody(sliceSize: sliceSize, fileIDs: order.map { ids[$0] }))
                index += PAR2.packet(type: PAR2.creatorType, setID: setID, body: PAR2.creatorBody())
                for number in order {
                    index += PAR2.packet(type: PAR2.fileDescriptionType, setID: setID, body: PAR2.fileDescriptionBody(
                        fileID: ids[number], md5: md5s[number], md5First16K: first16K[number],
                        length: files[number].size, name: names[number]))
                    index += PAR2.packet(type: PAR2.sliceChecksumType, setID: setID, body: ids[number] + sliceSums[number])
                }
                precondition(index.count == layout.recoveryCriticalSize, "PAR2 packets changed size")
                try output.writeBytes(index)
            }
            for exponent in batch {
                let packet = PAR2.packet(type: PAR2.recoverySliceType, setID: setID,
                                         body: PAR2.le32(UInt32(exponent)) + encoder.slice(exponent: exponent))
                try output.writeBytes(packet)
            }
        }
        finished = true
        recovery = (index, volume)
    }

    func readRecoveryVolume(_ node: Node, offset: UInt64, length: Int) throws -> [UInt8] {
        try prepareLocked(progress: nil)
        guard let volume = recovery?.volume else { return [UInt8](repeating: 0, count: length) }
        let handle = try FileHandle(forReadingFrom: volume)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        // The file holds exactly the volume's bytes; anything short is an error, never padding.
        let wanted = Int(min(UInt64(length), node.size - offset))
        var data = try handle.readBytes(wanted)
        guard data.count == wanted else { throw ISOBuilderError.unreadable(volume.path) }
        data += [UInt8](repeating: 0, count: length - data.count)
        return data
    }
}

/// The drive engine burns a `DiscImage` directly.
extension DiscImage: ImageSource {}

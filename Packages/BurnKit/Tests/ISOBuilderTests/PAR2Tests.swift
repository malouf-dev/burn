import CryptoKit
import Foundation
import Testing
@testable import ISOBuilder
import MMC

/// Reads PAR2 packets, written separately from the encoder, checking each packet's MD5.
struct PAR2Packet {
    let setID: [UInt8]
    let type: String
    let body: [UInt8]

    static func read(_ bytes: [UInt8]) throws -> [PAR2Packet] {
        var packets: [PAR2Packet] = []
        var offset = 0
        while offset < bytes.count {
            guard Array(bytes[offset..<(offset + 8)]) == Array("PAR2\0PKT".utf8) else {
                throw UDFReader.Problem("No packet at byte \(offset)")
            }
            var length = 0
            for index in 0..<8 { length |= Int(bytes[offset + 8 + index]) << (8 * index) }
            guard length >= 64, length % 4 == 0 else { throw UDFReader.Problem("Bad packet length \(length)") }
            let hash = Array(Insecure.MD5.hash(data: bytes[(offset + 32)..<(offset + length)]))
            guard hash == Array(bytes[(offset + 16)..<(offset + 32)]) else {
                throw UDFReader.Problem("Packet at byte \(offset) fails its MD5")
            }
            packets.append(PAR2Packet(setID: Array(bytes[(offset + 32)..<(offset + 48)]),
                                      type: String(decoding: bytes[(offset + 48)..<(offset + 64)], as: UTF8.self),
                                      body: Array(bytes[(offset + 64)..<(offset + length)])))
            offset += length
        }
        return packets
    }
}

@Suite("PAR2 recovery data")
struct PAR2Tests {
    @Test func fieldArithmetic() {
        // x^16 reduces to x^12 + x^3 + x + 1.
        #expect(GF16.exp(16) == 0x100B)
        #expect(GF16.exp(65535) == 1)
        for (a, b) in [(1, 1), (2, 0x8000), (0x1234, 0xFEDC), (0xFFFF, 0xFFFF), (7, 0)] as [(UInt16, UInt16)] {
            let product = GF16.multiply(a, b)
            #expect(product == GF16.multiply(b, a))
            if b != 0 { #expect(GF16.divide(product, b) == a) }
        }
        #expect(GF16.multiply(0x1234, GF16.divide(1, 0x1234)) == 1)
    }

    @Test func inputConstantsSkipFactorsOf65535() {
        #expect(GF16.inputLogs(count: 10) == [1, 2, 4, 7, 8, 11, 13, 14, 16, 19])
    }

    @Test func crc32MatchesTheStandardCheckValue() {
        #expect(Array("123456789".utf8).withUnsafeBytes { PAR2.crc32($0) } == 0xCBF4_3926)
    }

    @Test func aLostSliceCanBeRebuilt() {
        let size = 64
        let slices: [[UInt8]] = (0..<5).map { number in (0..<size).map { UInt8(truncatingIfNeeded: $0 * 31 + number * 7) } }
        let logs = GF16.inputLogs(count: slices.count)
        let encoder = PAR2Encoder(sliceSize: size, exponents: [0, 1])
        for (index, slice) in slices.enumerated() {
            // The last slice is short, as a file's last slice is, and counts as padded with zeros.
            let data = index == 4 ? Array(slice.prefix(10)) : slice
            data.withUnsafeBytes { encoder.add($0, inputLog: logs[index]) }
        }
        let padded = slices.enumerated().map { $0 == 4 ? Array($1.prefix(10)) + [UInt8](repeating: 0, count: size - 10) : $1 }

        // Exponent 0: every constant to the power 0 is 1, so the slice is the XOR of them all.
        let xor = padded.reduce([UInt8](repeating: 0, count: size)) { zip($0, $1).map { $0 ^ $1 } }
        #expect(encoder.slice(exponent: 0) == xor)

        // Exponent 1: lose slice 2, then rebuild it from the others and the recovery slice.
        func words(_ bytes: [UInt8]) -> [UInt16] {
            stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        }
        var rest = words(encoder.slice(exponent: 1))
        for (index, slice) in padded.enumerated() where index != 2 {
            let factor = GF16.coefficient(inputLog: logs[index], exponent: 1)
            for (word, value) in words(slice).enumerated() { rest[word] ^= GF16.multiply(factor, value) }
        }
        let factor = GF16.coefficient(inputLog: logs[2], exponent: 1)
        #expect(rest.map { GF16.divide($0, factor) } == words(padded[2]))
    }

    @Test func batchesAndPiecesAddUpLikeOneAtATime() {
        // Nine inputs cross a batch of eight, and slices over 64 KB cross a piece.
        let size = PAR2Encoder.chunk + 64
        let inputs: [[UInt8]] = (0..<9).map { number in (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ number &* 101) } }
        let logs = GF16.inputLogs(count: inputs.count)
        let encoder = PAR2Encoder(sliceSize: size, exponents: [3, 200])
        for (index, input) in inputs.enumerated() {
            input.withUnsafeBytes { encoder.add($0, inputLog: logs[index]) }
        }
        for exponent in [3, 200] {
            var expected = [UInt16](repeating: 0, count: size / 2)
            for (index, input) in inputs.enumerated() {
                let factor = GF16.coefficient(inputLog: logs[index], exponent: exponent)
                for word in 0..<(size / 2) {
                    expected[word] ^= GF16.multiply(factor, UInt16(input[2 * word]) | UInt16(input[2 * word + 1]) << 8)
                }
            }
            #expect(encoder.slice(exponent: exponent) == expected.withUnsafeBytes { Array($0) })
        }
    }

    @Test func manyExponentsAtOnceMatchOneAtATime() {
        // Enough exponents that every core works on several, as on a real disc.
        let size = 4096
        let inputs: [[UInt8]] = (0..<3).map { number in (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ number) } }
        let logs = GF16.inputLogs(count: inputs.count)
        let exponents = Array(0..<96)
        let together = PAR2Encoder(sliceSize: size, exponents: exponents)
        for (index, input) in inputs.enumerated() {
            input.withUnsafeBytes { together.add($0, inputLog: logs[index]) }
        }
        for exponent in exponents {
            let alone = PAR2Encoder(sliceSize: size, exponents: [exponent])
            for (index, input) in inputs.enumerated() {
                input.withUnsafeBytes { alone.add($0, inputLog: logs[index]) }
            }
            #expect(together.slice(exponent: exponent) == alone.slice(exponent: exponent), "exponent \(exponent)")
        }
    }

    @Test func slicesSuitTheDisc() throws {
        let cd = try #require(PAR2.plan(sizes: [700_000_000], percent: 10))
        #expect(cd.recoveryCount == 2000)
        #expect(cd.sliceSize % 4 == 0)
        let bluRay = try #require(PAR2.plan(sizes: [25_000_000_000], percent: 10))
        #expect(bluRay.recoveryCount == 80)
        let small = try #require(PAR2.plan(sizes: [100, 0, 5000], percent: 10))
        #expect(small.sliceSize == PAR2.minimumSliceSize)
        #expect(small.recoveryCount == 1)
        #expect(PAR2.plan(sizes: [0, 0], percent: 10) == nil)
        #expect(PAR2.plan(sizes: [100], percent: 0) == nil)
        #expect(PAR2.plan(sizes: [UInt64](repeating: 1, count: 40000), percent: 10) == nil)
        // Many files at once raise the slice size until the slices fit the limit.
        let many = try #require(PAR2.plan(sizes: [UInt64](repeating: 1_000_000, count: 1000), percent: 10))
        #expect(1000 * PAR2.sliceCount(1_000_000, sliceSize: many.sliceSize) <= PAR2.maxInputSlices)
    }

    func image(_ configure: (inout ISOImageBuilder) -> Void = { _ in }) throws -> (DiscImage, [String: [UInt8]], URL) {
        let (folder, expected) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "Recovery")
        configure(&builder)
        try builder.add(folder)
        return (try builder.image(date: Date(timeIntervalSince1970: 1_790_000_000)), expected, folder.deletingLastPathComponent())
    }

    func files(_ image: DiscImage, at base: URL, name: String) throws -> [String: [UInt8]] {
        let url = base.appendingPathComponent(name)
        try Data(image.read(block: 0, count: image.blockCount)).write(to: url)
        return try UDFReader(url: url).files()
    }

    @Test func discCarriesRecoveryFiles() throws {
        let (image, expected, base) = try image()
        #expect(image.needsPreparing)
        let files = try files(image, at: base, name: "recovery.iso")
        #expect(!image.needsPreparing)
        let index = try #require(files[".burn/recovery.par2"])
        let volumeName = try #require(files.keys.first { $0.hasPrefix(".burn/recovery.vol") })
        #expect(volumeName == ".burn/recovery.vol0+1.par2")

        let packets = try PAR2Packet.read(index)
        let main = try #require(packets.first { $0.type == "PAR 2.0\0Main\0\0\0\0" })
        #expect(Array(Insecure.MD5.hash(data: main.body)) == main.setID)
        #expect(packets.allSatisfy { $0.setID == main.setID })
        let descriptions = packets.filter { $0.type == "PAR 2.0\0FileDesc" }
        // Every file with data; the empty file needs no recovery.
        #expect(descriptions.count == expected.values.filter { !$0.isEmpty }.count)
        for description in descriptions {
            let nameBytes = description.body[56...].prefix { $0 != 0 }
            let path = String(decoding: nameBytes, as: UTF8.self)
            let bytes = try #require(expected[path], "\(path)")
            #expect(Array(description.body[16..<32]) == Array(Insecure.MD5.hash(data: bytes)))
        }
        #expect(packets.filter { $0.type == "PAR 2.0\0IFSC\0\0\0\0" }.count == descriptions.count)

        // The volume repeats those packets, then holds the recovery slice.
        let volume = try PAR2Packet.read(try #require(files[volumeName]))
        #expect(volume.count == packets.count + 1)
        let recovery = try #require(volume.last)
        #expect(recovery.type == "PAR 2.0\0RecvSlic")
        #expect(Array(recovery.body[0..<4]) == [0, 0, 0, 0])

        // Exponent 0 is the XOR of every input slice, each file cut into 4 KB slices.
        var xor = [UInt8](repeating: 0, count: PAR2.minimumSliceSize)
        for bytes in expected.values {
            for (offset, byte) in bytes.enumerated() { xor[offset % xor.count] ^= byte }
        }
        #expect(Array(recovery.body[4...]) == xor)

        let info = try JSONDecoder().decode(DiscInfo.self, from: Data(try #require(files[".burn/info.json"])))
        #expect(info.recovery == "PAR2, 10%")
    }

    @Test func severalPassesMakeTheSameData() throws {
        // 9,249 bytes of files at 100% make three 4 KB recovery slices.
        let (once, _, base) = try image { $0.recoveryPercent = 100 }
        let (passes, _, _) = try image { $0.recoveryPercent = 100 }
        passes.recoveryMemory = PAR2.minimumSliceSize
        let first = try files(once, at: base, name: "once.iso")
        let second = try files(passes, at: base, name: "passes.iso")
        let volume = try #require(first.keys.first { $0.hasPrefix(".burn/recovery.vol") })
        #expect(try PAR2Packet.read(try #require(first[volume])).filter { $0.type == "PAR 2.0\0RecvSlic" }.count == 3)
        #expect(first[volume] == second[volume])
        #expect(first[".burn/recovery.par2"] == second[".burn/recovery.par2"])
    }

    /// Counts and switches shared with the closures `prepare` calls.
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    let quickWaits: [TimeInterval] = Array(repeating: 0.001, count: 5)

    /// A file the recovery data reads in part, with a read partway through it.
    func midFileRead(_ image: DiscImage) throws -> (path: String, offset: UInt64) {
        var reads: [(String, UInt64)] = []
        image.readFault = { path, offset in reads.append((path, offset)) }
        try image.prepare(retryWaits: [])
        image.readFault = nil
        // Past the start, with more of the same file read after it.
        let read = try #require(reads.first { read in
            read.1 > 0 && reads.contains { $0.0 == read.0 && $0.1 > read.1 }
        })
        return (read.0, read.1)
    }

    @Test func aFileReadThatFailsWhileMakingRecoveryDataIsReadAgain() throws {
        // Hardware run 26: a file on a drive that dropped out. The read is tried again from the
        // same place, so the recovery data comes out exactly as it would have.
        let (clean, _, base) = try image()
        let (probe, _, _) = try image()
        let target = try midFileRead(probe)
        let (flaky, _, _) = try image()
        let failures = Box(0)
        flaky.readFault = { path, offset in
            if path == target.path, offset == target.offset, failures.value < 2 {
                failures.value += 1
                throw POSIXError(.EIO)
            }
        }
        let retries = Box<[String?]>([])
        try flaky.prepare(retryWaits: quickWaits, onRetry: { retries.value.append($0) })
        #expect(failures.value == 2)
        #expect(retries.value.count == 3)
        #expect(retries.value.first??.hasPrefix("Burn couldn't read \(target.path) from byte \(target.offset.grouped)") == true)
        #expect(retries.value.last == .some(nil))

        let first = try files(clean, at: base, name: "clean.iso")
        let second = try files(flaky, at: base, name: "flaky.iso")
        let volume = try #require(first.keys.first { $0.hasPrefix(".burn/recovery.vol") })
        #expect(first[volume] == second[volume])
        #expect(first[".burn/recovery.par2"] == second[".burn/recovery.par2"])
        #expect(first[".burn/SHA256SUMS"] == second[".burn/SHA256SUMS"])
    }

    @Test func aFileThatStaysUnreadableHoldsUntilTriedAgain() throws {
        let (image, _, _) = try image()
        let back = Box(false)
        image.readFault = { path, _ in
            if path.hasSuffix("readme.txt"), !back.value { throw POSIXError(.EIO) }
        }
        let held = Box<[HeldBurn]>([])
        try image.prepare(retryWaits: quickWaits, whenHeld: { burn in
            held.value.append(burn)
            back.value = true
            return .tryAgain
        })
        let burn = try #require(held.value.first)
        #expect(held.value.count == 1)
        #expect(burn.step == .readingFiles)
        #expect(burn.tries == 6)
        #expect(burn.problem.contains("readme.txt from byte 0 of"))
        #expect(burn.problem.hasSuffix("input/output error."))
        #expect(burn.advice.contains("nothing has been written to the disc"))
        #expect(!image.needsPreparing)
    }

    @Test func makingRecoveryDataCanBeAbandoned() throws {
        let (image, _, _) = try image()
        image.readFault = { path, _ in if path.hasSuffix("readme.txt") { throw POSIXError(.EIO) } }
        #expect {
            try image.prepare(retryWaits: quickWaits, whenHeld: { _ in .abandon })
        } throws: { error in
            guard case DriveError.abandoned(_, let tries) = error else { return false }
            return tries == 6
        }
        #expect(image.needsPreparing)
    }

    @Test func withNobodyToAskTheReadErrorIsThrown() throws {
        let (image, _, _) = try image()
        image.readFault = { path, _ in if path.hasSuffix("readme.txt") { throw POSIXError(.EIO) } }
        #expect(throws: POSIXError.self) { try image.prepare(retryWaits: quickWaits) }
    }

    @Test func recoveryCanBeLeftOut() throws {
        let (image, _, base) = try image { $0.recoveryPercent = 0 }
        #expect(!image.needsPreparing)
        let files = try files(image, at: base, name: "none.iso")
        #expect(files.keys.filter { $0.hasPrefix(".burn/") }.sorted() == [".burn/SHA256SUMS", ".burn/info.json"])
    }

    @Test func aFileChangedAfterPreparingIsCaught() throws {
        let (folder, _) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "Changed")
        try builder.add(folder)
        let image = try builder.image()
        try image.prepare()
        // Same size, different contents: only the checksum shows it.
        try Data("Hello, DISC.\n".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let error = try #require(throws: ISOBuilderError.self) {
            try image.read(block: 0, count: image.blockCount)
        }
        guard case .changedWhileWriting(let path) = error else {
            Issue.record("Expected changedWhileWriting, got \(error)")
            return
        }
        #expect(path.hasSuffix("/readme.txt"))
    }

    // MARK: - Repair

    /// The image's files written out as a mounted disc would show them, and what they should hold.
    func disc(percent: Int) throws -> (URL, [String: [UInt8]]) {
        let (image, expected, base) = try image { $0.recoveryPercent = percent }
        let files = try files(image, at: base, name: "disc.iso")
        let disc = base.appendingPathComponent("disc")
        for (path, bytes) in files {
            let url = disc.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
        }
        return (disc, expected)
    }

    @Test func damagedAndMissingFilesAreRepaired() throws {
        let (disc, expected) = try disc(percent: 100)
        #expect(RecoveryRepair.hasRecovery(at: disc))
        let deep = disc.appendingPathComponent("Holiday Photos/a/b/c/d/e/deep.bin")
        var bytes = try Data(contentsOf: deep)
        bytes[100] ^= 0xFF
        try bytes.write(to: deep)
        try FileManager.default.removeItem(at: disc.appendingPathComponent("Holiday Photos/readme.txt"))

        let output = disc.deletingLastPathComponent().appendingPathComponent("repaired")
        let report = try RecoveryRepair.repair(root: disc, into: output)
        #expect(report.isComplete)
        #expect(report.damagedSlices == 2)
        #expect(Set(report.repaired) == ["Holiday Photos/a/b/c/d/e/deep.bin", "Holiday Photos/readme.txt"])
        for (path, bytes) in expected where !bytes.isEmpty {
            #expect([UInt8](try Data(contentsOf: output.appendingPathComponent(path))) == bytes, "\(path)")
        }
        // The copy has every file and the .burn folder, so it checks out on its own.
        let check = try ChecksumVerifier.verify(root: output)
        #expect(check.isIntact)
        #expect(check.matched.count == expected.count)
    }

    @Test func tooMuchDamageIsReportedNotGuessed() throws {
        let (disc, _) = try disc(percent: 10)
        try FileManager.default.removeItem(at: disc.appendingPathComponent("Holiday Photos/readme.txt"))
        try FileManager.default.removeItem(at: disc.appendingPathComponent("Holiday Photos/Report.PDF"))
        let output = disc.deletingLastPathComponent().appendingPathComponent("repaired")
        let report = try RecoveryRepair.repair(root: disc, into: output)
        #expect(!report.isComplete)
        #expect(report.recoverySlices == 1)
        #expect(Set(report.unrepairable) == ["Holiday Photos/readme.txt", "Holiday Photos/Report.PDF"])
        #expect(report.repaired.isEmpty)
    }

    @Test func anIntactDiscNeedsNoRepair() throws {
        let (disc, expected) = try disc(percent: 10)
        let output = disc.deletingLastPathComponent().appendingPathComponent("copy")
        let report = try RecoveryRepair.repair(root: disc, into: output)
        #expect(report.isComplete)
        #expect(report.damagedSlices == 0)
        #expect(report.intact.count == expected.values.filter { !$0.isEmpty }.count)
    }

    @Test func matrixInverse() throws {
        let matrix: [[UInt16]] = [[1, 2, 3], [4, 5, 6], [7, 8, 10]]
        let inverse = try #require(GF16.invert(matrix))
        for row in 0..<3 {
            for column in 0..<3 {
                let sum = (0..<3).reduce(UInt16(0)) { $0 ^ GF16.multiply(matrix[row][$1], inverse[$1][column]) }
                #expect(sum == (row == column ? 1 : 0))
            }
        }
        #expect(GF16.invert([[1, 2], [1, 2]]) == nil)
    }
}

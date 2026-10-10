import CryptoKit
import Foundation
import MMC
import MMCSimulator
import Testing
@testable import ISOBuilder

@Suite("Images made as they're read")
struct DiscImageTests {
    func makeBuilder(_ folder: URL) throws -> ISOImageBuilder {
        var builder = ISOImageBuilder(volumeName: "Streamed")
        try builder.add(folder)
        return builder
    }

    @Test func anyOrderReadsTheSameAsTheFile() throws {
        let (folder, _) = try makeSourceFolder()
        let builder = try makeBuilder(folder)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let output = folder.deletingLastPathComponent().appendingPathComponent("streamed.iso")
        let blocks = try builder.write(to: output, date: date)
        let written = [UInt8](try Data(contentsOf: output))

        // Backwards, in odd-sized pieces, so .burn/SHA256SUMS is made before any file is read.
        let image = try builder.image(date: date)
        #expect(image.blockCount == blocks)
        var pieces: [[UInt8]] = []
        var end = image.blockCount
        while end > 0 {
            let count = min(7, end)
            pieces.append(try image.read(block: end - count, count: count))
            end -= count
        }
        #expect(Array(pieces.reversed().joined()) == written)
        // And again, the same.
        #expect(try image.read(block: 0, count: image.blockCount) == written)
    }

    @Test func burnsAndVerifiesThroughTheSimulator() async throws {
        let (folder, expected) = try makeSourceFolder()
        let image = try makeBuilder(folder).image()
        let simulator = SimulatedDrive(media: .init(profile: .bdRSequential, capacityBlocks: 12_219_392))
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        let report = try await drive.write(image)
        #expect(report.verified)

        // Read the disc back as a whole and check it as a UDF disc with its checksums.
        let media = try #require(simulator.currentMedia)
        var disc: [UInt8] = []
        for block in 0..<image.blockCount {
            disc += media.blocks[UInt32(block)] ?? [UInt8](repeating: 0, count: 2048)
        }
        let url = folder.deletingLastPathComponent().appendingPathComponent("burned.iso")
        try Data(disc).write(to: url)
        let files = try UDFReader(url: url).files()
        #expect(userFiles(files) == expected)
        let sums = try DiscChecksums.parse(String(decoding: try #require(files[".burn/SHA256SUMS"]), as: UTF8.self))
        #expect(sums.count == expected.count)
        for entry in sums {
            let bytes = try #require(expected[entry.path], "\(entry.path)")
            #expect(entry.digest == SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined())
        }
    }

    @Test func blocksSayWhatTheyHold() throws {
        let (folder, _) = try makeSourceFolder()
        let image = try makeBuilder(folder).image()
        #expect(image.describe(block: 0) == "padding")
        #expect(image.describe(block: 16)?.hasPrefix("disc structures") == true)
        #expect(image.describe(block: image.blockCount) == nil)
        let parts = (0..<image.blockCount).compactMap { image.describe(block: $0) }
        #expect(parts.contains("Holiday Photos/a/b/c/d/e/deep.bin from byte 2,048 of 5,000"))
        #expect(parts.contains { $0.hasPrefix(".burn/recovery.vol") })
    }

    @Test func aFileThatGrowsIsCaught() throws {
        let (folder, _) = try makeSourceFolder()
        let image = try makeBuilder(folder).image()
        let file = folder.appendingPathComponent("readme.txt")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more".utf8))
        try handle.close()
        // Compared by name: the scan may reach the file through /private/var rather than /var.
        let error = try #require(throws: ISOBuilderError.self) {
            try image.read(block: 0, count: image.blockCount)
        }
        guard case .changedWhileWriting(let path) = error else {
            Issue.record("Expected changedWhileWriting, got \(error)")
            return
        }
        #expect(path.hasSuffix("/readme.txt"))
    }

    @Test func aFileThatShrinksIsCaught() throws {
        let (folder, _) = try makeSourceFolder()
        let image = try makeBuilder(folder).image()
        let file = folder.appendingPathComponent("Report.PDF")
        try Data("short".utf8).write(to: file)
        // Compared by name: the scan may reach the file through /private/var rather than /var.
        let error = try #require(throws: ISOBuilderError.self) {
            try image.read(block: 0, count: image.blockCount)
        }
        guard case .changedWhileWriting(let path) = error else {
            Issue.record("Expected changedWhileWriting, got \(error)")
            return
        }
        #expect(path.hasSuffix("/Report.PDF"))
    }

    @Test func readsCarryOnPastAShortRead() throws {
        // A pipe hands back what has arrived so far, so one read returns less than asked.
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data([1, 2, 3]))
        let writer = pipe.fileHandleForWriting
        let thread = Thread {
            Thread.sleep(forTimeInterval: 0.2)
            writer.write(Data([4, 5, 6]))
            try? writer.close()
        }
        thread.start()
        #expect(try pipe.fileHandleForReading.readBytes(10) == [1, 2, 3, 4, 5, 6])
    }

    @Test func imagesFromOneBuilderStandApart() throws {
        let (folder, expected) = try makeSourceFolder()
        var builder = try makeBuilder(folder)
        let withUDF = try builder.image()
        builder.includesUDF = false
        let withoutUDF = try builder.image()
        #expect(withoutUDF.blockCount < withUDF.blockCount)

        let url = folder.deletingLastPathComponent().appendingPathComponent("first.iso")
        try Data(withUDF.read(block: 0, count: withUDF.blockCount)).write(to: url)
        #expect(userFiles(try UDFReader(url: url).files()) == expected)
    }
}

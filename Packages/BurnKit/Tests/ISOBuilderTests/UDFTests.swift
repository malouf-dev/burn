import Foundation
import Testing
@testable import ISOBuilder

@Suite("UDF bridge")
struct UDFTests {
    func build(_ configure: (inout ISOImageBuilder) -> Void = { _ in }) throws -> (UDFReader, ISOReader, [String: [UInt8]]) {
        let (folder, expected) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "My Test Disc")
        configure(&builder)
        try builder.add(folder)
        let output = folder.deletingLastPathComponent().appendingPathComponent("image.iso")
        let blocks = try builder.write(to: output)
        #expect(blocks == builder.blockCount())
        return (try UDFReader(url: output), try ISOReader(url: output), expected)
    }

    @Test func treeMatchesSource() throws {
        let (reader, _, expected) = try build()
        let files = userFiles(try reader.files())
        #expect(files.count == expected.count)
        for (path, bytes) in expected {
            #expect(files[path] == bytes, "\(path)")
        }
    }

    @Test func volumeDescribesTheDisc() throws {
        let (reader, iso, expected) = try build()
        #expect(reader.volumeName == "My Test Disc")
        #expect(reader.partitionStart == 257)
        #expect(reader.partitionStart + reader.partitionLength == iso.bytes.count / 2048 - 1)
        // Every file plus the four in .burn; the root, .burn, Holiday Photos, a to e, and many.
        #expect(reader.integrity.fileCount == UInt32(expected.count + 4))
        #expect(reader.integrity.directoryCount == 9)
        #expect(reader.integrity.nextUniqueID == UInt64(15 + expected.count + 4 + 9))
    }

    @Test func longDiscNamesKeepTheirWholeNameInUDF() throws {
        let (folder, _) = try makeSourceFolder()
        let name = "Better Off Ted (Season 1 & 2)"
        var builder = ISOImageBuilder(volumeName: name)
        try builder.add(folder)
        let output = folder.deletingLastPathComponent().appendingPathComponent("named.iso")
        try builder.write(to: output)
        #expect(try UDFReader(url: output).volumeName == name)
        // Joliet's descriptor holds 16 characters, big-endian, padded with spaces.
        let joliet = try ISOReader(url: output)
        let units = stride(from: 17 * 2048 + 40, to: 17 * 2048 + 72, by: 2).map {
            UInt16(joliet.bytes[$0]) << 8 | UInt16(joliet.bytes[$0 + 1])
        }
        #expect(String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces) == "Better Off Ted (")
    }

    @Test func isoAndUDFShareTheFileData() throws {
        let (reader, iso, _) = try build()
        let jolietTop = try #require(iso.children(of: iso.rootRecord(descriptorSector: 17))
            .first { ISOReader.jolietName($0.identifier) == "Holiday Photos" })
        let jolietFile = try #require(iso.children(of: jolietTop).first { ISOReader.jolietName($0.identifier) == "readme.txt" })
        let udfTop = try #require(try reader.rootEntries().first { $0.name == "Holiday Photos" })
        let udfFile = try #require(try reader.identifiers(try reader.fileEntry(block: udfTop.entryBlock))
            .first { $0.name == "readme.txt" })
        let entry = try reader.fileEntry(block: udfFile.entryBlock)
        #expect(entry.extents.count == 1)
        #expect(UInt32(reader.partitionStart) + entry.extents[0].block == jolietFile.extent)
    }

    @Test func burnFolderIsHidden() throws {
        let (reader, _, _) = try build()
        let burn = try #require(try reader.rootEntries().first { $0.name == ".burn" })
        #expect(burn.isHidden)
        #expect(burn.isDirectory)
        #expect(try reader.rootEntries().filter(\.isHidden).count == 1)
    }

    @Test func checksumPathsFollowUDFNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udf-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let long = String(repeating: "n", count: 200) + ".txt"
        let marks = "What? A: B*.txt"
        try Data("long".utf8).write(to: folder.appendingPathComponent(long))
        try Data("marks".utf8).write(to: folder.appendingPathComponent(marks))
        var builder = ISOImageBuilder(volumeName: "Names")
        try builder.addContents(of: folder)
        let output = folder.appendingPathComponent("names.iso")
        try builder.write(to: output)

        let files = try UDFReader(url: output).files()
        #expect(files[long] == Array("long".utf8))
        #expect(files[marks] == Array("marks".utf8))
        let sums = try DiscChecksums.parse(String(decoding: try #require(files[".burn/SHA256SUMS"]), as: UTF8.self))
        #expect(Set(sums.map(\.path)) == [long, marks])

        // Joliet keeps its own, shorter names for the same files.
        let joliet = try ISOReader(url: output).jolietFiles()
        #expect(joliet["What_ A_ B_.txt"] == Array("marks".utf8))
        #expect(joliet.keys.contains { $0.hasSuffix(".txt") && $0.utf16.count == Names.jolietLimit })
    }

    @Test func udfCanBeLeftOut() throws {
        let (folder, expected) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "Plain")
        builder.includesUDF = false
        try builder.add(folder)
        let output = folder.deletingLastPathComponent().appendingPathComponent("plain.iso")
        let blocks = try builder.write(to: output)
        #expect(blocks == builder.blockCount())
        #expect(throws: (any Error).self) { try UDFReader(url: output) }
        let iso = try ISOReader(url: output)
        #expect(iso.le32(16 * 2048 + 140) == 19) // the path table follows the descriptors directly
        let files = userFiles(iso.jolietFiles())
        #expect(files.count == expected.count)
        for (path, bytes) in expected {
            #expect(files[path] == bytes, "\(path)")
        }
    }

    @Test func filesOf4GBOrMoreAreInUDFOnly() throws {
        let root = Node(name: "", source: nil, isDirectory: true, size: 0, date: Date())
        let big = Node(name: "big.mov", source: nil, isDirectory: false, size: 5 << 30, date: Date())
        let small = Node(name: "small.txt", source: nil, isDirectory: false, size: 10, date: Date())
        root.children = [big, small]
        let layout = Layout(root: root, paddingBlocks: 150, includesUDF: true)
        #expect(layout.sortedChildren(root, joliet: true).map(\.name) == ["small.txt"])
        #expect(layout.sortedChildren(root, joliet: false).count == 1)
        #expect(layout.udfSortedChildren(root).map(\.udfName) == ["big.mov", "small.txt"])
        #expect(layout.totalBlocks > Int(big.size / 2048))

        // Under 1 GB per extent, so 5 GB takes six, laid end to end.
        let entry = layout.udfFileEntry(big)
        #expect(UDFReader.le32(entry, 172) == 6 * 8)
        var total: UInt64 = 0
        var block = big.fileExtent - UDF.partitionStart
        for index in 0..<6 {
            let length = UDFReader.le32(entry, 176 + 8 * index)
            #expect(UDFReader.le32(entry, 180 + 8 * index) == block)
            #expect(index == 5 || length == UInt32(UDF.maxExtent))
            block += length / 2048
            total += UInt64(length)
        }
        #expect(total == big.size)
    }

    @Test func withoutUDFLargeFilesAreRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("udf-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("big.bin")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        // A sparse file: it reads as 4.5 GB of zeros but takes no space.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 4_500_000_000)
        try handle.close()

        var builder = ISOImageBuilder(volumeName: "Big")
        try builder.add(url)
        #expect(builder.blockCount() > 4_500_000_000 / 2048)
        builder.includesUDF = false
        #expect(throws: ISOBuilderError.fileTooLarge(url.path)) {
            try builder.write(to: folder.appendingPathComponent("big.iso"))
        }
    }

    @Test func crcMatchesTheStandard() {
        // ECMA-167 1/7.2.6 gives this example, and 0x31C3 is CRC-16/XMODEM's check value.
        #expect(UDF.crc(ArraySlice<UInt8>([0x70, 0x6A, 0x77])) == 0x3299)
        #expect(UDF.crc(Array("123456789".utf8)[...]) == 0x31C3)
    }

    @Test func compressedUnicode() {
        #expect(UDF.cs0("abc") == [8, 0x61, 0x62, 0x63])
        #expect(UDF.cs0("Caf\u{E9}") == [8, 0x43, 0x61, 0x66, 0xE9])
        #expect(UDF.cs0("日本") == [16, 0x65, 0xE5, 0x67, 0x2C])
        let field = UDF.dstring("Disc", length: 32)
        #expect(field.count == 32)
        #expect(Array(field[0..<5]) == [8, 0x44, 0x69, 0x73, 0x63])
        #expect(field[31] == 5)
        #expect(UDF.dstring("", length: 32) == [UInt8](repeating: 0, count: 32))
        #expect(UDF.dstring(String(repeating: "x", count: 40), length: 32)[31] == 31)
    }

    @Test func udfNames() {
        #expect(Names.udf("a/b", isDirectory: false) == "a_b")
        #expect(Names.udf("What? A: B*.txt", isDirectory: false) == "What? A: B*.txt")
        #expect(Names.udf(String(repeating: "a", count: 300), isDirectory: true).utf16.count == 254)
        #expect(Names.udf(String(repeating: "日", count: 300), isDirectory: true).utf16.count == 127)
        #expect(Names.udf("Cafe\u{301}", isDirectory: true) == "Caf\u{E9}")
        #expect(UDF.cs0(Names.udf(String(repeating: "日", count: 300) + ".txt", isDirectory: false)).count <= 255)
    }
}

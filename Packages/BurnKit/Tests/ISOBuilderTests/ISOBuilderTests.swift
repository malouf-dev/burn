import CryptoKit
import Foundation
import Testing
@testable import ISOBuilder

/// Files in the image other than the `.burn` checksum folder.
func userFiles(_ files: [String: [UInt8]]) -> [String: [UInt8]] {
    files.filter { !$0.key.hasPrefix(DiscChecksums.folderName + "/") }
}

/// Creates a folder of test files and returns it with the expected relative paths and contents.
func makeSourceFolder() throws -> (URL, [String: [UInt8]]) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("iso-test-\(UUID().uuidString)")
    let folder = base.appendingPathComponent("Holiday Photos")
    var expected: [String: [UInt8]] = [:]

    func add(_ relative: String, _ bytes: [UInt8]) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        expected["Holiday Photos/" + relative] = bytes
    }

    try add("readme.txt", Array("Hello, disc.\n".utf8))
    try add("empty file", [])
    try add("Café résumé.txt", Array("accents".utf8))
    try add("a/b/c/d/e/deep.bin", (0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    try add(String(repeating: "L", count: 96) + ".txt", Array("long name".utf8))
    try add("Report.PDF", [UInt8](repeating: 0x25, count: 4097))
    try add("report.pdf copy", [1, 2, 3])
    for index in 0..<120 {
        try add("many/file number \(index).dat", [UInt8(index)])
    }
    try Data("junk".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
    return (folder, expected)
}

@Suite("ISO image builder")
struct ISOBuilderTests {
    func build() throws -> (ISOReader, [String: [UInt8]], Int, URL) {
        let (folder, expected) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "My Test Disc")
        try builder.add(folder)
        let output = folder.deletingLastPathComponent().appendingPathComponent("image.iso")
        let blocks = try builder.write(to: output)
        #expect(blocks == builder.blockCount())
        return (try ISOReader(url: output), expected, blocks, output)
    }

    @Test func volumeDescriptors() throws {
        let (reader, _, blocks, _) = try build()
        #expect(reader.bytes.count == blocks * 2048)
        #expect(reader.bytes[16 * 2048] == 1)
        #expect(Array(reader.bytes[(16 * 2048 + 1)..<(16 * 2048 + 6)]) == Array("CD001".utf8))
        #expect(reader.le32(16 * 2048 + 80) == UInt32(blocks))
        #expect(reader.be32(16 * 2048 + 84) == UInt32(blocks))
        #expect(reader.bytes[17 * 2048] == 2)
        #expect(Array(reader.bytes[(17 * 2048 + 88)..<(17 * 2048 + 91)]) == [0x25, 0x2F, 0x45])
        #expect(reader.bytes[18 * 2048] == 255)
        let volumeID = String(decoding: reader.bytes[(16 * 2048 + 40)..<(16 * 2048 + 72)], as: UTF8.self)
        #expect(volumeID.trimmingCharacters(in: .whitespaces) == "MY_TEST_DISC")
    }

    @Test func jolietTreeMatchesSource() throws {
        let (reader, expected, _, _) = try build()
        let files = userFiles(reader.jolietFiles())
        #expect(files.count == expected.count)
        for (path, bytes) in expected {
            #expect(files[path] == bytes, "\(path)")
        }
        #expect(files.keys.allSatisfy { !$0.hasSuffix(".DS_Store") })
    }

    @Test func isoNamesAreLevelOneAndUnique() throws {
        let (reader, _, _, _) = try build()
        let pattern = try Regex("^[A-Z0-9_]{1,8}(\\.[A-Z0-9_]{0,3};1)?$")
        for directory in reader.isoNames() {
            #expect(Set(directory).count == directory.count)
            for name in directory {
                #expect(name.wholeMatch(of: pattern) != nil, "\(name)")
            }
        }
    }

    @Test func pathTablesListEveryDirectory() throws {
        let (reader, _, _, _) = try build()
        let size = Int(reader.le32(16 * 2048 + 132))
        let lTable = Int(reader.le32(16 * 2048 + 140)) * 2048
        let mTable = Int(reader.be32(16 * 2048 + 148)) * 2048
        var offset = 0
        var count = 0
        while offset < size {
            let nameLength = Int(reader.bytes[lTable + offset])
            #expect(reader.bytes[mTable + offset] == UInt8(nameLength))
            if count == 0 {
                #expect(reader.le32(lTable + offset + 2) == reader.rootRecord(descriptorSector: 16).extent)
                #expect(reader.be32(mTable + offset + 2) == reader.rootRecord(descriptorSector: 16).extent)
            }
            offset += 8 + nameLength + nameLength % 2
            count += 1
        }
        // Root, .burn, Holiday Photos, a, a/b, a/b/c, a/b/c/d, a/b/c/d/e, many
        #expect(count == 9)
    }

    @Test func addContentsPutsFilesAtTheRoot() throws {
        let (folder, expected) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "Contents")
        try builder.addContents(of: folder)
        let output = folder.deletingLastPathComponent().appendingPathComponent("contents.iso")
        try builder.write(to: output)
        let files = userFiles(try ISOReader(url: output).jolietFiles())
        let prefix = "Holiday Photos/"
        #expect(files.count == expected.count)
        for (path, bytes) in expected {
            #expect(files[String(path.dropFirst(prefix.count))] == bytes, "\(path)")
        }
    }

    @Test func longNamesThatTruncateAlikeGetDistinctNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iso-long-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let long = String(repeating: "x", count: 150)
        try Data("one".utf8).write(to: folder.appendingPathComponent(long + "1.txt"))
        try Data("two".utf8).write(to: folder.appendingPathComponent(long + "2.txt"))
        var builder = ISOImageBuilder(volumeName: "Long")
        builder.includesChecksums = false
        try builder.addContents(of: folder)
        let output = folder.appendingPathComponent("long.iso")
        try builder.write(to: output)
        let files = try ISOReader(url: output).jolietFiles()
        #expect(files.count == 2)
        #expect(Set(files.values) == [Array("one".utf8), Array("two".utf8)])
        #expect(files.keys.allSatisfy { $0.hasSuffix(".txt") && $0.utf16.count == Names.jolietLimit })
    }

    @Test func largeDirectorySpansSectors() throws {
        let (reader, _, _, _) = try build()
        let root = reader.rootRecord(descriptorSector: 17)
        let top = try #require(reader.children(of: root).first { ISOReader.jolietName($0.identifier) == "Holiday Photos" })
        let many = try #require(reader.children(of: top).first { ISOReader.jolietName($0.identifier) == "many" })
        #expect(many.size > 2048)
        #expect(reader.children(of: many).count == 120)
    }
}

@Suite("Checksum folder")
struct ChecksumFolderTests {
    func build(_ configure: (inout ISOImageBuilder) -> Void = { _ in }) throws -> (ISOReader, [String: [UInt8]], URL) {
        let (folder, expected) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "My Test Disc")
        configure(&builder)
        try builder.add(folder)
        let output = folder.deletingLastPathComponent().appendingPathComponent("image.iso")
        let blocks = try builder.write(to: output)
        #expect(blocks == builder.blockCount())
        return (try ISOReader(url: output), expected, folder.deletingLastPathComponent())
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func listsEveryFileWithItsSHA256() throws {
        let (reader, expected, _) = try build()
        let files = reader.jolietFiles()
        let sums = try #require(files[".burn/SHA256SUMS"])
        let entries = try DiscChecksums.parse(String(decoding: sums, as: UTF8.self))
        #expect(entries.count == expected.count)
        for entry in entries {
            let bytes = try #require(expected[entry.path], "\(entry.path)")
            #expect(entry.digest == Self.sha256(bytes), "\(entry.path)")
        }
        #expect(entries.map(\.path) == entries.map(\.path).sorted())
    }

    @Test func infoDescribesTheDisc() throws {
        let (reader, expected, _) = try build { $0.applicationName = "Burn test" }
        let data = try #require(reader.jolietFiles()[".burn/info.json"])
        let info = try JSONDecoder().decode(DiscInfo.self, from: Data(data))
        #expect(info.discName == "My Test Disc")
        #expect(info.application == "Burn test")
        #expect(info.fileCount == expected.count)
        #expect(info.totalBytes == expected.values.reduce(0) { $0 + UInt64($1.count) })
        #expect(info.algorithm == "SHA-256")
        #expect(info.created.count == 20)
    }

    @Test func folderIsHiddenInBothTrees() throws {
        let (reader, _, _) = try build()
        let joliet = reader.children(of: reader.rootRecord(descriptorSector: 17))
        let burn = try #require(joliet.first { ISOReader.jolietName($0.identifier) == ".burn" })
        #expect(burn.isHidden)
        #expect(burn.isDirectory)
        let iso = reader.children(of: reader.rootRecord(descriptorSector: 16))
        let isoBurn = try #require(iso.first { String(decoding: $0.identifier, as: UTF8.self) == "_BURN" })
        #expect(isoBurn.isHidden)
        #expect(joliet.filter(\.isHidden).count == 1)
    }

    @Test func checksumsCanBeLeftOut() throws {
        let (reader, expected, _) = try build { $0.includesChecksums = false }
        let files = reader.jolietFiles()
        #expect(files.count == expected.count)
        #expect(files.keys.allSatisfy { !$0.hasPrefix(".burn") })
    }

    @Test func aStaleBurnFolderIsReplaced() throws {
        let (folder, expected) = try makeSourceFolder()
        let stale = folder.appendingPathComponent(".burn")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("0000  old disc\n".utf8).write(to: stale.appendingPathComponent("SHA256SUMS"))
        var builder = ISOImageBuilder(volumeName: "Copy")
        try builder.addContents(of: folder)
        let output = folder.deletingLastPathComponent().appendingPathComponent("copy.iso")
        try builder.write(to: output)
        let files = try ISOReader(url: output).jolietFiles()
        let sums = String(decoding: try #require(files[".burn/SHA256SUMS"]), as: UTF8.self)
        #expect(!sums.contains("old disc"))
        #expect(try DiscChecksums.parse(sums).count == expected.count)
        #expect(files.keys.filter { $0.hasPrefix(".burn") }.count == 2)
    }
}

@Suite("Name rules")
struct NameTests {
    @Test func isoNames() {
        #expect(Names.iso("hello world.txt", isDirectory: false) == "HELLO_WO.TXT;1")
        #expect(Names.iso("archive.tar.gz", isDirectory: false) == "ARCHIVE_.GZ;1")
        #expect(Names.iso("README", isDirectory: false) == "README.;1")
        #expect(Names.iso("My Folder.v2", isDirectory: true) == "MY_FOLDE")
        #expect(Names.iso(".hidden", isDirectory: false) == "_HIDDEN.;1")
        #expect(Names.iso("hello world.txt", isDirectory: false, index: 3) == "HELLO__3.TXT;1")
    }

    @Test func jolietNames() {
        #expect(Names.joliet("a:b*c?.txt", isDirectory: false) == "a_b_c_.txt")
        #expect(Names.joliet("photo.jpg", isDirectory: false, index: 1) == "photo (2).jpg")
        let long = String(repeating: "x", count: 200)
        #expect(Names.joliet(long, isDirectory: true).utf16.count == Names.jolietLimit)
    }

    @Test func longDuplicatesStayDistinctAndKeepTheirExtension() {
        let long = String(repeating: "n", count: 150)
        let first = Names.joliet(long + "1.txt", isDirectory: false)
        let second = Names.joliet(long + "2.txt", isDirectory: false, index: 1)
        #expect(first.utf16.count == Names.jolietLimit)
        #expect(first.hasSuffix(".txt"))
        #expect(second.utf16.count == Names.jolietLimit)
        #expect(second.hasSuffix(" (2).txt"))
        #expect(first != second)
    }

    @Test func jolietNamesAreComposed() {
        let decomposed = "Cafe\u{301}"
        #expect(Names.joliet(decomposed, isDirectory: true) == "Caf\u{E9}")
        #expect(Names.joliet(decomposed, isDirectory: true).unicodeScalars.count == 4)
    }

    @Test func jolietIdentifierIsBigEndianWithVersion() {
        #expect(Names.jolietIdentifier("A", isDirectory: false) == [0x00, 0x41, 0x00, 0x3B, 0x00, 0x31])
        #expect(Names.jolietIdentifier("A", isDirectory: true) == [0x00, 0x41])
    }
}

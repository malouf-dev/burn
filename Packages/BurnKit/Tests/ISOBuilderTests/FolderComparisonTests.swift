import Foundation
import Testing
@testable import ISOBuilder

@Suite("Comparing folders")
struct FolderComparisonTests {
    @Test func findsWhatDiffers() throws {
        let (original, _) = try makeSourceFolder()
        let copy = original.deletingLastPathComponent().appendingPathComponent("Copy")
        try FileManager.default.copyItem(at: original, to: copy)
        #expect(try FolderComparison.compare(original: original, copy: copy).isIdentical)

        // Restore's own files and .DS_Store don't count.
        try Data("{}".utf8).write(to: copy.appendingPathComponent(DiscRestore.stateName))
        try FileManager.default.createDirectory(at: copy.appendingPathComponent(".burn-restore-x/a"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: copy.appendingPathComponent(".burn-restore-x/a/b"))
        let quiet = try FolderComparison.compare(original: original, copy: copy)
        #expect(quiet.isIdentical)
        #expect(quiet.matching.count == 127)

        try Data("Hello, disc!\n".utf8).write(to: copy.appendingPathComponent("readme.txt"))
        var bytes = [UInt8](try Data(contentsOf: copy.appendingPathComponent("a/b/c/d/e/deep.bin")))
        bytes[4_999] ^= 0x01
        try Data(bytes).write(to: copy.appendingPathComponent("a/b/c/d/e/deep.bin"))
        try FileManager.default.removeItem(at: copy.appendingPathComponent("report.pdf copy"))
        try Data("new".utf8).write(to: copy.appendingPathComponent("extra.txt"))

        let result = try FolderComparison.compare(original: original, copy: copy)
        #expect(!result.isIdentical)
        #expect(result.differing == ["a/b/c/d/e/deep.bin", "readme.txt"])
        #expect(result.onlyInOriginal == ["report.pdf copy"])
        #expect(result.onlyInCopy == ["extra.txt"])
    }
}

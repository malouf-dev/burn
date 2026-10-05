import Foundation
import Testing
@testable import ISOBuilder

@Suite("Reading discs back with retries")
struct RestoreReadingTests {
    static let deep = "Holiday Photos/a/b/c/d/e/deep.bin"

    /// A disc of the usual test files, written out as if mounted, with or without recovery data.
    func mountedDisc(recovery: Int) throws -> (root: URL, expected: [String: [UInt8]], base: URL) {
        let (folder, expected) = try makeSourceFolder()
        var builder = ISOImageBuilder(volumeName: "Reading")
        builder.recoveryPercent = recovery
        try builder.add(folder)
        let base = folder.deletingLastPathComponent()
        let image = base.appendingPathComponent("disc.iso")
        try builder.write(to: image)
        let root = base.appendingPathComponent("mounted")
        for (path, bytes) in try UDFReader(url: image).files() {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
        }
        return (root, expected, base)
    }

    /// Reads the disc, but gets `deep.bin` wrong on the first try at each piece, as the BD-R
    /// drive did in runs 18 and 20, or can't read some of its bytes at all.
    func faulty(misreadFirst: Bool = false, unreadable: Range<UInt64>? = nil) -> DiscReader {
        DiscReader { url, offset, count, attempt in
            var bytes = try DiscReader.disc.read(url, offset, count, attempt)
            guard url.path.hasSuffix("deep.bin") else { return bytes }
            if let unreadable, offset < unreadable.upperBound, offset + UInt64(count) > unreadable.lowerBound {
                throw CocoaError(.fileReadUnknown)
            }
            if misreadFirst, attempt == 1, !bytes.isEmpty { bytes[0] ^= 0xFF }
            return bytes
        }
    }

    func restored(_ destination: URL, _ path: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: destination.appendingPathComponent(path)))
    }

    @Test func aMisreadIsReadAgain() throws {
        let (root, expected, base) = try mountedDisc(recovery: 10)
        let destination = base.appendingPathComponent("Restored")
        let report = try DiscRestore.restore(root: root, into: destination, reader: faulty(misreadFirst: true)) { _ in }
        #expect(report.isComplete)
        #expect(report.repaired.isEmpty)
        #expect(report.rereads == 2) // deep.bin's two slices
        #expect(try restored(destination, Self.deep) == expected[Self.deep])
    }

    @Test func anUnreadableAreaIsRebuiltFromRecoveryData() throws {
        let (root, expected, base) = try mountedDisc(recovery: 10)
        let destination = base.appendingPathComponent("Restored")
        let report = try DiscRestore.restore(root: root, into: destination, reader: faulty(unreadable: 0..<2048)) { _ in }
        #expect(report.isComplete)
        #expect(report.repaired == [Self.deep])
        #expect(try restored(destination, Self.deep) == expected[Self.deep])
    }

    @Test func withoutRecoveryDataAMisreadIsCopiedAgain() throws {
        let (root, expected, base) = try mountedDisc(recovery: 0)
        let destination = base.appendingPathComponent("Restored")
        let report = try DiscRestore.restore(root: root, into: destination, reader: faulty(misreadFirst: true)) { _ in }
        #expect(report.isComplete)
        #expect(report.rereads == 1)
        #expect(try restored(destination, Self.deep) == expected[Self.deep])
    }

    @Test func withoutRecoveryDataWhatCanBeReadIsSalvaged() throws {
        let (root, expected, base) = try mountedDisc(recovery: 0)
        let destination = base.appendingPathComponent("Restored")
        let report = try DiscRestore.restore(root: root, into: destination, reader: faulty(unreadable: 2048..<4096)) { _ in }
        #expect(report.damaged == [Self.deep])
        #expect(report.unreadableBytes == [Self.deep: 2048])
        // Not restored, but kept with everything that could be read.
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(Self.deep).path))
        let kept = try #require(report.kept)
        let salvaged = try restored(kept, Self.deep)
        let original = try #require(expected[Self.deep])
        #expect(salvaged.count == original.count)
        #expect(Array(salvaged[0..<2048]) == Array(original[0..<2048]))
        #expect(salvaged[2048..<4096].allSatisfy { $0 == 0 })
        #expect(Array(salvaged[4096...]) == Array(original[4096...]))
        // Everything else is restored.
        #expect(try restored(destination, "Holiday Photos/readme.txt") == expected["Holiday Photos/readme.txt"])
    }
}

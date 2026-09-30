import Foundation
import Testing
@testable import ISOBuilder

@Suite("Checking a disc against its checksums")
struct ChecksumVerifierTests {
    /// Writes an image's files into a folder, as a mounted disc would show them.
    func mountedCopy(decomposeNames: Bool = false) throws -> (URL, [String: [UInt8]]) {
        let (reader, expected, base) = try ChecksumFolderTests().build()
        let disc = base.appendingPathComponent("disc")
        for (path, bytes) in reader.jolietFiles() {
            let onDisc = decomposeNames ? path.decomposedStringWithCanonicalMapping : path
            let url = disc.appendingPathComponent(onDisc)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
        }
        return (disc, expected)
    }

    @Test func anIntactDiscPasses() throws {
        let (disc, expected) = try mountedCopy()
        #expect(ChecksumVerifier.hasChecksums(at: disc))
        let report = try ChecksumVerifier.verify(root: disc)
        #expect(report.isIntact)
        #expect(report.matched.count == expected.count)
        #expect(report.unexpected.isEmpty)
        #expect(report.info?.discName == "My Test Disc")
    }

    @Test func changedMissingAndUnexpectedFilesAreReported() throws {
        let (disc, _) = try mountedCopy()
        try Data("tampered".utf8).write(to: disc.appendingPathComponent("Holiday Photos/readme.txt"))
        try FileManager.default.removeItem(at: disc.appendingPathComponent("Holiday Photos/many/file number 7.dat"))
        try Data("new".utf8).write(to: disc.appendingPathComponent("Holiday Photos/added.txt"))
        let report = try ChecksumVerifier.verify(root: disc)
        #expect(!report.isIntact)
        #expect(report.changed == ["Holiday Photos/readme.txt"])
        #expect(report.missing == ["Holiday Photos/many/file number 7.dat"])
        #expect(report.unexpected == ["Holiday Photos/added.txt"])
    }

    // macOS can list a disc's names decomposed, while the list holds them composed.
    @Test func decomposedNamesStillMatch() throws {
        let (disc, expected) = try mountedCopy(decomposeNames: true)
        let report = try ChecksumVerifier.verify(root: disc)
        #expect(report.isIntact)
        #expect(report.matched.count == expected.count)
    }

    @Test func eachFileIsReportedAsItsChecked() throws {
        let (disc, expected) = try mountedCopy()
        try Data("tampered".utf8).write(to: disc.appendingPathComponent("Holiday Photos/readme.txt"))
        let results = FileResults()
        _ = try ChecksumVerifier.verify(root: disc, file: { results.add($0, $1) })
        #expect(results.all.count == expected.count)
        #expect(results.all["Holiday Photos/readme.txt"] == .changed)
        #expect(results.all.values.filter { $0 == .matched }.count == expected.count - 1)
        #expect(try ChecksumVerifier.listedFiles(at: disc).count == expected.count)
    }

    @Test func progressReachesTheEnd() throws {
        let (disc, expected) = try mountedCopy()
        let last = LastProgress()
        _ = try ChecksumVerifier.verify(root: disc) { last.set($0) }
        let progress = try #require(last.value)
        #expect(progress.checkedFiles == expected.count)
        #expect(progress.fraction == 1)
    }

    @Test func aDiscWithoutChecksumsIsRefused() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-sums-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(!ChecksumVerifier.hasChecksums(at: empty))
        #expect(throws: DiscChecksumsError.noChecksums) { try ChecksumVerifier.verify(root: empty) }
    }

    @Test func listsFromShasumAreRead() throws {
        let digest = String(repeating: "ab", count: 32)
        let entries = try DiscChecksums.parse("\(digest) *binary file.bin\n\(digest.uppercased())  text.txt\r\n")
        #expect(entries.map(\.path) == ["binary file.bin", "text.txt"])
        #expect(entries.allSatisfy { $0.digest == digest })
        #expect(throws: DiscChecksumsError.badLine(1)) { try DiscChecksums.parse("not a checksum\n") }
    }
}

final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ChecksumProgress?

    func set(_ progress: ChecksumProgress) {
        lock.lock()
        defer { lock.unlock() }
        stored = progress
    }

    var value: ChecksumProgress? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class FileResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: FileCheck] = [:]

    func add(_ path: String, _ check: FileCheck) {
        lock.lock()
        defer { lock.unlock() }
        results[path] = check
    }

    var all: [String: FileCheck] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}

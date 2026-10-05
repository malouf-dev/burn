import CryptoKit
import Foundation
import MMC

/// What checking a disc against its `.burn/SHA256SUMS` found. Paths are from the disc's root.
public struct ChecksumReport: Sendable, Equatable {
    public var info: DiscInfo?
    public var matched: [String] = []
    /// Files whose contents no longer match their checksum.
    public var changed: [String] = []
    /// Files in the list that aren't on the disc.
    public var missing: [String] = []
    /// Files that couldn't be read to the end.
    public var unreadable: [String] = []
    /// Files on the disc that aren't in the list.
    public var unexpected: [String] = []

    /// True when every listed file is there and matches.
    public var isIntact: Bool {
        changed.isEmpty && missing.isEmpty && unreadable.isEmpty
    }

    public var checkedCount: Int {
        matched.count + changed.count + missing.count + unreadable.count
    }
}

/// One listed file's result.
public enum FileCheck: Sendable, Equatable {
    case matched
    case changed
    case missing
    case unreadable
}

public struct ChecksumProgress: Sendable, Equatable {
    public var checkedFiles: Int
    public var totalFiles: Int
    public var checkedBytes: UInt64
    public var totalBytes: UInt64

    public init(checkedFiles: Int, totalFiles: Int, checkedBytes: UInt64, totalBytes: UInt64) {
        self.checkedFiles = checkedFiles
        self.totalFiles = totalFiles
        self.checkedBytes = checkedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes == 0 ? (totalFiles == 0 ? 1 : Double(checkedFiles) / Double(totalFiles))
                        : Double(checkedBytes) / Double(totalBytes)
    }
}

/// Checks the files on a mounted disc, or any folder, against its `.burn/SHA256SUMS`.
public enum ChecksumVerifier {
    /// True when `root` has a checksum list to check against.
    public static func hasChecksums(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: sumsURL(root).path)
    }

    /// The details in `.burn/info.json`, if the disc has them.
    public static func info(at root: URL) -> DiscInfo? {
        let url = root.appendingPathComponent(DiscChecksums.folderName).appendingPathComponent(DiscChecksums.infoName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiscInfo.self, from: data)
    }

    /// The paths in the disc's checksum list, in its order, for showing before a check.
    public static func listedFiles(at root: URL) throws -> [String] {
        try entries(at: root).map(\.path)
    }

    static func entries(at root: URL) throws -> [(path: String, digest: String)] {
        guard hasChecksums(at: root) else { throw DiscChecksumsError.noChecksums }
        guard let data = try? Data(contentsOf: sumsURL(root)) else {
            throw DiscChecksumsError.unreadable(DiscChecksums.sumsName)
        }
        return try DiscChecksums.parse(String(decoding: data, as: UTF8.self))
    }

    /// Reads every listed file and compares its SHA-256 with the list. Blocks until done, so call
    /// it off the main thread. Throws `CancellationError` if the calling task is cancelled.
    /// `file` hears each file's result as soon as it's known.
    public static func verify(root: URL,
                              progress: @Sendable (ChecksumProgress) -> Void = { _ in },
                              file: @Sendable (String, FileCheck) -> Void = { _, _ in }) throws -> ChecksumReport {
        let entries = try entries(at: root)
        var report = ChecksumReport(info: info(at: root))

        // Match names in composed (NFC) form: macOS can report a disc's names decomposed.
        let onDisc = filesOnDisc(root)
        let listed = Set(entries.map { $0.path.precomposedStringWithCanonicalMapping })
        report.unexpected = onDisc.keys.filter { !listed.contains($0) }.sorted()

        let totalBytes = entries.reduce(UInt64(0)) { total, entry in
            total + (onDisc[entry.path.precomposedStringWithCanonicalMapping]?.size ?? 0)
        }
        var state = ChecksumProgress(checkedFiles: 0, totalFiles: entries.count, checkedBytes: 0, totalBytes: totalBytes)
        progress(state)

        for entry in entries {
            try Task.checkCancellation()
            guard let found = onDisc[entry.path.precomposedStringWithCanonicalMapping] else {
                report.missing.append(entry.path)
                file(entry.path, .missing)
                state.checkedFiles += 1
                progress(state)
                continue
            }
            switch hash(found.url, progress: { bytes in
                state.checkedBytes += bytes
                progress(state)
            }) {
            case .some(let digest) where digest == entry.digest:
                report.matched.append(entry.path)
                file(entry.path, .matched)
            case .some:
                report.changed.append(entry.path)
                file(entry.path, .changed)
            case .none:
                report.unreadable.append(entry.path)
                file(entry.path, .unreadable)
            }
            state.checkedFiles += 1
            progress(state)
        }
        return report
    }

    // MARK: - Helpers

    private static func sumsURL(_ root: URL) -> URL {
        root.appendingPathComponent(DiscChecksums.folderName).appendingPathComponent(DiscChecksums.sumsName)
    }

    /// Every file under `root` except the `.burn` folder, keyed by its NFC path from the root.
    static func filesOnDisc(_ root: URL) -> [String: (url: URL, size: UInt64)] {
        var result: [String: (url: URL, size: UInt64)] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
        while let relative = enumerator.nextObject() as? String {
            if relative == DiscChecksums.folderName {
                enumerator.skipDescendants()
                continue
            }
            if (relative as NSString).lastPathComponent == ".DS_Store" { continue }
            guard let attributes = enumerator.fileAttributes,
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            result[relative.precomposedStringWithCanonicalMapping] = (root.appendingPathComponent(relative), size)
        }
        return result
    }

    /// The file's SHA-256 in hex, or nil if it can't be read to the end.
    static func digest(of url: URL) -> String? {
        hash(url, progress: { _ in })
    }

    private static func hash(_ url: URL, progress: (UInt64) -> Void) -> String? {
        guard let input = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? input.close() }
        var hasher = SHA256()
        while true {
            let chunk: [UInt8]
            do {
                chunk = try input.readBytes(1024 * 1024)
            } catch {
                return nil
            }
            // None left means the end of the file.
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            progress(UInt64(chunk.count))
        }
        return DiscChecksums.hex(hasher.finalize())
    }
}

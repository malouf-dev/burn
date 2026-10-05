import Foundation

/// Two folders compared file by file, such as a restored disc set against the folder it was
/// burned from (decision D16).
public struct FolderComparison: Sendable, Equatable {
    /// Paths from each folder's top, in composed (NFC) form.
    public var matching: [String] = []
    /// In both, but with different contents.
    public var differing: [String] = []
    public var onlyInOriginal: [String] = []
    public var onlyInCopy: [String] = []

    public var isIdentical: Bool {
        differing.isEmpty && onlyInOriginal.isEmpty && onlyInCopy.isEmpty
    }

    /// Reads every file in both folders. Blocks until done, so call it off the main thread.
    /// Throws `CancellationError` if the calling task is cancelled. Skips `.DS_Store`, `.burn`
    /// folders and what Restore keeps for itself.
    public static func compare(original: URL, copy: URL,
                               progress: @Sendable (Double) -> Void = { _ in }) throws -> FolderComparison {
        let originals = files(in: original)
        let copies = files(in: copy)
        var result = FolderComparison()
        result.onlyInOriginal = originals.keys.filter { copies[$0] == nil }.sorted()
        result.onlyInCopy = copies.keys.filter { originals[$0] == nil }.sorted()

        let shared = originals.keys.filter { copies[$0] != nil }.sorted()
        let total = Double(max(1, shared.reduce(UInt64(0)) { $0 + (originals[$1]?.size ?? 0) }))
        var done = 0.0
        for path in shared {
            try Task.checkCancellation()
            guard let left = originals[path], let right = copies[path] else { continue }
            if left.size == right.size,
               let leftDigest = ChecksumVerifier.digest(of: left.url),
               leftDigest == ChecksumVerifier.digest(of: right.url) {
                result.matching.append(path)
            } else {
                result.differing.append(path)
            }
            done += Double(left.size)
            progress(done / total)
        }
        progress(1)
        return result
    }

    /// Every regular file under `root`, by its NFC path from the root, with its size.
    static func files(in root: URL) -> [String: (url: URL, size: UInt64)] {
        var result: [String: (url: URL, size: UInt64)] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return result }
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if name == DiscChecksums.folderName || name.hasPrefix(".burn-restore-") {
                enumerator.skipDescendants()
                continue
            }
            if name == ".DS_Store" || name == DiscRestore.stateName { continue }
            guard let attributes = enumerator.fileAttributes,
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            result[relative.precomposedStringWithCanonicalMapping] = (root.appendingPathComponent(relative), size)
        }
        return result
    }
}

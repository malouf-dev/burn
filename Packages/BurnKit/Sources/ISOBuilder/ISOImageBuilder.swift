import Foundation

public enum ISOBuilderError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case fileTooLarge(String)
    case unreadable(String)
    case changedWhileWriting(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "\(path) doesn't exist."
        case .fileTooLarge(let path): return "\(path) is 4 GB or larger. Files that size need UDF, which comes in a later version."
        case .unreadable(let path): return "Couldn't read \(path)."
        case .changedWhileWriting(let path): return "\(path) changed while the image was being written."
        }
    }
}

/// Builds an ISO 9660 image with Joliet names from files and folders on disk.
///
/// ISO 9660 level 1 names (8.3, upper case) serve old systems. Joliet carries the real names,
/// which macOS, Windows and Linux all read. Files must be under 4 GB.
public struct ISOImageBuilder {
    public var volumeName: String
    /// Zero blocks added at the end, so drives that read ahead past the data don't fail.
    public var paddingBlocks = 150
    /// Names skipped when adding folders.
    public var skippedNames: Set<String> = [".DS_Store"]
    /// Adds the hidden `.burn` folder with a checksum for every file (decision D12).
    public var includesChecksums = true
    /// Recorded in `.burn/info.json`.
    public var applicationName = "Burn"

    private let root = Node(name: "", source: nil, isDirectory: true, size: 0, date: Date())

    public init(volumeName: String) {
        self.volumeName = volumeName
    }

    /// Adds a file, or a folder with everything in it, at the top level of the disc.
    public mutating func add(_ url: URL) throws {
        let node = try Self.scan(url, skipping: skippedNames)
        root.children.append(node)
    }

    /// Adds everything inside a folder at the top level of the disc, without the folder itself.
    /// This is what disc tools usually do with a single folder: the disc takes the folder's place.
    public mutating func addContents(of folder: URL) throws {
        let node = try Self.scan(folder, skipping: skippedNames)
        guard node.isDirectory else {
            root.children.append(node)
            return
        }
        root.children += node.children
    }

    /// Total bytes of file data added so far.
    public var contentBytes: UInt64 {
        root.totalSize
    }

    /// Number of files added so far.
    public var fileCount: Int {
        root.fileCount
    }

    /// The image size in 2,048-byte blocks.
    public func blockCount() -> Int {
        Layout(root: imageRoot(date: Date()), paddingBlocks: paddingBlocks).totalBlocks
    }

    /// Writes the image and returns its size in blocks.
    @discardableResult
    public func write(to url: URL, date: Date = Date(), progress: ((Double) -> Void)? = nil) throws -> Int {
        let layout = Layout(root: imageRoot(date: date), paddingBlocks: paddingBlocks)
        let writer = try ImageWriter(url: url)
        defer { writer.close() }
        try layout.write(to: writer, volumeName: volumeName, date: date, progress: progress)
        return layout.totalBlocks
    }

    /// The tree to write: what was added, plus the `.burn` folder when checksums are on.
    private func imageRoot(date: Date) -> Node {
        guard includesChecksums else { return root }
        let top = Node(name: "", source: nil, isDirectory: true, size: 0, date: root.date)
        let folder = Node(name: DiscChecksums.folderName, source: nil, isDirectory: true, size: 0, date: date)
        folder.isHidden = true
        // Sized once the names on the disc are known, and written once every file is hashed.
        let sums = Node(name: DiscChecksums.sumsName, source: nil, isDirectory: false, size: 0, date: date)
        sums.generated = .checksums
        let info = DiscInfo(discName: volumeName, created: date, application: applicationName,
                            fileCount: root.fileCount, totalBytes: root.totalSize).encoded()
        let infoNode = Node(name: DiscChecksums.infoName, source: nil, isDirectory: false,
                            size: UInt64(info.count), date: date)
        infoNode.generated = .content(info)
        folder.children = [sums, infoNode]
        // A `.burn` folder copied from an earlier disc would describe that disc, so ours replaces it.
        top.children = [folder] + root.children.filter { $0.name != DiscChecksums.folderName }
        return top
    }

    // MARK: - Scanning

    private static func scan(_ url: URL, skipping: Set<String>) throws -> Node {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard FileManager.default.fileExists(atPath: url.path) else { throw ISOBuilderError.notFound(url.path) }
        let values = try url.resourceValues(forKeys: keys)
        let date = values.contentModificationDate ?? Date()
        if values.isDirectory == true {
            let node = Node(name: url.lastPathComponent, source: url, isDirectory: true, size: 0, date: date)
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if skipping.contains(child.lastPathComponent) { continue }
                let childValues = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
                if childValues.isSymbolicLink == true { continue }
                node.children.append(try scan(child, skipping: skipping))
            }
            return node
        }
        let size = UInt64(values.fileSize ?? 0)
        guard size < UInt64(UInt32.max) else { throw ISOBuilderError.fileTooLarge(url.path) }
        return Node(name: url.lastPathComponent, source: url, isDirectory: false, size: size, date: date)
    }
}

/// One file or folder in the image.
final class Node {
    /// Content made by the builder rather than read from a file.
    enum Generated {
        /// `.burn/SHA256SUMS`, written after every other file has been hashed.
        case checksums
        case content([UInt8])
    }

    let name: String
    let source: URL?
    let isDirectory: Bool
    var size: UInt64
    let date: Date
    var children: [Node] = []
    weak var parent: Node?
    var generated: Generated?
    var isHidden = false

    var isoName = ""
    var jolietName = ""
    var isoNumber = 0
    var jolietNumber = 0
    var isoExtent: UInt32 = 0
    var isoSize = 0
    var jolietExtent: UInt32 = 0
    var jolietSize = 0
    var fileExtent: UInt32 = 0

    init(name: String, source: URL?, isDirectory: Bool, size: UInt64, date: Date) {
        self.name = name
        self.source = source
        self.isDirectory = isDirectory
        self.size = size
        self.date = date
    }

    var totalSize: UInt64 {
        isDirectory ? children.reduce(0) { $0 + $1.totalSize } : size
    }

    var fileCount: Int {
        isDirectory ? children.reduce(0) { $0 + $1.fileCount } : 1
    }

    var blocks: Int {
        Int((size + 2047) / 2048)
    }
}

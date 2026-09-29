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

    private let root = Node(name: "", source: nil, isDirectory: true, size: 0, date: Date())

    public init(volumeName: String) {
        self.volumeName = volumeName
    }

    /// Adds a file, or a folder with everything in it, at the top level of the disc.
    public mutating func add(_ url: URL) throws {
        let node = try Self.scan(url, skipping: skippedNames)
        root.children.append(node)
    }

    /// Total bytes of file data added so far.
    public var contentBytes: UInt64 {
        root.totalSize
    }

    /// The image size in 2,048-byte blocks.
    public func blockCount() -> Int {
        Layout(root: root, paddingBlocks: paddingBlocks).totalBlocks
    }

    /// Writes the image and returns its size in blocks.
    @discardableResult
    public func write(to url: URL, date: Date = Date(), progress: ((Double) -> Void)? = nil) throws -> Int {
        let layout = Layout(root: root, paddingBlocks: paddingBlocks)
        let writer = try ImageWriter(url: url)
        defer { writer.close() }
        try layout.write(to: writer, volumeName: volumeName, date: date, progress: progress)
        return layout.totalBlocks
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
    let name: String
    let source: URL?
    let isDirectory: Bool
    let size: UInt64
    let date: Date
    var children: [Node] = []
    weak var parent: Node?

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

    var blocks: Int {
        Int((size + 2047) / 2048)
    }
}

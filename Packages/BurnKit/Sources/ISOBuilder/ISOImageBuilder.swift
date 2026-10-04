import Foundation

public enum ISOBuilderError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case fileTooLarge(String)
    case fileTooLargeForDisc(String)
    case unreadable(String)
    case changedWhileWriting(String)

    public var description: String {
        switch self {
        case .notFound(let path): return "\(path) doesn't exist."
        case .fileTooLarge(let path): return "\(path) is 4 GB or larger. Files that size need UDF, which is turned off."
        case .fileTooLargeForDisc(let path): return "\(path) is larger than any disc holds."
        case .unreadable(let path): return "Couldn't read \(path)."
        case .changedWhileWriting(let path): return "\(path) changed while the image was being written."
        }
    }
}

/// Builds a disc image from files and folders on disk (decision D14).
///
/// The image is a UDF 2.01 bridge: UDF carries the real names and files of any size, and every
/// current system reads it. ISO 9660 and Joliet describe the same file data for older systems:
/// level 1 names (8.3, upper case) and Joliet's longer ones. Files of 4 GB or more are in UDF only.
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
    /// Adds UDF 2.01 alongside ISO 9660 and Joliet. Without it, files must be under 4 GB.
    public var includesUDF = true

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
        Layout(root: imageRoot(date: Date()), paddingBlocks: paddingBlocks, includesUDF: includesUDF).totalBlocks
    }

    /// The image, made block by block as it's read, for burning with no file in between.
    /// Later changes to the builder don't affect it.
    public func image(date: Date = Date()) throws -> DiscImage {
        if let file = root.first(where: { !$0.isDirectory && $0.size > UDF.maxFileSize }) {
            throw ISOBuilderError.fileTooLargeForDisc(file.source?.path ?? file.name)
        }
        if !includesUDF, let file = root.first(where: { !$0.inISO }) {
            throw ISOBuilderError.fileTooLarge(file.source?.path ?? file.name)
        }
        let layout = Layout(root: imageRoot(date: date), paddingBlocks: paddingBlocks, includesUDF: includesUDF)
        return DiscImage(layout: layout, volumeName: volumeName, date: date)
    }

    /// Writes the image to a file and returns its size in blocks.
    @discardableResult
    public func write(to url: URL, date: Date = Date(), progress: ((Double) -> Void)? = nil) throws -> Int {
        let disc = try image(date: date)
        try disc.write(to: url, progress: progress)
        return disc.blockCount
    }

    /// The tree to write: a copy of what was added, so each image lays out its own, plus the
    /// `.burn` folder when checksums are on.
    private func imageRoot(date: Date) -> Node {
        let top = Node(name: "", source: nil, isDirectory: true, size: 0, date: root.date)
        top.children = root.children.map { $0.copy() }
        guard includesChecksums else { return top }
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
        top.children = [folder] + top.children.filter { $0.name != DiscChecksums.folderName }
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
    var udfName = ""
    /// Block of the File Entry, within the UDF partition.
    var udfEntry: UInt32 = 0
    var udfUniqueID: UInt64 = 0
    /// Folders: where their File Identifier Descriptors start, within the partition, and their length.
    var udfDirectoryBlock: UInt32 = 0
    var udfDirectorySize = 0

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

    /// Whether ISO 9660 and Joliet can list it: every folder, and files under 4 GB.
    var inISO: Bool {
        isDirectory || size < UInt64(UInt32.max)
    }

    /// A copy of this node and everything below it, without any layout.
    func copy() -> Node {
        let node = Node(name: name, source: source, isDirectory: isDirectory, size: size, date: date)
        node.generated = generated
        node.isHidden = isHidden
        node.children = children.map { $0.copy() }
        return node
    }

    /// This node or the first below it that matches, depth first.
    func first(where predicate: (Node) -> Bool) -> Node? {
        if predicate(self) { return self }
        for child in children {
            if let found = child.first(where: predicate) { return found }
        }
        return nil
    }
}

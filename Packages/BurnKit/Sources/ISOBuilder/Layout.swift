import Foundation

let sectorSize = 2048

/// Where everything goes in the image, worked out before any bytes are written.
///
/// With UDF, the image is a bridge (decision D14): UDF 2.01 and ISO 9660 with Joliet describe the
/// same file data. Sectors 19-21 hold the UDF recognition sequence, 32-65 its volume descriptors,
/// 256 its anchor, and from 257 its partition: the File Set Descriptor, a File Entry for every file
/// and folder, and the folders' contents. The ISO 9660 and Joliet structures follow, then the files.
struct Layout {
    let root: Node
    let paddingBlocks: Int
    let includesUDF: Bool
    /// Directories in ISO path table order, and in Joliet path table order.
    private(set) var isoDirectories: [Node] = []
    private(set) var jolietDirectories: [Node] = []
    private(set) var files: [Node] = []
    /// `.burn/SHA256SUMS`, when the image carries checksums.
    private(set) var checksumsNode: Node?
    private(set) var isoPathTableSize = 0
    private(set) var jolietPathTableSize = 0
    private(set) var isoPathTableL: UInt32 = 0
    private(set) var isoPathTableM: UInt32 = 0
    private(set) var jolietPathTableL: UInt32 = 0
    private(set) var jolietPathTableM: UInt32 = 0
    private(set) var dataEnd: UInt32 = 0
    private(set) var totalBlocks = 0
    /// Every file and folder, root first, in the order of their UDF File Entries.
    private(set) var udfNodes: [Node] = []
    private(set) var udfPartitionLength: UInt32 = 0
    private(set) var udfNextUniqueID: UInt64 = 16

    init(root: Node, paddingBlocks: Int, includesUDF: Bool) {
        self.root = root
        self.paddingBlocks = paddingBlocks
        self.includesUDF = includesUDF
        root.parent = root
        assignNames(root)
        isoDirectories = pathTableOrder(key: { $0.isoName })
        jolietDirectories = pathTableOrder(key: { $0.jolietName })
        for (index, directory) in isoDirectories.enumerated() { directory.isoNumber = index + 1 }
        for (index, directory) in jolietDirectories.enumerated() { directory.jolietNumber = index + 1 }
        collectFiles(root)
        // Generated files go last, so every other file is hashed before SHA256SUMS is written.
        files = files.filter { $0.generated == nil } + files.filter { $0.generated != nil }
        checksumsNode = files.first { node in
            if case .checksums? = node.generated { return true }
            return false
        }
        if let checksumsNode {
            checksumsNode.size = UInt64(files.filter { $0.generated == nil }
                .reduce(0) { $0 + DiscChecksums.lineLength(path: discPath($1)) })
        }

        isoPathTableSize = isoDirectories.reduce(0) { $0 + Self.pathRecordLength(identifierLength: $1 === root ? 1 : $1.isoName.utf8.count) }
        jolietPathTableSize = jolietDirectories.reduce(0) { $0 + Self.pathRecordLength(identifierLength: $1 === root ? 1 : Names.jolietIdentifier($1.jolietName, isDirectory: true).count) }

        for directory in isoDirectories {
            directory.isoSize = Self.directorySize(recordLengths: recordLengths(directory, joliet: false))
        }
        for directory in jolietDirectories {
            directory.jolietSize = Self.directorySize(recordLengths: recordLengths(directory, joliet: true))
        }

        if includesUDF {
            udfNodes = udfOrder()
            // The root's unique ID is 0. UDF reserves 1 to 15, so the rest count from 16.
            for (index, node) in udfNodes.enumerated() { node.udfUniqueID = index == 0 ? 0 : UInt64(15 + index) }
            udfNextUniqueID = UInt64(15 + udfNodes.count)
            for directory in udfNodes where directory.isDirectory {
                directory.udfDirectorySize = udfSortedChildren(directory).reduce(UDF.identifierLength(nameBytes: 0)) {
                    $0 + UDF.identifierLength(nameBytes: UDF.cs0($1.udfName).count)
                }
            }
        }

        // Sectors 0-15 are the system area, 16-18 the ISO 9660 volume descriptors.
        var next: UInt32 = 19
        func take(_ bytes: Int) -> UInt32 {
            let start = next
            next += UInt32((bytes + sectorSize - 1) / sectorSize)
            return start
        }
        if includesUDF {
            // Blocks 0 and 1 of the partition hold the File Set Descriptor and its terminator.
            next = UDF.partitionStart + 2
            for node in udfNodes {
                node.udfEntry = next - UDF.partitionStart
                next += 1
            }
            for directory in udfNodes where directory.isDirectory {
                directory.udfDirectoryBlock = take(directory.udfDirectorySize) - UDF.partitionStart
            }
        }
        isoPathTableL = take(isoPathTableSize)
        isoPathTableM = take(isoPathTableSize)
        jolietPathTableL = take(jolietPathTableSize)
        jolietPathTableM = take(jolietPathTableSize)
        for directory in isoDirectories { directory.isoExtent = take(directory.isoSize) }
        for directory in jolietDirectories { directory.jolietExtent = take(directory.jolietSize) }
        for file in files { file.fileExtent = take(Int(file.size)) }
        dataEnd = next
        if includesUDF {
            // The last block holds the second anchor, and the partition runs up to it.
            totalBlocks = Int(next) + max(paddingBlocks, 1)
            udfPartitionLength = UInt32(totalBlocks - 1) - UDF.partitionStart
        } else {
            totalBlocks = Int(next) + paddingBlocks
        }
    }

    // MARK: - Names and ordering

    private func assignNames(_ directory: Node) {
        var usedISO = Set<String>()
        var usedJoliet = Set<String>()
        var usedUDF = Set<String>()
        for child in directory.children {
            child.parent = directory
            if child.inISO {
                var index = 0
                var iso = Names.iso(child.name, isDirectory: child.isDirectory)
                while usedISO.contains(iso) {
                    index += 1
                    iso = Names.iso(child.name, isDirectory: child.isDirectory, index: index)
                }
                usedISO.insert(iso)
                child.isoName = iso

                index = 0
                var joliet = Names.joliet(child.name, isDirectory: child.isDirectory)
                while usedJoliet.contains(joliet.lowercased()) {
                    index += 1
                    joliet = Names.joliet(child.name, isDirectory: child.isDirectory, index: index)
                }
                usedJoliet.insert(joliet.lowercased())
                child.jolietName = joliet
            }

            if includesUDF {
                var index = 0
                var udf = Names.udf(child.name, isDirectory: child.isDirectory)
                while usedUDF.contains(udf.lowercased()) {
                    index += 1
                    udf = Names.udf(child.name, isDirectory: child.isDirectory, index: index)
                }
                usedUDF.insert(udf.lowercased())
                child.udfName = udf
            }
            if child.isDirectory { assignNames(child) }
        }
    }

    /// Breadth-first, each directory's subdirectories sorted by identifier, as ECMA-119 requires.
    private func pathTableOrder(key: (Node) -> String) -> [Node] {
        var order = [root]
        var level = [root]
        while !level.isEmpty {
            var nextLevel: [Node] = []
            for directory in level {
                let subdirectories = directory.children.filter(\.isDirectory)
                    .sorted { Self.identifierOrder(key($0), key($1)) }
                nextLevel += subdirectories
            }
            order += nextLevel
            level = nextLevel
        }
        return order
    }

    /// Every node, breadth first, each folder's children sorted by UDF name.
    private func udfOrder() -> [Node] {
        var order = [root]
        var index = 0
        while index < order.count {
            let node = order[index]
            index += 1
            if node.isDirectory { order += udfSortedChildren(node) }
        }
        return order
    }

    func udfSortedChildren(_ directory: Node) -> [Node] {
        directory.children.sorted { Self.identifierOrder($0.udfName, $1.udfName) }
    }

    /// A file's path from the root as it reads on the disc. That's through UDF names when the disc
    /// has UDF, since every current system reads UDF first, and through Joliet names when it doesn't.
    func discPath(_ node: Node) -> String {
        var parts: [String] = []
        var current = node
        while current !== root {
            parts.append(includesUDF ? current.udfName : current.jolietName)
            guard let parent = current.parent else { break }
            current = parent
        }
        return parts.reversed().joined(separator: "/")
    }

    static func identifierOrder(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf16).lexicographicallyPrecedes(Array(rhs.utf16))
    }

    /// Every file, including those too large for ISO 9660, which only UDF lists.
    private mutating func collectFiles(_ directory: Node) {
        for child in directory.children.sorted(by: { Self.identifierOrder($0.name, $1.name) }) {
            if child.isDirectory {
                collectFiles(child)
            } else {
                files.append(child)
            }
        }
    }

    /// A folder's children in the ISO 9660 or Joliet tree, which leaves out files of 4 GB or more.
    func sortedChildren(_ directory: Node, joliet: Bool) -> [Node] {
        directory.children.filter(\.inISO).sorted {
            joliet ? Self.identifierOrder($0.jolietName, $1.jolietName) : Self.identifierOrder($0.isoName, $1.isoName)
        }
    }

    // MARK: - Sizes

    static func pathRecordLength(identifierLength: Int) -> Int {
        8 + identifierLength + (identifierLength % 2)
    }

    static func recordLength(identifierLength: Int) -> Int {
        let length = 33 + identifierLength
        return length + (length % 2)
    }

    private func recordLengths(_ directory: Node, joliet: Bool) -> [Int] {
        var lengths = [Self.recordLength(identifierLength: 1), Self.recordLength(identifierLength: 1)]
        for child in sortedChildren(directory, joliet: joliet) {
            let identifier = joliet ? Names.jolietIdentifier(child.jolietName, isDirectory: child.isDirectory).count
                                    : child.isoName.utf8.count
            lengths.append(Self.recordLength(identifierLength: identifier))
        }
        return lengths
    }

    /// Records may not cross a sector boundary, so a record that doesn't fit starts the next sector.
    static func directorySize(recordLengths: [Int]) -> Int {
        var offset = 0
        for length in recordLengths {
            let used = offset % sectorSize
            if used + length > sectorSize { offset += sectorSize - used }
            offset += length
        }
        return (offset + sectorSize - 1) / sectorSize * sectorSize
    }
}

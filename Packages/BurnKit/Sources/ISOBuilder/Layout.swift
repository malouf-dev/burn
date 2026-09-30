import Foundation

let sectorSize = 2048

/// Where everything goes in the image, worked out before any bytes are written.
struct Layout {
    let root: Node
    let paddingBlocks: Int
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

    init(root: Node, paddingBlocks: Int) {
        self.root = root
        self.paddingBlocks = paddingBlocks
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
                .reduce(0) { $0 + DiscChecksums.lineLength(path: jolietPath($1)) })
        }

        isoPathTableSize = isoDirectories.reduce(0) { $0 + Self.pathRecordLength(identifierLength: $1 === root ? 1 : $1.isoName.utf8.count) }
        jolietPathTableSize = jolietDirectories.reduce(0) { $0 + Self.pathRecordLength(identifierLength: $1 === root ? 1 : Names.jolietIdentifier($1.jolietName, isDirectory: true).count) }

        for directory in isoDirectories {
            directory.isoSize = Self.directorySize(recordLengths: recordLengths(directory, joliet: false))
        }
        for directory in jolietDirectories {
            directory.jolietSize = Self.directorySize(recordLengths: recordLengths(directory, joliet: true))
        }

        // Sectors 0-15 are the system area, 16-18 the volume descriptors.
        var next: UInt32 = 19
        func take(_ bytes: Int) -> UInt32 {
            let start = next
            next += UInt32((bytes + sectorSize - 1) / sectorSize)
            return start
        }
        isoPathTableL = take(isoPathTableSize)
        isoPathTableM = take(isoPathTableSize)
        jolietPathTableL = take(jolietPathTableSize)
        jolietPathTableM = take(jolietPathTableSize)
        for directory in isoDirectories { directory.isoExtent = take(directory.isoSize) }
        for directory in jolietDirectories { directory.jolietExtent = take(directory.jolietSize) }
        for file in files { file.fileExtent = take(Int(file.size)) }
        dataEnd = next
        totalBlocks = Int(next) + paddingBlocks
    }

    // MARK: - Names and ordering

    private func assignNames(_ directory: Node) {
        var usedISO = Set<String>()
        var usedJoliet = Set<String>()
        for child in directory.children {
            child.parent = directory
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

    /// A file's path from the root as it reads on the disc, through its Joliet names.
    func jolietPath(_ node: Node) -> String {
        var parts: [String] = []
        var current = node
        while current !== root {
            parts.append(current.jolietName)
            guard let parent = current.parent else { break }
            current = parent
        }
        return parts.reversed().joined(separator: "/")
    }

    static func identifierOrder(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf16).lexicographicallyPrecedes(Array(rhs.utf16))
    }

    private mutating func collectFiles(_ directory: Node) {
        for child in sortedChildren(directory, joliet: false) {
            if child.isDirectory {
                collectFiles(child)
            } else {
                files.append(child)
            }
        }
    }

    func sortedChildren(_ directory: Node, joliet: Bool) -> [Node] {
        directory.children.sorted {
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

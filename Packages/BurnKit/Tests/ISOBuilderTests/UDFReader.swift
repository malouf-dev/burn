import Foundation

/// A minimal UDF reader, written separately from the builder from ECMA-167 and UDF 2.01, to check
/// its output. Every descriptor it reads must have a valid tag: identifier, checksum, CRC and location.
struct UDFReader {
    struct Problem: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    struct FileEntry {
        var fileType: UInt8
        var size: UInt64
        var extents: [(length: UInt32, block: UInt32)]
        var uniqueID: UInt64
        var linkCount: UInt16
    }

    struct Identifier {
        var name: String
        var isDirectory: Bool
        var isHidden: Bool
        var isParent: Bool
        var entryBlock: UInt32
        var uniqueID: UInt32
    }

    let bytes: [UInt8]
    let partitionStart: Int
    let partitionLength: Int
    let rootBlock: UInt32
    let volumeName: String
    let integrity: (fileCount: UInt32, directoryCount: UInt32, nextUniqueID: UInt64)

    init(url: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        self.bytes = bytes
        let sectors = bytes.count / 2048

        for (index, identifier) in ["BEA01", "NSR03", "TEA01"].enumerated() {
            let start = (19 + index) * 2048
            guard Array(bytes[(start + 1)..<(start + 6)]) == Array(identifier.utf8) else {
                throw Problem("No \(identifier) in sector \(19 + index)")
            }
        }

        // Both anchors, and both copies of the volume descriptor sequence.
        let anchor = 256 * 2048
        try Self.checkTag(bytes, at: anchor, id: 2, location: 256)
        try Self.checkTag(bytes, at: (sectors - 1) * 2048, id: 2, location: UInt32(sectors - 1))
        var partitionStart: Int?
        var partitionLength = 0
        var fileSetBlock: UInt32?
        var volumeName = ""
        var integrityExtent: UInt32?
        for sequence in [anchor + 16, anchor + 24] {
            let length = Int(Self.le32(bytes, sequence))
            let location = Int(Self.le32(bytes, sequence + 4))
            guard length >= 16 * 2048 else { throw Problem("Volume descriptor sequence is under 16 sectors") }
            var terminated = false
            for sector in location..<(location + length / 2048) {
                let offset = sector * 2048
                let id = Self.le16(bytes, offset)
                try Self.checkTag(bytes, at: offset, id: id, location: UInt32(sector))
                switch id {
                case 5:
                    guard Self.regid(bytes, offset + 24) == "+NSR03" else { throw Problem("Partition isn't +NSR03") }
                    partitionStart = Int(Self.le32(bytes, offset + 188))
                    partitionLength = Int(Self.le32(bytes, offset + 192))
                case 6:
                    guard Self.le32(bytes, offset + 212) == 2048 else { throw Problem("Block size isn't 2048") }
                    guard Self.regid(bytes, offset + 216) == "*OSTA UDF Compliant",
                          Self.le16(bytes, offset + 216 + 24) == 0x0201 else { throw Problem("Domain isn't UDF 2.01") }
                    guard bytes[offset + 440] == 1, Self.le32(bytes, offset + 268) == 1 else {
                        throw Problem("Expected one type 1 partition map")
                    }
                    fileSetBlock = Self.le32(bytes, offset + 248 + 4)
                    volumeName = Self.dstring(bytes, offset + 84, length: 128)
                    integrityExtent = Self.le32(bytes, offset + 436)
                case 8:
                    terminated = true
                default:
                    break
                }
                if terminated { break }
            }
            guard terminated else { throw Problem("Volume descriptor sequence has no terminator") }
        }
        guard let partitionStart, let fileSetBlock, let integrityExtent else {
            throw Problem("Missing the partition or logical volume descriptor")
        }
        guard partitionStart + partitionLength <= sectors else { throw Problem("Partition runs past the image") }

        let integrity = Int(integrityExtent) * 2048
        try Self.checkTag(bytes, at: integrity, id: 9, location: integrityExtent)
        guard Self.le32(bytes, integrity + 28) == 1 else { throw Problem("Logical volume isn't closed") }
        let useLength = Int(Self.le32(bytes, integrity + 76))
        let use = integrity + 80 + 8 * Int(Self.le32(bytes, integrity + 72))
        guard useLength >= 46 else { throw Problem("Integrity implementation use is too short") }
        self.integrity = (Self.le32(bytes, use + 32), Self.le32(bytes, use + 36),
                          UInt64(Self.le32(bytes, integrity + 40)) | UInt64(Self.le32(bytes, integrity + 44)) << 32)

        let fileSet = (partitionStart + Int(fileSetBlock)) * 2048
        try Self.checkTag(bytes, at: fileSet, id: 256, location: fileSetBlock)
        self.partitionStart = partitionStart
        self.partitionLength = partitionLength
        self.rootBlock = Self.le32(bytes, fileSet + 400 + 4)
        self.volumeName = volumeName
    }

    // MARK: - Files

    func fileEntry(block: UInt32) throws -> FileEntry {
        let offset = (partitionStart + Int(block)) * 2048
        try Self.checkTag(bytes, at: offset, id: 261, location: block)
        guard Self.le16(bytes, offset + 34) & 0x7 == 0 else { throw Problem("Expected short allocation descriptors") }
        let extendedLength = Int(Self.le32(bytes, offset + 168))
        let allocationLength = Int(Self.le32(bytes, offset + 172))
        var extents: [(length: UInt32, block: UInt32)] = []
        var position = offset + 176 + extendedLength
        while position < offset + 176 + extendedLength + allocationLength {
            extents.append((Self.le32(bytes, position) & 0x3FFF_FFFF, Self.le32(bytes, position + 4)))
            position += 8
        }
        let size = UInt64(Self.le32(bytes, offset + 56)) | UInt64(Self.le32(bytes, offset + 60)) << 32
        let uniqueID = UInt64(Self.le32(bytes, offset + 160)) | UInt64(Self.le32(bytes, offset + 164)) << 32
        return FileEntry(fileType: bytes[offset + 27], size: size, extents: extents, uniqueID: uniqueID,
                         linkCount: Self.le16(bytes, offset + 48))
    }

    func contents(_ entry: FileEntry) -> [UInt8] {
        var data: [UInt8] = []
        for extent in entry.extents {
            let start = (partitionStart + Int(extent.block)) * 2048
            data += bytes[start..<(start + Int(extent.length))]
        }
        return Array(data.prefix(Int(entry.size)))
    }

    /// A folder's File Identifier Descriptors, parent first.
    func identifiers(_ directory: FileEntry) throws -> [Identifier] {
        guard directory.fileType == 4 else { throw Problem("Not a folder") }
        let data = contents(directory)
        let firstBlock = directory.extents.first?.block ?? 0
        var result: [Identifier] = []
        var position = 0
        while position < data.count {
            try Self.checkTag(data, at: position, id: 257, location: firstBlock + UInt32(position / 2048))
            let characteristics = data[position + 18]
            let nameLength = Int(data[position + 19])
            let useLength = Int(Self.le16(data, position + 36))
            let nameStart = position + 38 + useLength
            result.append(Identifier(name: Self.cs0(Array(data[nameStart..<(nameStart + nameLength)])),
                                     isDirectory: characteristics & 0x02 != 0, isHidden: characteristics & 0x01 != 0,
                                     isParent: characteristics & 0x08 != 0, entryBlock: Self.le32(data, position + 24),
                                     uniqueID: Self.le32(data, position + 32)))
            position += (38 + useLength + nameLength + 3) / 4 * 4
        }
        return result
    }

    /// Path to file contents, read through the UDF tree, with each File Entry checked against
    /// the identifier that points to it.
    func files() throws -> [String: [UInt8]] {
        var result: [String: [UInt8]] = [:]
        func walk(_ block: UInt32, prefix: String) throws {
            let directory = try fileEntry(block: block)
            let entries = try identifiers(directory)
            guard entries.first?.isParent == true else { throw Problem("\(prefix): no parent entry first") }
            let subdirectories = entries.dropFirst().filter(\.isDirectory).count
            guard Int(directory.linkCount) == 1 + subdirectories else { throw Problem("\(prefix): link count") }
            for entry in entries.dropFirst() {
                let path = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
                let child = try fileEntry(block: entry.entryBlock)
                guard UInt32(truncatingIfNeeded: child.uniqueID) == entry.uniqueID else {
                    throw Problem("\(path): unique ID differs from its entry")
                }
                if entry.isDirectory {
                    try walk(entry.entryBlock, prefix: path)
                } else {
                    guard child.fileType == 5 else { throw Problem("\(path): not a file") }
                    result[path] = contents(child)
                }
            }
        }
        try walk(rootBlock, prefix: "")
        return result
    }

    /// The root folder's entries other than its parent.
    func rootEntries() throws -> [Identifier] {
        Array(try identifiers(try fileEntry(block: rootBlock)).dropFirst())
    }

    // MARK: - Fields

    static func checkTag(_ bytes: [UInt8], at offset: Int, id: UInt16, location: UInt32) throws {
        let found = le16(bytes, offset)
        guard found == id else { throw Problem("Expected tag \(id) at byte \(offset), found \(found)") }
        guard le16(bytes, offset + 2) == 3 else { throw Problem("Tag \(id) isn't version 3") }
        var checksum: UInt8 = 0
        for index in 0..<16 where index != 4 { checksum &+= bytes[offset + index] }
        guard checksum == bytes[offset + 4] else { throw Problem("Tag \(id) at byte \(offset): bad checksum") }
        let length = Int(le16(bytes, offset + 10))
        guard crc(bytes[(offset + 16)..<(offset + 16 + length)]) == le16(bytes, offset + 8) else {
            throw Problem("Tag \(id) at byte \(offset): bad CRC")
        }
        guard le32(bytes, offset + 12) == location else {
            throw Problem("Tag \(id) at byte \(offset): location \(le32(bytes, offset + 12)), expected \(location)")
        }
    }

    /// CRC-ITU-T, bit by bit, as ECMA-167 1/7.2.6 describes it.
    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    static func cs0(_ bytes: [UInt8]) -> String {
        guard let compression = bytes.first else { return "" }
        let body = bytes.dropFirst()
        if compression == 8 { return String(decoding: body.map { UInt16($0) }, as: UTF16.self) }
        var units: [UInt16] = []
        var index = body.startIndex
        while index + 1 < body.endIndex {
            units.append(UInt16(body[index]) << 8 | UInt16(body[index + 1]))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func dstring(_ bytes: [UInt8], _ offset: Int, length: Int) -> String {
        let used = Int(bytes[offset + length - 1])
        return cs0(Array(bytes[offset..<(offset + used)]))
    }

    static func regid(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[(offset + 1)..<(offset + 24)].prefix { $0 != 0 }, as: UTF8.self)
    }

    static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

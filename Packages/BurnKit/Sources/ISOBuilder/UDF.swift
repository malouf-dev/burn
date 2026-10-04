import Foundation

/// Encoders for UDF 2.01 structures (ECMA-167 3rd edition, as profiled by OSTA UDF 2.01).
///
/// Every structure here is written from those two standards. Offsets in comments are byte
/// offsets within the structure, as the standards number them.
enum UDF {
    static let revision: UInt16 = 0x0201
    /// Sectors of the volume structures, fixed by the layout.
    static let volumeRecognition: UInt32 = 19
    static let mainSequence: UInt32 = 32
    static let reserveSequence: UInt32 = 48
    static let sequenceBlocks: UInt32 = 16
    static let integritySequence: UInt32 = 64
    static let anchor: UInt32 = 256
    static let partitionStart: UInt32 = 257
    /// The largest single extent: under 1 GB and a whole number of blocks.
    static let maxExtent: UInt64 = (1 << 30) - UInt64(sectorSize)
    /// Allocation descriptors that fit in one File Entry block after its fixed part.
    static let maxExtentsPerEntry = (sectorSize - 176) / 8
    /// The largest file one File Entry can describe, about 250 GB, more than any disc holds.
    static let maxFileSize = UInt64(maxExtentsPerEntry) * maxExtent

    enum TagID: UInt16 {
        case primaryVolume = 1
        case anchor = 2
        case implementationUse = 4
        case partition = 5
        case logicalVolume = 6
        case unallocatedSpace = 7
        case terminating = 8
        case logicalVolumeIntegrity = 9
        case fileSet = 256
        case fileIdentifier = 257
        case fileEntry = 261
    }

    // MARK: - Basic fields

    /// Fills in a descriptor tag (ECMA-167 3/7.2) over bytes already laid out in `descriptor`.
    /// The CRC covers everything after the 16-byte tag.
    static func finishTag(_ descriptor: inout [UInt8], _ id: TagID, location: UInt32) {
        put16(&descriptor, id.rawValue, at: 0)
        put16(&descriptor, 3, at: 2) // descriptor version 3, for NSR03
        descriptor[4] = 0
        descriptor[5] = 0
        put16(&descriptor, 1, at: 6) // tag serial number
        let crcLength = descriptor.count - 16
        put16(&descriptor, crc(descriptor[16...]), at: 8)
        put16(&descriptor, UInt16(crcLength), at: 10)
        put32(&descriptor, location, at: 12)
        var checksum: UInt8 = 0
        for index in 0..<16 where index != 4 { checksum &+= descriptor[index] }
        descriptor[4] = checksum
    }

    /// CRC-ITU-T: polynomial 0x1021, starting from zero (ECMA-167 1/7.2.6).
    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc = (crc << 8) ^ crcTable[Int(UInt8(crc >> 8) ^ byte)]
        }
        return crc
    }

    private static let crcTable: [UInt16] = (0..<256).map { index -> UInt16 in
        var value = UInt16(index) << 8
        for _ in 0..<8 { value = value & 0x8000 != 0 ? (value << 1) ^ 0x1021 : value << 1 }
        return value
    }

    /// OSTA Compressed Unicode: 8 bits per character when every character fits, else 16, big-endian.
    static func cs0(_ text: String) -> [UInt8] {
        let units = Array(text.utf16)
        if units.allSatisfy({ $0 <= 0xFF }) { return [8] + units.map { UInt8($0) } }
        var bytes: [UInt8] = [16]
        for unit in units { bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        return bytes
    }

    /// A fixed-length dstring: CS0 bytes, zero padding, and the used length in the last byte.
    static func dstring(_ text: String, length: Int) -> [UInt8] {
        var field = [UInt8](repeating: 0, count: length)
        var fitted = text
        var bytes = cs0(fitted)
        while bytes.count > length - 1 {
            fitted.removeLast()
            bytes = cs0(fitted)
        }
        guard !fitted.isEmpty else { return field }
        field.replaceSubrange(0..<bytes.count, with: bytes)
        field[length - 1] = UInt8(bytes.count)
        return field
    }

    /// The character set every UDF string uses.
    static let charspec: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 64)
        let name = Array("OSTA Compressed Unicode".utf8)
        bytes.replaceSubrange(1...name.count, with: name)
        return bytes
    }()

    /// An entity identifier (regid): flags, a 23-byte identifier and an 8-byte suffix.
    static func regid(_ identifier: String, suffix: [UInt8] = []) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let name = Array(identifier.utf8.prefix(23))
        bytes.replaceSubrange(1..<(1 + name.count), with: name)
        bytes.replaceSubrange(24..<(24 + suffix.count), with: suffix)
        return bytes
    }

    /// Who wrote the disc, as UDF asks every structure to record.
    static let implementation = regid("*Burn")
    /// The domain that marks the logical volume as UDF, with the revision it follows.
    static let domain = regid("*OSTA UDF Compliant", suffix: [UInt8(revision & 0xFF), UInt8(revision >> 8)])
    static let lvInfo = regid("*UDF LV Info", suffix: [UInt8(revision & 0xFF), UInt8(revision >> 8)])

    /// extent_ad: a length in bytes and a sector.
    static func extent(length: UInt32, location: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8)
        put32(&bytes, length, at: 0)
        put32(&bytes, location, at: 4)
        return bytes
    }

    /// long_ad: a length, a block in partition 0, and, for File Identifiers, the target's unique ID.
    static func longAD(length: UInt32, block: UInt32, uniqueID: UInt32 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        put32(&bytes, length, at: 0)
        put32(&bytes, block, at: 4)
        put32(&bytes, uniqueID, at: 12)
        return bytes
    }

    /// short_ad pieces for `size` bytes from `block`, each under 1 GB.
    static func shortADs(size: UInt64, block: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = size
        var next = block
        while remaining > 0 {
            let length = min(remaining, maxExtent)
            var ad = [UInt8](repeating: 0, count: 8)
            put32(&ad, UInt32(length), at: 0)
            put32(&ad, next, at: 4)
            bytes += ad
            remaining -= length
            next += UInt32(length / UInt64(sectorSize))
        }
        return bytes
    }

    static func blocks(_ bytes: UInt64) -> UInt64 {
        (bytes + UInt64(sectorSize) - 1) / UInt64(sectorSize)
    }

    /// A File Identifier Descriptor's length: 38 bytes, the name, padded to four bytes.
    static func identifierLength(nameBytes: Int) -> Int {
        (38 + nameBytes + 3) / 4 * 4
    }

    // MARK: - Volume recognition

    /// BEA01, NSR03 and TEA01, which tell readers a UDF volume follows the ISO 9660 descriptors.
    static func recognitionSequence() -> [UInt8] {
        ["BEA01", "NSR03", "TEA01"].flatMap { identifier -> [UInt8] in
            var sector = [UInt8](repeating: 0, count: sectorSize)
            sector.replaceSubrange(1..<6, with: Array(identifier.utf8))
            sector[6] = 1
            return sector
        }
    }
}

func put16(_ bytes: inout [UInt8], _ value: UInt16, at offset: Int) {
    bytes[offset] = UInt8(value & 0xFF)
    bytes[offset + 1] = UInt8(value >> 8)
}

func put32(_ bytes: inout [UInt8], _ value: UInt32, at offset: Int) {
    littleEndian32(&bytes, value, at: offset)
}

func put64(_ bytes: inout [UInt8], _ value: UInt64, at offset: Int) {
    put32(&bytes, UInt32(truncatingIfNeeded: value), at: offset)
    put32(&bytes, UInt32(truncatingIfNeeded: value >> 32), at: offset + 4)
}

extension Timestamp {
    /// UDF's 12-byte timestamp: type 1 (local time) with a zero offset, which is UTC.
    var udfForm: [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 12)
        put16(&bytes, 0x1000, at: 0)
        put16(&bytes, UInt16(clamping: components.year ?? 1970), at: 2)
        bytes[4] = UInt8(clamping: components.month ?? 1)
        bytes[5] = UInt8(clamping: components.day ?? 1)
        bytes[6] = UInt8(clamping: components.hour ?? 0)
        bytes[7] = UInt8(clamping: components.minute ?? 0)
        bytes[8] = UInt8(clamping: components.second ?? 0)
        let nanoseconds = max(0, components.nanosecond ?? 0)
        bytes[9] = UInt8(clamping: nanoseconds / 10_000_000)
        bytes[10] = UInt8(clamping: nanoseconds / 100_000 % 100)
        bytes[11] = UInt8(clamping: nanoseconds / 1_000 % 100)
        return bytes
    }
}

// MARK: - Descriptors

extension Layout {
    /// The Volume Descriptor Sequence: six descriptors from `start`, padded to 16 sectors.
    func udfVolumeSequence(start: UInt32, volumeName: String, stamp: Timestamp) -> [UInt8] {
        var sectors: [[UInt8]] = []

        // Primary Volume Descriptor (ECMA-167 3/10.1).
        var primary = [UInt8](repeating: 0, count: 512)
        put32(&primary, 1, at: 16) // sequence number
        primary.replaceSubrange(24..<56, with: UDF.dstring(volumeName, length: 32))
        put16(&primary, 1, at: 56) // volume sequence number
        put16(&primary, 1, at: 58) // of 1
        put16(&primary, 2, at: 60) // interchange level: a single volume
        put16(&primary, 2, at: 62)
        put32(&primary, 1, at: 64) // character set list: CS0
        put32(&primary, 1, at: 68)
        primary.replaceSubrange(72..<200, with: UDF.dstring(volumeSetIdentifier(volumeName, stamp: stamp), length: 128))
        primary.replaceSubrange(200..<264, with: UDF.charspec)
        primary.replaceSubrange(264..<328, with: UDF.charspec)
        primary.replaceSubrange(344..<376, with: UDF.implementation)
        primary.replaceSubrange(376..<388, with: stamp.udfForm)
        primary.replaceSubrange(388..<420, with: UDF.implementation)
        sectors.append(primary)

        // Implementation Use Volume Descriptor, with UDF's logical volume information (UDF 2.2.7).
        var implementationUse = [UInt8](repeating: 0, count: 512)
        put32(&implementationUse, 2, at: 16)
        implementationUse.replaceSubrange(20..<52, with: UDF.lvInfo)
        implementationUse.replaceSubrange(52..<116, with: UDF.charspec)
        implementationUse.replaceSubrange(116..<244, with: UDF.dstring(volumeName, length: 128))
        implementationUse.replaceSubrange(352..<384, with: UDF.implementation)
        sectors.append(implementationUse)

        // Partition Descriptor (ECMA-167 3/10.5): one read-only partition holding everything after the anchor.
        var partition = [UInt8](repeating: 0, count: 512)
        put32(&partition, 3, at: 16)
        put16(&partition, 1, at: 20) // allocated
        put16(&partition, 0, at: 22) // partition number
        partition.replaceSubrange(24..<56, with: UDF.regid("+NSR03"))
        put32(&partition, 1, at: 184) // access type: read only
        put32(&partition, UDF.partitionStart, at: 188)
        put32(&partition, udfPartitionLength, at: 192)
        partition.replaceSubrange(196..<228, with: UDF.implementation)
        sectors.append(partition)

        // Logical Volume Descriptor (ECMA-167 3/10.6) with one type 1 partition map.
        var logical = [UInt8](repeating: 0, count: 446)
        put32(&logical, 4, at: 16)
        logical.replaceSubrange(20..<84, with: UDF.charspec)
        logical.replaceSubrange(84..<212, with: UDF.dstring(volumeName, length: 128))
        put32(&logical, UInt32(sectorSize), at: 212)
        logical.replaceSubrange(216..<248, with: UDF.domain)
        logical.replaceSubrange(248..<264, with: UDF.longAD(length: UInt32(sectorSize), block: 0)) // the File Set Descriptor
        put32(&logical, 6, at: 264) // map table length
        put32(&logical, 1, at: 268) // one partition map
        logical.replaceSubrange(272..<304, with: UDF.implementation)
        logical.replaceSubrange(432..<440, with: UDF.extent(length: UInt32(2 * sectorSize), location: UDF.integritySequence))
        logical[440] = 1 // type 1 map
        logical[441] = 6
        put16(&logical, 1, at: 442) // volume sequence number
        put16(&logical, 0, at: 444) // partition number
        sectors.append(logical)

        // Unallocated Space Descriptor: none, the disc is full.
        var unallocated = [UInt8](repeating: 0, count: 24)
        put32(&unallocated, 5, at: 16)
        sectors.append(unallocated)

        sectors.append([UInt8](repeating: 0, count: 512)) // Terminating Descriptor

        let ids: [UDF.TagID] = [.primaryVolume, .implementationUse, .partition, .logicalVolume, .unallocatedSpace, .terminating]
        var bytes: [UInt8] = []
        for (index, sector) in sectors.enumerated() {
            var descriptor = sector
            UDF.finishTag(&descriptor, ids[index], location: start + UInt32(index))
            bytes += descriptor + [UInt8](repeating: 0, count: sectorSize - descriptor.count)
        }
        bytes += [UInt8](repeating: 0, count: Int(UDF.sequenceBlocks) * sectorSize - bytes.count)
        return bytes
    }

    /// UDF asks for 16 unique characters first: here the time in hex, then a hash of the name.
    private func volumeSetIdentifier(_ volumeName: String, stamp: Timestamp) -> String {
        let seconds = UInt32(truncatingIfNeeded: Int(stamp.date.timeIntervalSince1970))
        var hash: UInt32 = 2_166_136_261
        for byte in volumeName.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(format: "%08X%08X", seconds, hash) + " " + volumeName
    }

    /// The Logical Volume Integrity Descriptor, marked closed, and a Terminating Descriptor.
    func udfIntegritySequence(stamp: Timestamp) -> [UInt8] {
        var integrity = [UInt8](repeating: 0, count: 134)
        integrity.replaceSubrange(16..<28, with: stamp.udfForm)
        put32(&integrity, 1, at: 28) // close
        put64(&integrity, udfNextUniqueID, at: 40) // logical volume header: next unique ID
        put32(&integrity, 1, at: 72) // partitions
        put32(&integrity, 46, at: 76) // implementation use length
        put32(&integrity, 0, at: 80) // free space: none
        put32(&integrity, udfPartitionLength, at: 84) // size
        integrity.replaceSubrange(88..<120, with: UDF.implementation)
        put32(&integrity, UInt32(udfNodes.filter { !$0.isDirectory }.count), at: 120)
        put32(&integrity, UInt32(udfNodes.filter(\.isDirectory).count), at: 124)
        put16(&integrity, UDF.revision, at: 128) // minimum read revision
        put16(&integrity, UDF.revision, at: 130) // minimum write revision
        put16(&integrity, UDF.revision, at: 132) // maximum write revision
        UDF.finishTag(&integrity, .logicalVolumeIntegrity, location: UDF.integritySequence)

        var terminating = [UInt8](repeating: 0, count: 512)
        UDF.finishTag(&terminating, .terminating, location: UDF.integritySequence + 1)
        return integrity + [UInt8](repeating: 0, count: sectorSize - integrity.count)
            + terminating + [UInt8](repeating: 0, count: sectorSize - terminating.count)
    }

    /// The Anchor Volume Descriptor Pointer, found at sector 256 and at the last sector.
    func udfAnchor(location: UInt32) -> [UInt8] {
        var anchor = [UInt8](repeating: 0, count: 512)
        let length = UDF.sequenceBlocks * UInt32(sectorSize)
        anchor.replaceSubrange(16..<24, with: UDF.extent(length: length, location: UDF.mainSequence))
        anchor.replaceSubrange(24..<32, with: UDF.extent(length: length, location: UDF.reserveSequence))
        UDF.finishTag(&anchor, .anchor, location: location)
        return anchor + [UInt8](repeating: 0, count: sectorSize - anchor.count)
    }

    /// The File Set Descriptor at block 0 of the partition, then a Terminating Descriptor.
    func udfFileSet(volumeName: String, stamp: Timestamp) -> [UInt8] {
        var fileSet = [UInt8](repeating: 0, count: 512)
        fileSet.replaceSubrange(16..<28, with: stamp.udfForm)
        put16(&fileSet, 3, at: 28) // interchange level
        put16(&fileSet, 3, at: 30)
        put32(&fileSet, 1, at: 32) // character set list: CS0
        put32(&fileSet, 1, at: 36)
        fileSet.replaceSubrange(48..<112, with: UDF.charspec)
        fileSet.replaceSubrange(112..<240, with: UDF.dstring(volumeName, length: 128))
        fileSet.replaceSubrange(240..<304, with: UDF.charspec)
        fileSet.replaceSubrange(304..<336, with: UDF.dstring(volumeName, length: 32))
        fileSet.replaceSubrange(400..<416, with: UDF.longAD(length: UInt32(sectorSize), block: root.udfEntry))
        fileSet.replaceSubrange(416..<448, with: UDF.domain)
        UDF.finishTag(&fileSet, .fileSet, location: 0)

        var terminating = [UInt8](repeating: 0, count: 512)
        UDF.finishTag(&terminating, .terminating, location: 1)
        return fileSet + [UInt8](repeating: 0, count: sectorSize - fileSet.count)
            + terminating + [UInt8](repeating: 0, count: sectorSize - terminating.count)
    }

    /// A File Entry (ECMA-167 4/14.9) for a file or folder, padded to one block.
    func udfFileEntry(_ node: Node) -> [UInt8] {
        let size: UInt64
        let allocation: [UInt8]
        if node.isDirectory {
            size = UInt64(node.udfDirectorySize)
            allocation = UDF.shortADs(size: size, block: node.udfDirectoryBlock)
        } else {
            size = node.size
            allocation = UDF.shortADs(size: size, block: node.fileExtent - UDF.partitionStart)
        }
        precondition(allocation.count <= UDF.maxExtentsPerEntry * 8, "\(node.name) is too large for one File Entry")

        var entry = [UInt8](repeating: 0, count: 176 + allocation.count)
        // ICB tag: strategy 4, one entry, short allocation descriptors.
        put16(&entry, 4, at: 20)
        put16(&entry, 1, at: 24)
        entry[27] = node.isDirectory ? 4 : 5
        put32(&entry, 0xFFFF_FFFF, at: 36) // user: not specified
        put32(&entry, 0xFFFF_FFFF, at: 40) // group: not specified
        // Read for everyone, and search for folders. Nothing on a closed disc can be changed.
        put32(&entry, node.isDirectory ? 0x14A5 : 0x1084, at: 44)
        let links = node.isDirectory ? 1 + node.children.filter(\.isDirectory).count : 1
        put16(&entry, UInt16(clamping: links), at: 48)
        put64(&entry, size, at: 56)
        put64(&entry, UDF.blocks(size), at: 64)
        let stamp = Timestamp(node.date).udfForm
        entry.replaceSubrange(72..<84, with: stamp) // accessed
        entry.replaceSubrange(84..<96, with: stamp) // modified
        entry.replaceSubrange(96..<108, with: stamp) // attributes changed
        put32(&entry, 1, at: 108) // checkpoint
        entry.replaceSubrange(128..<160, with: UDF.implementation)
        put64(&entry, node.udfUniqueID, at: 160)
        put32(&entry, UInt32(allocation.count), at: 172)
        entry.replaceSubrange(176..<entry.count, with: allocation)
        UDF.finishTag(&entry, .fileEntry, location: node.udfEntry)
        return entry + [UInt8](repeating: 0, count: sectorSize - entry.count)
    }

    /// A folder's File Identifier Descriptors: its parent first, then each child. They may cross
    /// block boundaries, which UDF allows. Padded to whole blocks.
    func udfDirectoryContents(_ directory: Node) -> [UInt8] {
        var bytes: [UInt8] = []
        func add(_ target: Node, name: [UInt8], characteristics: UInt8) {
            var identifier = [UInt8](repeating: 0, count: UDF.identifierLength(nameBytes: name.count))
            put16(&identifier, 1, at: 16) // file version
            identifier[18] = characteristics
            identifier[19] = UInt8(name.count)
            identifier.replaceSubrange(20..<36, with: UDF.longAD(length: UInt32(sectorSize), block: target.udfEntry,
                                                                 uniqueID: UInt32(truncatingIfNeeded: target.udfUniqueID)))
            identifier.replaceSubrange(38..<(38 + name.count), with: name)
            let location = directory.udfDirectoryBlock + UInt32(bytes.count / sectorSize)
            UDF.finishTag(&identifier, .fileIdentifier, location: location)
            bytes += identifier
        }
        add(directory.parent ?? root, name: [], characteristics: 0x0A) // parent, a directory
        for child in udfSortedChildren(directory) {
            let characteristics: UInt8 = (child.isDirectory ? 0x02 : 0) | (child.isHidden ? 0x01 : 0)
            add(child, name: UDF.cs0(child.udfName), characteristics: characteristics)
        }
        precondition(bytes.count == directory.udfDirectorySize, "UDF directory \(directory.name) changed size")
        let padded = Int(UDF.blocks(UInt64(bytes.count))) * sectorSize
        return bytes + [UInt8](repeating: 0, count: padded - bytes.count)
    }
}

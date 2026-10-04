import Foundation

extension Layout {
    /// Sectors 16-18: the ISO 9660 primary descriptor, the Joliet descriptor and the terminator.
    func isoDescriptors(volumeName: String, stamp: Timestamp) -> [UInt8] {
        var terminator = [UInt8](repeating: 0, count: sectorSize)
        terminator[0] = 255
        terminator.replaceSubrange(1..<6, with: Array("CD001".utf8))
        terminator[6] = 1
        return volumeDescriptor(joliet: false, volumeName: volumeName, stamp: stamp)
            + volumeDescriptor(joliet: true, volumeName: volumeName, stamp: stamp) + terminator
    }

    // MARK: - Volume descriptors

    func volumeDescriptor(joliet: Bool, volumeName: String, stamp: Timestamp) -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: sectorSize)
        sector[0] = joliet ? 2 : 1
        sector.replaceSubrange(1..<6, with: Array("CD001".utf8))
        sector[6] = 1

        func text(_ value: String, at offset: Int, length: Int) {
            if joliet {
                var bytes = [UInt8]()
                for unit in value.utf16 { bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
                bytes = Array(bytes.prefix(length / 2 * 2))
                while bytes.count + 2 <= length { bytes += [0x00, 0x20] }
                sector.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            } else {
                var bytes = Array(value.utf8.prefix(length))
                bytes += [UInt8](repeating: 0x20, count: length - bytes.count)
                sector.replaceSubrange(offset..<(offset + length), with: bytes)
            }
        }

        text("", at: 8, length: 32) // system identifier
        let name = joliet ? Names.truncateUTF16(volumeName, to: 16) : Names.isoVolume(volumeName)
        text(name, at: 40, length: 32)
        bothEndian32(&sector, UInt32(totalBlocks), at: 80)
        if joliet {
            sector[88] = 0x25
            sector[89] = 0x2F
            sector[90] = 0x45 // UCS-2 level 3
        }
        bothEndian16(&sector, 1, at: 120) // volume set size
        bothEndian16(&sector, 1, at: 124) // volume sequence number
        bothEndian16(&sector, UInt16(sectorSize), at: 128)
        let pathTableSize = joliet ? jolietPathTableSize : isoPathTableSize
        bothEndian32(&sector, UInt32(pathTableSize), at: 132)
        littleEndian32(&sector, joliet ? jolietPathTableL : isoPathTableL, at: 140)
        bigEndian32(&sector, joliet ? jolietPathTableM : isoPathTableM, at: 148)

        let rootRecord = directoryRecord(extent: joliet ? root.jolietExtent : root.isoExtent,
                                         size: UInt32(joliet ? root.jolietSize : root.isoSize),
                                         isDirectory: true, identifier: [0x00], stamp: Timestamp(root.date))
        sector.replaceSubrange(156..<(156 + rootRecord.count), with: rootRecord)

        text("", at: 190, length: 128) // volume set
        text("", at: 318, length: 128) // publisher
        text("", at: 446, length: 128) // data preparer
        text("BURN", at: 574, length: 128) // application
        text("", at: 702, length: 37)
        text("", at: 739, length: 37)
        text("", at: 776, length: 37)
        sector.replaceSubrange(813..<830, with: stamp.longForm)
        sector.replaceSubrange(830..<847, with: stamp.longForm)
        sector.replaceSubrange(847..<864, with: Timestamp.unsetLongForm)
        sector.replaceSubrange(864..<881, with: stamp.longForm)
        sector[881] = 1 // file structure version
        return sector
    }

    // MARK: - Path tables

    func pathTable(joliet: Bool, bigEndian: Bool) -> [UInt8] {
        let directories = joliet ? jolietDirectories : isoDirectories
        var table: [UInt8] = []
        for directory in directories {
            let identifier: [UInt8]
            if directory === root {
                identifier = [0x00]
            } else if joliet {
                identifier = Names.jolietIdentifier(directory.jolietName, isDirectory: true)
            } else {
                identifier = Array(directory.isoName.utf8)
            }
            var record = [UInt8](repeating: 0, count: Self.pathRecordLength(identifierLength: identifier.count))
            record[0] = UInt8(identifier.count)
            let extent = joliet ? directory.jolietExtent : directory.isoExtent
            let parent = directory.parent ?? root
            let parentNumber = UInt16(joliet ? parent.jolietNumber : parent.isoNumber)
            if bigEndian {
                bigEndian32(&record, extent, at: 2)
                record[6] = UInt8(parentNumber >> 8)
                record[7] = UInt8(parentNumber & 0xFF)
            } else {
                littleEndian32(&record, extent, at: 2)
                record[6] = UInt8(parentNumber & 0xFF)
                record[7] = UInt8(parentNumber >> 8)
            }
            record.replaceSubrange(8..<(8 + identifier.count), with: identifier)
            table += record
        }
        return table
    }

    // MARK: - Directories

    func directoryContents(_ directory: Node, joliet: Bool) -> [UInt8] {
        let parent = directory.parent ?? root
        var records: [[UInt8]] = []
        records.append(directoryRecord(extent: joliet ? directory.jolietExtent : directory.isoExtent,
                                       size: UInt32(joliet ? directory.jolietSize : directory.isoSize),
                                       isDirectory: true, identifier: [0x00], stamp: Timestamp(directory.date)))
        records.append(directoryRecord(extent: joliet ? parent.jolietExtent : parent.isoExtent,
                                       size: UInt32(joliet ? parent.jolietSize : parent.isoSize),
                                       isDirectory: true, identifier: [0x01], stamp: Timestamp(parent.date)))
        for child in sortedChildren(directory, joliet: joliet) {
            let identifier = joliet ? Names.jolietIdentifier(child.jolietName, isDirectory: child.isDirectory)
                                    : Array(child.isoName.utf8)
            let extent: UInt32
            let size: UInt32
            if child.isDirectory {
                extent = joliet ? child.jolietExtent : child.isoExtent
                size = UInt32(joliet ? child.jolietSize : child.isoSize)
            } else {
                extent = child.fileExtent
                size = UInt32(child.size)
            }
            records.append(directoryRecord(extent: extent, size: size, isDirectory: child.isDirectory,
                                           identifier: identifier, stamp: Timestamp(child.date), hidden: child.isHidden))
        }

        var bytes: [UInt8] = []
        for record in records {
            let used = bytes.count % sectorSize
            if used + record.count > sectorSize {
                bytes += [UInt8](repeating: 0, count: sectorSize - used)
            }
            bytes += record
        }
        let size = joliet ? directory.jolietSize : directory.isoSize
        bytes += [UInt8](repeating: 0, count: size - bytes.count)
        return bytes
    }

    func directoryRecord(extent: UInt32, size: UInt32, isDirectory: Bool, identifier: [UInt8], stamp: Timestamp,
                                 hidden: Bool = false) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: Self.recordLength(identifierLength: identifier.count))
        record[0] = UInt8(record.count)
        bothEndian32(&record, extent, at: 2)
        bothEndian32(&record, size, at: 10)
        record.replaceSubrange(18..<25, with: stamp.shortForm)
        // Flag bit 0, "existence", hides the entry on systems that honour it, such as Windows.
        record[25] = (isDirectory ? 0x02 : 0x00) | (hidden ? 0x01 : 0x00)
        bothEndian16(&record, 1, at: 28)
        record[32] = UInt8(identifier.count)
        record.replaceSubrange(33..<(33 + identifier.count), with: identifier)
        return record
    }
}

// MARK: - Encoding helpers

func littleEndian32(_ bytes: inout [UInt8], _ value: UInt32, at offset: Int) {
    for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(index))) }
}

func bigEndian32(_ bytes: inout [UInt8], _ value: UInt32, at offset: Int) {
    for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(3 - index))) }
}

func bothEndian32(_ bytes: inout [UInt8], _ value: UInt32, at offset: Int) {
    littleEndian32(&bytes, value, at: offset)
    bigEndian32(&bytes, value, at: offset + 4)
}

func bothEndian16(_ bytes: inout [UInt8], _ value: UInt16, at offset: Int) {
    bytes[offset] = UInt8(value & 0xFF)
    bytes[offset + 1] = UInt8(value >> 8)
    bytes[offset + 2] = UInt8(value >> 8)
    bytes[offset + 3] = UInt8(value & 0xFF)
}

/// Disc dates, always in UTC.
struct Timestamp {
    let date: Date
    let components: DateComponents

    init(_ date: Date) {
        self.date = date
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    }

    /// The 7-byte form used in directory records.
    var shortForm: [UInt8] {
        [UInt8(clamping: (components.year ?? 1970) - 1900), UInt8(clamping: components.month ?? 1),
         UInt8(clamping: components.day ?? 1), UInt8(clamping: components.hour ?? 0),
         UInt8(clamping: components.minute ?? 0), UInt8(clamping: components.second ?? 0), 0]
    }

    /// The 17-byte form used in volume descriptors.
    var longForm: [UInt8] {
        let hundredths = (components.nanosecond ?? 0) / 10_000_000
        let text = String(format: "%04ld%02ld%02ld%02ld%02ld%02ld%02ld",
                          components.year ?? 1970, components.month ?? 1, components.day ?? 1,
                          components.hour ?? 0, components.minute ?? 0, components.second ?? 0, hundredths)
        return Array(text.utf8) + [0]
    }

    static let unsetLongForm: [UInt8] = Array("0000000000000000".utf8) + [0]
}

import Foundation

/// A minimal ISO 9660 reader, written separately from the builder, to check its output.
struct ISOReader {
    struct Record {
        var extent: UInt32
        var size: UInt32
        var isDirectory: Bool
        var identifier: [UInt8]
    }

    let bytes: [UInt8]

    init(url: URL) throws {
        bytes = [UInt8](try Data(contentsOf: url))
    }

    func le32(_ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    func be32(_ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    func record(at offset: Int) -> Record? {
        let length = Int(bytes[offset])
        guard length > 0 else { return nil }
        let nameLength = Int(bytes[offset + 32])
        return Record(extent: le32(offset + 2), size: le32(offset + 10), isDirectory: bytes[offset + 25] & 0x02 != 0,
                      identifier: Array(bytes[(offset + 33)..<(offset + 33 + nameLength)]))
    }

    func rootRecord(descriptorSector: Int) -> Record {
        record(at: descriptorSector * 2048 + 156)!
    }

    /// Every record in a directory except "." and "..", following the no-crossing rule.
    func children(of directory: Record) -> [Record] {
        var result: [Record] = []
        let start = Int(directory.extent) * 2048
        var offset = start
        let end = start + Int(directory.size)
        while offset < end {
            let length = Int(bytes[offset])
            if length == 0 {
                offset = (offset / 2048 + 1) * 2048
                continue
            }
            if let entry = record(at: offset), entry.identifier != [0], entry.identifier != [1] {
                result.append(entry)
            }
            offset += length
        }
        return result
    }

    static func jolietName(_ identifier: [UInt8]) -> String {
        var units: [UInt16] = []
        var index = 0
        while index + 1 < identifier.count {
            units.append(UInt16(identifier[index]) << 8 | UInt16(identifier[index + 1]))
            index += 2
        }
        var name = String(decoding: units, as: UTF16.self)
        if name.hasSuffix(";1") { name.removeLast(2) }
        return name
    }

    /// Relative path to file contents, read through the Joliet tree.
    func jolietFiles() -> [String: [UInt8]] {
        var result: [String: [UInt8]] = [:]
        func walk(_ directory: Record, prefix: String) {
            for child in children(of: directory) {
                let name = Self.jolietName(child.identifier)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if child.isDirectory {
                    walk(child, prefix: path)
                } else {
                    let start = Int(child.extent) * 2048
                    result[path] = Array(bytes[start..<(start + Int(child.size))])
                }
            }
        }
        walk(rootRecord(descriptorSector: 17), prefix: "")
        return result
    }

    /// Every ISO 9660 identifier, per directory, read through the primary tree.
    func isoNames() -> [[String]] {
        var result: [[String]] = []
        func walk(_ directory: Record) {
            let entries = children(of: directory)
            result.append(entries.map { String(decoding: $0.identifier, as: UTF8.self) })
            for entry in entries where entry.isDirectory { walk(entry) }
        }
        walk(rootRecord(descriptorSector: 16))
        return result
    }
}

import Foundation

/// Big-endian helpers for SCSI byte layouts.
public extension Array where Element == UInt8 {
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 1 < count else { return 0 }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 3 < count else { return 0 }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func byte(at offset: Int) -> UInt8 {
        offset < count ? self[offset] : 0
    }

    mutating func put(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    mutating func put(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    /// ASCII text with trailing spaces and NULs removed.
    func asciiString(at offset: Int, length: Int) -> String {
        guard offset < count else { return "" }
        let end = Swift.min(offset + length, count)
        let text = String(decoding: self[offset..<end], as: UTF8.self)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

extension BinaryInteger {
    /// The number with commas between thousands, such as "2,379,022,336", the same in every
    /// locale, for messages and the log.
    public var grouped: String {
        let digits = String(self)
        let negative = digits.hasPrefix("-")
        var body = Array(negative ? digits.dropFirst() : Substring(digits))
        var index = body.count - 3
        while index > 0 {
            body.insert(",", at: index)
            index -= 3
        }
        return (negative ? "-" : "") + String(body)
    }
}

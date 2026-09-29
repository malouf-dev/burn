import Foundation

/// Name rules for ISO 9660 level 1 and Joliet.
enum Names {
    static let dCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

    /// ISO 9660 level 1: 8.3 upper-case names. `index` makes names unique within a directory.
    static func iso(_ name: String, isDirectory: Bool, index: Int = 0) -> String {
        var base = name
        var ext = ""
        if !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = String(name[..<dot])
            ext = String(name[name.index(after: dot)...])
        }
        func clean(_ text: String, limit: Int) -> String {
            let mapped = text.uppercased().map { dCharacters.contains($0) ? $0 : "_" }
            return String(mapped.prefix(limit))
        }
        var cleanBase = clean(base, limit: 8)
        let cleanExt = clean(ext, limit: 3)
        if cleanBase.isEmpty { cleanBase = "_" }
        if index > 0 {
            let suffix = "_\(index)"
            cleanBase = String(cleanBase.prefix(max(1, 8 - suffix.count))) + suffix
        }
        if isDirectory { return cleanBase }
        return cleanExt.isEmpty ? "\(cleanBase).;1" : "\(cleanBase).\(cleanExt);1"
    }

    /// Longest Joliet name we write, in UTF-16 code units, before the ";1" version suffix.
    /// The Joliet standard says 64; most readers accept this longer limit, as mkisofs's -joliet-long does.
    static let jolietLimit = 103

    /// Joliet: the real name in UCS-2, with characters Joliet forbids replaced.
    static func joliet(_ name: String, isDirectory: Bool, index: Int = 0) -> String {
        let forbidden: Set<Character> = ["*", "/", ":", ";", "?", "\\"]
        // Composed (NFC) form, as Windows expects. macOS reads either.
        let composed = name.precomposedStringWithCanonicalMapping
        var cleaned = String(composed.map { character -> Character in
            if forbidden.contains(character) { return "_" }
            if let scalar = character.unicodeScalars.first, scalar.value < 0x20 { return "_" }
            return character
        })
        if index > 0 {
            let suffix = " (\(index + 1))"
            var base = cleaned
            var ext = ""
            if !isDirectory, let dot = cleaned.lastIndex(of: "."), dot != cleaned.startIndex {
                base = String(cleaned[..<dot])
                ext = String(cleaned[dot...])
            }
            cleaned = base + suffix + ext
        }
        cleaned = truncateUTF16(cleaned, to: jolietLimit)
        return cleaned
    }

    static func truncateUTF16(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        var count = 0
        for character in text {
            let size = String(character).utf16.count
            if count + size > limit { break }
            result.append(character)
            count += size
        }
        return result
    }

    /// Joliet identifier bytes, big-endian UCS-2, with ";1" on files.
    static func jolietIdentifier(_ name: String, isDirectory: Bool) -> [UInt8] {
        let full = isDirectory ? name : name + ";1"
        var bytes: [UInt8] = []
        for unit in full.utf16 {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        return bytes
    }

    /// Volume name for the primary descriptor: d-characters, up to 32.
    static func isoVolume(_ name: String) -> String {
        let mapped = name.uppercased().map { dCharacters.contains($0) ? $0 : "_" }
        let result = String(mapped.prefix(32))
        return result.isEmpty ? "CDROM" : result
    }
}

import CryptoKit
import Foundation

/// The hidden `.burn` folder at the root of a data disc (decision D12). It holds a SHA-256
/// checksum for every file, so the disc can be checked years later.
///
/// `SHA256SUMS` is in the form `shasum -a 256 -c` reads, so checking a disc needs nothing but
/// the tools every Mac and Linux system has: `cd /Volumes/Disc && shasum -a 256 -c .burn/SHA256SUMS`.
/// `info.json` adds the disc name, date, app and totals for Burn to show.
public enum DiscChecksums {
    public static let folderName = ".burn"
    public static let sumsName = "SHA256SUMS"
    public static let infoName = "info.json"

    /// One line: 64 lower-case hex digits, two spaces, the path from the disc's root, a newline.
    static func line(digest: String, path: String) -> String {
        "\(digest)  \(path)\n"
    }

    static func lineLength(path: String) -> Int {
        64 + 2 + path.utf8.count + 1
    }

    /// The whole list, sorted by path so the file reads well and is the same every time.
    public static func render(_ digests: [String: String]) -> String {
        digests.sorted { $0.key < $1.key }.map { line(digest: $0.value, path: $0.key) }.joined()
    }

    /// Reads a list written by `render`, or by `shasum -a 256` itself.
    public static func parse(_ text: String) throws -> [(path: String, digest: String)] {
        var entries: [(path: String, digest: String)] = []
        // Swift reads "\r\n" as one character, and isNewline covers it and "\n" alike.
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let hexDigits = Set("0123456789abcdefABCDEF")
            guard line.count > 66, line.prefix(64).allSatisfy({ hexDigits.contains($0) }) else {
                throw DiscChecksumsError.badLine(index + 1)
            }
            let separator = line[line.index(line.startIndex, offsetBy: 64)...].prefix(2)
            guard separator == "  " || separator == " *" else { throw DiscChecksumsError.badLine(index + 1) }
            let path = String(line.dropFirst(66))
            entries.append((path: path, digest: line.prefix(64).lowercased()))
        }
        return entries
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DiscChecksumsError: Error, Sendable, Equatable, CustomStringConvertible {
    case noChecksums
    case unreadable(String)
    case badLine(Int)

    public var description: String {
        switch self {
        case .noChecksums: return "This disc has no \(DiscChecksums.folderName) folder with checksums."
        case .unreadable(let name): return "Couldn't read \(name)."
        case .badLine(let line): return "Line \(line) of \(DiscChecksums.sumsName) isn't a checksum line."
        }
    }
}

/// `.burn/info.json`: details for Burn to show when checking a disc.
public struct DiscInfo: Codable, Sendable, Hashable {
    public var format = "burn-checksums"
    public var formatVersion = 1
    public var discName: String
    /// When the image was made, in ISO 8601 UTC to the second.
    public var created: String
    public var application: String
    public var algorithm = "SHA-256"
    public var fileCount: Int
    public var totalBytes: UInt64
    /// How the disc's PAR2 recovery data was made, such as "PAR2, 10%", when it has some.
    public var recovery: String?

    public init(discName: String, created: Date, application: String, fileCount: Int, totalBytes: UInt64) {
        self.discName = discName
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        self.created = formatter.string(from: created)
        self.application = application
        self.fileCount = fileCount
        self.totalBytes = totalBytes
    }

    /// Sorted keys and fixed-width fields, so the size is known before the image is written.
    func encoded() -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return [UInt8](data) + [0x0A]
    }
}

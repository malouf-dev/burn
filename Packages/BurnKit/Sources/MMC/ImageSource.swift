import Foundation

/// Where the blocks to write come from.
public protocol ImageSource: Sendable {
    /// Size of the image in 2,048-byte blocks.
    var blockCount: Int { get }
    /// Reads `count` blocks starting at `block`. Must return exactly `count * 2048` bytes.
    func read(block: Int, count: Int) throws -> [UInt8]
    /// What a block holds, such as which file and where in it, for the log. Nil if not known.
    func describe(block: Int) -> String?
}

extension ImageSource {
    public func describe(block: Int) -> String? { nil }
}

public enum ImageSourceError: Error, Sendable, CustomStringConvertible {
    case notBlockAligned(bytes: Int64)
    case shortRead(block: Int)

    public var description: String {
        switch self {
        case .notBlockAligned(let bytes):
            return "The image is \(bytes) bytes, which isn't a whole number of 2,048-byte blocks."
        case .shortRead(let block):
            return "The image ended early at block \(block)."
        }
    }
}

/// An image held in memory, for tests.
public struct MemoryImageSource: ImageSource {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count % MMC.blockSize == 0, "Image must be whole blocks")
        self.bytes = bytes
    }

    public var blockCount: Int { bytes.count / MMC.blockSize }

    public func read(block: Int, count: Int) throws -> [UInt8] {
        let start = block * MMC.blockSize
        let end = start + count * MMC.blockSize
        guard end <= bytes.count else { throw ImageSourceError.shortRead(block: block) }
        return Array(bytes[start..<end])
    }
}

/// An image file on disk, such as an ISO.
public final class FileImageSource: ImageSource, @unchecked Sendable {
    public let url: URL
    public let blockCount: Int
    private var handle: FileHandle
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        guard size % Int64(MMC.blockSize) == 0 else { throw ImageSourceError.notBlockAligned(bytes: size) }
        blockCount = Int(size / Int64(MMC.blockSize))
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    public func read(block: Int, count: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.seek(toOffset: UInt64(block) * UInt64(MMC.blockSize))
            let data = try handle.readBytes(count * MMC.blockSize)
            guard data.count == count * MMC.blockSize else { throw ImageSourceError.shortRead(block: block) }
            return data
        } catch {
            // The next try opens the file again, in case its drive dropped out and came back.
            if let reopened = try? FileHandle(forReadingFrom: url) {
                try? handle.close()
                handle = reopened
            }
            throw error
        }
    }

    public func describe(block: Int) -> String? {
        "\(url.lastPathComponent) from byte \((UInt64(block) * UInt64(MMC.blockSize)).grouped)"
    }
}

/// A disc image file the user added, and whether it can be burned block for block.
///
/// An ISO or a raw Apple image (`.cdr`, made by `hdiutil convert -format UDTO`) is the disc's
/// blocks, so writing it as it is gives an exact copy, boot code and Mac partitions included.
/// An Apple disc image in UDIF form (most `.dmg` files) is compressed or wrapped, and ends in a
/// 512-byte trailer that starts "koly"; it has to be converted first.
public enum DiscImageFile {
    /// Names that may hold a disc image.
    public static let extensions: Set<String> = ["iso", "cdr", "img", "dmg"]

    public enum Kind: Sendable, Hashable {
        /// The disc's blocks, ready to burn.
        case raw(blocks: Int)
        /// A UDIF image, to convert with `hdiutil convert -format UDTO` before burning.
        case appleDiskImage
        /// Not a whole number of 2,048-byte blocks, so not a data disc's image.
        case notBlockAligned(bytes: Int64)
    }

    public static func hasImageExtension(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Reads the file's size and its last 512 bytes.
    public static func inspect(_ url: URL) throws -> Kind {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size >= 512 {
            try handle.seek(toOffset: size - 512)
            if try handle.readBytes(4) == Array("koly".utf8) { return .appleDiskImage }
        }
        guard size > 0, size % UInt64(MMC.blockSize) == 0 else { return .notBlockAligned(bytes: Int64(size)) }
        return .raw(blocks: Int(size / UInt64(MMC.blockSize)))
    }
}

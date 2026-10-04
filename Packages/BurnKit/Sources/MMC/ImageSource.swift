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
    private let handle: FileHandle
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
        try handle.seek(toOffset: UInt64(block) * UInt64(MMC.blockSize))
        let data = try handle.read(upToCount: count * MMC.blockSize) ?? Data()
        guard data.count == count * MMC.blockSize else { throw ImageSourceError.shortRead(block: block) }
        return [UInt8](data)
    }
}

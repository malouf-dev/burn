import Foundation
import MMC

/// How Restore and Repair read a disc's files, with retries (decision D16).
///
/// A drive can return wrong data with no error (hardware runs 18 and 20), or fail a read where
/// the disc is scratched. A piece that fails, or fails its checksum, is read again, up to
/// `attempts` times, past macOS's file cache where the system allows. What still can't be read
/// is salvaged a sector at a time, so as little as possible is lost. Tests stand in their own
/// reader to make reads fail.
struct DiscReader: Sendable {
    /// Reads up to `count` bytes at `offset`. `attempt` counts from 1. Throws on a read error.
    var read: @Sendable (_ url: URL, _ offset: UInt64, _ count: Int, _ attempt: Int) throws -> [UInt8]

    static let attempts = 3
    /// Unreadable areas are retried in pieces this size, then a sector at a time.
    static let salvagePiece = 64 * 1024
    static let sector = 2048

    /// Reads the mounted disc. Retries open the file afresh with caching off, so a wrong copy
    /// already in memory isn't simply handed back again.
    static let disc = DiscReader { url, offset, count, attempt in
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if canImport(Darwin)
        if attempt > 1 { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }
        #endif
        try handle.seek(toOffset: offset)
        return try handle.readBytes(count)
    }

    /// Reads `count` bytes, trying again while the read fails, comes back short, or `good`
    /// rejects it. Returns nil if no attempt passed, and how many attempts it took. A caller
    /// trying again itself starts at a later `firstAttempt`, so the read skips the cache.
    func reliably(_ url: URL, offset: UInt64, count: Int, firstAttempt: Int = 1,
                  good: ([UInt8]) -> Bool = { _ in true }) -> (bytes: [UInt8]?, attempts: Int) {
        for attempt in firstAttempt...max(firstAttempt, Self.attempts) {
            if let bytes = try? read(url, offset, count, attempt), bytes.count == count, good(bytes) {
                return (bytes, attempt)
            }
        }
        return (nil, Self.attempts)
    }

    /// Reads what can be read of `count` bytes, filling what can't with zeros. Returns the bytes
    /// and how many couldn't be read.
    func salvage(_ url: URL, offset: UInt64, count: Int) -> (bytes: [UInt8], lost: Int) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        var lost = 0
        var done = 0
        while done < count {
            let piece = min(Self.salvagePiece, count - done)
            if let read = reliably(url, offset: offset + UInt64(done), count: piece).bytes {
                bytes += read
            } else {
                // A sector at a time, so one bad sector costs 2 KB, not 64.
                var inPiece = 0
                while inPiece < piece {
                    let size = min(Self.sector, piece - inPiece)
                    let at = offset + UInt64(done + inPiece)
                    if let read = reliably(url, offset: at, count: size).bytes {
                        bytes += read
                    } else {
                        bytes += [UInt8](repeating: 0, count: size)
                        lost += size
                    }
                    inPiece += size
                }
            }
            done += piece
        }
        return (bytes, lost)
    }

    /// Copies a whole file, salvaging what won't read. Returns how many bytes were lost.
    func copy(_ source: URL, size: UInt64, to target: URL, firstAttempt: Int = 1) throws -> Int {
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw ISOBuilderError.unreadable(target.path)
        }
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        var offset: UInt64 = 0
        var lost = 0
        while offset < size {
            try Task.checkCancellation()
            let count = Int(min(UInt64(1 << 20), size - offset))
            var chunk = reliably(source, offset: offset, count: count, firstAttempt: firstAttempt).bytes
            if chunk == nil {
                let salvaged = salvage(source, offset: offset, count: count)
                chunk = salvaged.bytes
                lost += salvaged.lost
            }
            try writer.writeBytes(chunk ?? [])
            offset += UInt64(count)
        }
        return lost
    }
}

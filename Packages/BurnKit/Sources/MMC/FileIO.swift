import Foundation

/// File reads and writes straight between Swift arrays and the file, with read(2) and write(2).
///
/// FileHandle's own methods hand back autoreleased objects on macOS, freed only when an
/// autorelease pool drains. A long loop on a background thread drains none, so everything it reads
/// stays in memory until the loop ends. Making recovery data for a 36 GB disc filled the Mac's
/// memory that way, and macOS killed the app (hardware run 20).
extension FileHandle {
    /// Reads `count` bytes from the current position, fewer only at the end of the file. One read
    /// can return less than asked before the end, so this reads until it has them all.
    public func readBytes(_ count: Int) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: count)
        var filled = 0
        let descriptor = fileDescriptor
        try result.withUnsafeMutableBytes { buffer in
            while filled < count {
                let got = systemRead(descriptor, buffer.baseAddress! + filled, count - filled)
                if got < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                if got == 0 { break }
                filled += got
            }
        }
        result.removeLast(count - filled)
        return result
    }

    /// Writes all of `bytes` at the current position.
    public func writeBytes(_ bytes: [UInt8]) throws {
        var written = 0
        let descriptor = fileDescriptor
        try bytes.withUnsafeBytes { buffer in
            while written < bytes.count {
                let put = systemWrite(descriptor, buffer.baseAddress! + written, bytes.count - written)
                if put < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                written += put
            }
        }
    }
}

// Outside the extension, where FileHandle's own read and write methods don't hide these.
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(descriptor, buffer, count)
}

private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    write(descriptor, buffer, count)
}

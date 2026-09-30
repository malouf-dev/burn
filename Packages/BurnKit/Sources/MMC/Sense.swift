import Foundation

/// Fixed-format SCSI sense data: why a command failed.
public struct SenseData: Sendable, Equatable, CustomStringConvertible {
    public var key: UInt8
    public var asc: UInt8
    public var ascq: UInt8
    /// Progress for long operations such as blanking, as a fraction, when the drive reports it.
    public var progress: Double?

    public init(key: UInt8, asc: UInt8, ascq: UInt8, progress: Double? = nil) {
        self.key = key
        self.asc = asc
        self.ascq = ascq
        self.progress = progress
    }

    /// Parses fixed (70h, 71h) or descriptor (72h, 73h) format sense data.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 3 else { return nil }
        let responseCode = bytes[0] & 0x7F
        switch responseCode {
        case 0x70, 0x71:
            key = bytes[2] & 0x0F
            asc = bytes.byte(at: 12)
            ascq = bytes.byte(at: 13)
            let sksv = bytes.byte(at: 15)
            if sksv & 0x80 != 0, key == 0x02 {
                progress = Double(bytes.uint16(at: 16)) / 65536.0
            } else {
                progress = nil
            }
        case 0x72, 0x73:
            key = bytes[1] & 0x0F
            asc = bytes[2]
            ascq = bytes.byte(at: 3)
            progress = nil
        default:
            return nil
        }
    }

    /// Fixed-format bytes, for the simulated drive.
    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0, count: 18)
        result[0] = 0x70
        result[2] = key
        result[7] = 10
        result[12] = asc
        result[13] = ascq
        if let progress {
            result[15] = 0x80
            result.put(UInt16(clamping: Int(progress * 65536.0)), at: 16)
        }
        return result
    }

    // Common conditions.
    public static let mediumNotPresent = SenseData(key: 0x02, asc: 0x3A, ascq: 0x00)
    public static let becomingReady = SenseData(key: 0x02, asc: 0x04, ascq: 0x01)
    public static let operationInProgress = SenseData(key: 0x02, asc: 0x04, ascq: 0x07)
    public static let longWriteInProgress = SenseData(key: 0x02, asc: 0x04, ascq: 0x08)
    public static let mediumChanged = SenseData(key: 0x06, asc: 0x28, ascq: 0x00)
    public static let invalidCommand = SenseData(key: 0x05, asc: 0x20, ascq: 0x00)
    public static let invalidFieldInCDB = SenseData(key: 0x05, asc: 0x24, ascq: 0x00)
    public static let invalidAddressForWrite = SenseData(key: 0x05, asc: 0x21, ascq: 0x02)
    public static let lbaOutOfRange = SenseData(key: 0x05, asc: 0x21, ascq: 0x00)
    public static let illegalModeForTrack = SenseData(key: 0x05, asc: 0x64, ascq: 0x00)
    public static let incompatibleMedium = SenseData(key: 0x05, asc: 0x30, ascq: 0x00)
    public static let unrecoveredReadError = SenseData(key: 0x03, asc: 0x11, ascq: 0x00)
    public static let writeError = SenseData(key: 0x03, asc: 0x0C, ascq: 0x00)
    public static let eraseFailure = SenseData(key: 0x03, asc: 0x51, ascq: 0x00)

    /// True when the drive is busy and the command should be retried shortly.
    public var isTransientNotReady: Bool {
        key == 0x02 && asc == 0x04 && [0x00, 0x01, 0x04, 0x07, 0x08].contains(ascq)
    }

    public var isNoMedium: Bool { key == 0x02 && asc == 0x3A }

    public var isUnitAttention: Bool { key == 0x06 }

    /// The drive couldn't erase the disc.
    public var isEraseFailure: Bool { key == 0x03 && asc == 0x51 }

    public var keyName: String {
        switch key {
        case 0x0: return "NO SENSE"
        case 0x1: return "RECOVERED ERROR"
        case 0x2: return "NOT READY"
        case 0x3: return "MEDIUM ERROR"
        case 0x4: return "HARDWARE ERROR"
        case 0x5: return "ILLEGAL REQUEST"
        case 0x6: return "UNIT ATTENTION"
        case 0x7: return "DATA PROTECT"
        case 0x8: return "BLANK CHECK"
        case 0xB: return "ABORTED COMMAND"
        default: return "KEY \(hex(key))"
        }
    }

    /// A plain explanation for the common additional sense codes.
    public var explanation: String {
        // Reading an unwritten part of the disc, which is normal on a blank one.
        if key == 0x8 { return "That part of the disc hasn't been written." }
        switch (asc, ascq) {
        case (0x04, 0x01): return "The drive is getting ready."
        case (0x04, 0x04), (0x04, 0x07): return "The drive is busy with an operation."
        case (0x04, 0x08): return "The drive is busy writing."
        case (0x04, _): return "The drive is not ready."
        case (0x0C, _): return "The drive couldn't write to the disc."
        case (0x11, _): return "The drive couldn't read part of the disc."
        case (0x20, 0x00): return "The drive doesn't support this command."
        case (0x21, 0x00): return "The address is past the end of the disc."
        case (0x21, 0x02): return "The drive refused to write at this address."
        case (0x24, 0x00): return "The drive rejected a field in the command."
        case (0x26, _): return "The drive rejected the command's parameters."
        case (0x28, 0x00): return "The disc was changed."
        case (0x29, _): return "The drive was reset."
        case (0x2C, _): return "The drive received commands in an unexpected order."
        case (0x30, _): return "The disc isn't compatible with this operation."
        case (0x31, _): return "The drive couldn't format the disc."
        case (0x3A, _): return "There's no disc in the drive."
        case (0x44, _): return "The drive reported an internal failure."
        case (0x51, 0x01): return "An earlier erase of this disc didn't finish."
        case (0x53, 0x02): return "The disc is locked in the drive."
        case (0x51, _): return "The drive couldn't erase the disc."
        case (0x63, _): return "The end of the disc's writable area was reached."
        case (0x64, _): return "The drive rejected the write mode for this disc."
        case (0x72, _): return "The drive couldn't close the session."
        case (0x73, _): return "The drive couldn't calibrate its laser for this disc."
        default: return "Drive error."
        }
    }

    public var description: String {
        "\(keyName) (\(hex(key))) ASC \(hex(asc)) ASCQ \(hex(ascq)): \(explanation)"
    }
}

func hex(_ value: UInt8) -> String {
    String(format: "%02Xh", value)
}

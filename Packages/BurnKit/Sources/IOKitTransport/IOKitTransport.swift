import Foundation
import MMC
import CIOKitMMC

/// A CD, DVD or Blu-ray burner found in the IORegistry.
public struct DriveReference: Sendable, Hashable, Identifiable {
    /// The IORegistry entry ID. Stable while the drive stays connected.
    public let id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
}

public enum IOKitDrives {
    /// Every connected burner that macOS offers for authoring.
    public static func list() -> [DriveReference] {
        let count = Int(BKMMCCopyDeviceIDs(nil, 0))
        guard count > 0 else { return [] }
        var ids = [UInt64](repeating: 0, count: count)
        let found = Int(BKMMCCopyDeviceIDs(&ids, Int32(count)))
        return ids.prefix(min(found, count)).map(DriveReference.init(id:))
    }
}

/// Sends MMC commands to a real drive through IOKit.
///
/// Without exclusive access only read-only status commands work. `beginExclusiveAccess`
/// makes this app the drive's driver until `endExclusiveAccess`, which writing needs.
public final class IOKitTransport: SCSITransport, @unchecked Sendable {
    public let reference: DriveReference
    private let device: OpaquePointer
    private let lock = NSLock()

    public init(_ reference: DriveReference) throws {
        var error: Int32 = 0
        guard let device = BKMMCDeviceOpen(reference.id, &error) else {
            throw TransportError.cannotOpen(reason: Self.openFailureReason(error))
        }
        self.reference = reference
        self.device = device
    }

    deinit {
        BKMMCDeviceClose(device)
    }

    static func openFailureReason(_ code: Int32) -> String {
        let hexCode = String(format: "0x%08X", UInt32(bitPattern: code))
        switch code {
        case BKMMC_ERROR_NO_PLUGIN:
            return "macOS returned no drive interface (\(hexCode))."
        case BKMMC_ERROR_QUERY_FAILED:
            return "the drive's IOKit plug-in refused the MMC and SCSI task interfaces (\(hexCode))."
        case BKMMC_ERROR_UNSUPPORTED:
            return "IOKit isn't available on this platform."
        default:
            return "IOKit error \(hexCode)."
        }
    }

    /// A report of each step of opening the drive, for diagnosing problems.
    public static func diagnose(_ reference: DriveReference) -> String {
        let size = 16_384
        var buffer = [CChar](repeating: 0, count: size)
        BKMMCDescribeDevice(reference.id, &buffer, size)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func beginExclusiveAccess() throws {
        lock.lock()
        defer { lock.unlock() }
        let result = BKMMCDeviceObtainExclusiveAccess(device)
        if result == BKMMC_ERROR_TASK_UNAVAILABLE {
            throw TransportError.cannotOpen(reason: "the SCSI task interface, which writing needs, isn't available.")
        }
        guard result == 0 else { throw TransportError.exclusiveAccessDenied(code: result) }
    }

    public func endExclusiveAccess() {
        lock.lock()
        defer { lock.unlock() }
        BKMMCDeviceReleaseExclusiveAccess(device)
    }

    public var hasExclusiveAccess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return BKMMCDeviceHasExclusiveAccess(device)
    }

    public func execute(_ command: SCSICommand) throws -> SCSIResponse {
        lock.lock()
        defer { lock.unlock() }

        var cdb = command.cdb
        var status: UInt8 = 0xFF
        var sense = [UInt8](repeating: 0, count: Int(BKMMC_SENSE_LENGTH))
        var transferred: UInt64 = 0
        let timeoutMS = UInt32(clamping: Int(command.timeout * 1000))

        var buffer: [UInt8]
        let direction: UInt8
        switch command.direction {
        case .none:
            buffer = []
            direction = UInt8(BKMMC_DIRECTION_NONE)
        case .fromDevice(let length):
            buffer = [UInt8](repeating: 0, count: length)
            direction = UInt8(BKMMC_DIRECTION_FROM_DEVICE)
        case .toDevice(let bytes):
            buffer = bytes
            direction = UInt8(BKMMC_DIRECTION_TO_DEVICE)
        }

        let result: Int32 = cdb.withUnsafeMutableBufferPointer { cdbPointer in
            buffer.withUnsafeMutableBytes { bufferPointer in
                BKMMCDeviceExecute(device, cdbPointer.baseAddress, UInt8(cdbPointer.count),
                                   bufferPointer.baseAddress, UInt64(bufferPointer.count), direction, timeoutMS,
                                   &status, &sense, &transferred)
            }
        }

        if result == BKMMC_ERROR_NEEDS_EXCLUSIVE_ACCESS {
            throw TransportError.needsExclusiveAccess
        }
        if result == BKMMC_ERROR_SERVICE_FAILURE {
            throw TransportError.notDelivered(reason: Self.serviceFailureReason(status))
        }
        guard result == 0 else {
            throw TransportError.ioError(code: result)
        }

        var data: [UInt8] = []
        if case .fromDevice = command.direction {
            data = Array(buffer.prefix(Int(min(transferred, UInt64(buffer.count)))))
        }
        let senseData = status == SCSIStatus.checkCondition.rawValue ? SenseData(bytes: sense) : nil
        return SCSIResponse(status: status, sense: senseData, data: data)
    }

    /// IOKit's task status codes for a command that didn't complete.
    static func serviceFailureReason(_ status: UInt8) -> String {
        switch status {
        case 0x01: "the command timed out"
        case 0x02: "the connection to the drive timed out"
        case 0x03: "the drive stopped responding"
        case 0x04: "the drive is no longer connected"
        case 0x05: "the command could not be delivered"
        default: String(format: "the command failed in transport (status %02Xh)", status)
        }
    }
}

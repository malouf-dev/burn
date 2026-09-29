import Foundation

/// Which way data moves for a command.
public enum DataDirection: Sendable, Equatable {
    case none
    /// Read this many bytes from the drive.
    case fromDevice(length: Int)
    /// Send these bytes to the drive.
    case toDevice([UInt8])
}

/// One SCSI command: the command descriptor block plus its data phase.
public struct SCSICommand: Sendable, Equatable {
    public var cdb: [UInt8]
    public var direction: DataDirection
    /// Seconds before the transport gives up.
    public var timeout: TimeInterval

    public init(cdb: [UInt8], direction: DataDirection = .none, timeout: TimeInterval = 30) {
        self.cdb = cdb
        self.direction = direction
        self.timeout = timeout
    }

    public var operationCode: UInt8 { cdb.first ?? 0 }
}

/// SCSI status byte values the engine cares about.
public enum SCSIStatus: UInt8, Sendable {
    case good = 0x00
    case checkCondition = 0x02
    case busy = 0x08
}

/// What came back from one command.
public struct SCSIResponse: Sendable, Equatable {
    public var status: UInt8
    public var sense: SenseData?
    public var data: [UInt8]

    public init(status: UInt8, sense: SenseData? = nil, data: [UInt8] = []) {
        self.status = status
        self.sense = sense
        self.data = data
    }

    public static func good(_ data: [UInt8] = []) -> SCSIResponse {
        SCSIResponse(status: SCSIStatus.good.rawValue, data: data)
    }

    public static func check(_ sense: SenseData) -> SCSIResponse {
        SCSIResponse(status: SCSIStatus.checkCondition.rawValue, sense: sense)
    }

    public var isGood: Bool { status == SCSIStatus.good.rawValue }
}

/// Failures below the SCSI level: the command never reached the drive or no answer came back.
public enum TransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The drive can't take this command until the app has exclusive access.
    case needsExclusiveAccess
    /// Exclusive access was refused, usually because a disc in the drive is mounted or another app is using it.
    case exclusiveAccessDenied(code: Int32)
    /// macOS wouldn't unmount the disc, so exclusive access couldn't be taken.
    case cannotUnmount(reason: String)
    /// The drive disappeared.
    case deviceGone
    /// The drive couldn't be opened. The reason names the step that failed.
    case cannotOpen(reason: String)
    /// The command never completed: the connection timed out or the drive stopped responding.
    case notDelivered(reason: String)
    /// Any other IOKit error.
    case ioError(code: Int32)

    public var description: String {
        switch self {
        case .needsExclusiveAccess:
            return "The drive needs exclusive access for this command."
        case .exclusiveAccessDenied(let code):
            return "Couldn't take control of the drive (error \(String(format: "0x%08X", UInt32(bitPattern: code)))). A mounted disc or another app may be using it."
        case .cannotUnmount(let reason):
            return "Couldn't unmount the disc (\(reason)). Close any files open on it and try again."
        case .deviceGone:
            return "The drive is no longer connected."
        case .notDelivered(let reason):
            return "The command didn't complete: \(reason)."
        case .cannotOpen(let reason):
            return "Couldn't open the drive: \(reason) Run `burnctl diagnose` for details."
        case .ioError(let code):
            return "The drive didn't respond (error \(String(format: "0x%08X", UInt32(bitPattern: code))))."
        }
    }
}

/// Something that can send SCSI commands to one drive.
///
/// Implementations: the IOKit transport for real drives and the simulated drive for tests.
/// Calls may block, so the engine runs them off the cooperative thread pool.
public protocol SCSITransport: AnyObject, Sendable {
    /// Sends one command and waits for it to finish.
    /// A CHECK CONDITION is a normal response. Only transport failures throw.
    func execute(_ command: SCSICommand) throws -> SCSIResponse

    /// Takes exclusive control of the drive, which writing needs. Unmounts the disc first if
    /// macOS has mounted it.
    func beginExclusiveAccess() throws

    /// Gives control back to macOS.
    func endExclusiveAccess()
}

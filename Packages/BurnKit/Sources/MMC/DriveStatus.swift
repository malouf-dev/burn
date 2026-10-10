import Foundation

/// What's in the drive, as the app shows it.
public enum DriveState: Sendable, Equatable {
    case noDisc
    /// The drive is still reading a newly inserted disc.
    case becomingReady
    case disc(DiscState)
}

/// A disc in the drive.
public struct DiscState: Sendable, Equatable {
    public var profile: MediaProfile
    public var status: DiscInformation.Status
    public var lastSessionState: DiscInformation.SessionState
    public var isErasable: Bool
    /// Blocks still writable, in 2,048-byte blocks.
    public var freeBlocks: UInt32
    /// Blocks already recorded.
    public var usedBlocks: UInt32
    public var writability: Writability

    public init(profile: MediaProfile, status: DiscInformation.Status, lastSessionState: DiscInformation.SessionState? = nil,
                isErasable: Bool, freeBlocks: UInt32, usedBlocks: UInt32 = 0, writability: Writability) {
        self.profile = profile
        self.status = status
        self.lastSessionState = lastSessionState ?? (status == .blank ? .empty : .complete)
        self.isErasable = isErasable
        self.freeBlocks = freeBlocks
        self.usedBlocks = usedBlocks
        self.writability = writability
    }

    public var freeBytes: Int64 { Int64(freeBlocks) * Int64(MMC.blockSize) }
    public var usedBytes: Int64 { Int64(usedBlocks) * Int64(MMC.blockSize) }

    /// A rewritable disc with data that a burn can erase first (`WriteOptions.eraseFirst`).
    public var canOverwrite: Bool { writability == .needsErase && profile.supportsBlank }

    /// True when a burn stopped before the disc was closed, so the disc may not read back.
    public var isUnfinished: Bool { lastSessionState == .incomplete || lastSessionState == .damaged }
}

/// What `DiscDrive.inspect()` found.
public struct DiscReport: Sendable {
    public struct BlockRead: Sendable {
        public var block: UInt32
        /// Nil when the block read back.
        public var error: String?
        public var duration: TimeInterval
    }

    public var disc: DiscState
    public var information: DiscInformation
    public var tracks: [TrackInformation]
    public var capacity: CapacityData?
    public var reads: [BlockRead]
}

/// What the app can do with the disc in 0.1.
public enum Writability: Sendable, Equatable {
    /// A blank disc this engine can write.
    case blank
    /// A rewritable disc with data on it. Erase it first.
    case needsErase
    /// A disc with room for another session. Adding sessions comes later.
    case appendable
    /// A blank disc of a kind this version can't write yet, such as DVD+RW or BD-RE.
    case unsupported
    /// A closed or pressed disc.
    case notWritable

    static func classify(profile: MediaProfile, info: DiscInformation) -> Writability {
        if info.status == .blank {
            return profile.writeMethod != nil ? .blank : .unsupported
        }
        if profile.supportsBlank && info.isErasable {
            return .needsErase
        }
        if info.status == .appendable {
            return .appendable
        }
        return .notWritable
    }
}

public enum DriveError: Error, Sendable, Equatable, CustomStringConvertible {
    case commandFailed(operation: String, status: UInt8, sense: SenseData?)
    case transport(TransportError)
    /// Another operation is already running on this drive.
    case busy
    case noDisc
    case notWritable(Writability)
    case unsupportedMedia(MediaProfile)
    case simulationUnsupported(MediaProfile)
    case doesNotFit(neededBlocks: Int, freeBlocks: Int)
    case verificationFailed(block: Int)
    case cancelled
    /// The drive doesn't offer the format type wanted. `offered` lists the types it does.
    case formatNotOffered(wanted: UInt8, offered: [UInt8])
    /// A step failed every try, and the burn was stopped.
    case abandoned(problem: String, tries: Int)
    /// The drive refused the write speed, before anything was written.
    case speedNotAccepted(label: String, reason: String)
    case image(String)

    public var description: String {
        switch self {
        case .commandFailed(let operation, let status, let sense):
            if let sense {
                return "\(operation) failed: \(sense.explanation) [\(sense)]"
            }
            return "\(operation) failed with SCSI status \(hex(status))."
        case .transport(let error):
            return error.description
        case .busy:
            return "The drive is busy with another operation."
        case .noDisc:
            return "There's no disc in the drive."
        case .notWritable(let writability):
            switch writability {
            case .needsErase: return "This disc has data on it. Erase it first."
            case .appendable: return "This disc already has data on it. Adding to it comes in a later version."
            case .unsupported: return "This version can't write this kind of disc yet."
            case .notWritable, .blank: return "This disc can't be written."
            }
        case .unsupportedMedia(let profile):
            return "This version can't write \(profile.name) discs yet."
        case .simulationUnsupported(let profile):
            return "\(profile.name) discs don't support a simulated burn."
        case .doesNotFit(let needed, let free):
            return "The files need \(needed) blocks but the disc has \(free) free."
        case .verificationFailed(let block):
            return "Verification failed: block \(block) on the disc doesn't match."
        case .cancelled:
            return "The burn was cancelled."
        case .formatNotOffered(let wanted, let offered):
            let list = offered.map { hex($0) }.joined(separator: ", ")
            return "The drive doesn't offer format type \(hex(wanted)) for this disc. It offers: \(list.isEmpty ? "none" : list)."
        case .abandoned(let problem, let tries):
            return "\(problem) Burn tried \(tries) times before stopping."
        case .speedNotAccepted(let label, let reason):
            return "The drive didn't accept the write speed \(label), so nothing was written. Choose another speed in the Burn sheet. (\(reason))"
        case .image(let message):
            return message
        }
    }
}

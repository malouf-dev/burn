import Foundation

/// The kind of disc in the drive, as reported by GET CONFIGURATION (MMC "profiles").
public struct MediaProfile: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let none = MediaProfile(rawValue: 0x0000)
    public static let cdROM = MediaProfile(rawValue: 0x0008)
    public static let cdR = MediaProfile(rawValue: 0x0009)
    public static let cdRW = MediaProfile(rawValue: 0x000A)
    public static let dvdROM = MediaProfile(rawValue: 0x0010)
    public static let dvdRSequential = MediaProfile(rawValue: 0x0011)
    public static let dvdRAM = MediaProfile(rawValue: 0x0012)
    public static let dvdRWRestrictedOverwrite = MediaProfile(rawValue: 0x0013)
    public static let dvdRWSequential = MediaProfile(rawValue: 0x0014)
    public static let dvdRDualLayerSequential = MediaProfile(rawValue: 0x0015)
    public static let dvdRDualLayerJump = MediaProfile(rawValue: 0x0016)
    public static let dvdPlusRW = MediaProfile(rawValue: 0x001A)
    public static let dvdPlusR = MediaProfile(rawValue: 0x001B)
    public static let dvdPlusRWDualLayer = MediaProfile(rawValue: 0x002A)
    public static let dvdPlusRDualLayer = MediaProfile(rawValue: 0x002B)
    public static let bdROM = MediaProfile(rawValue: 0x0040)
    public static let bdRSequential = MediaProfile(rawValue: 0x0041)
    public static let bdRRandom = MediaProfile(rawValue: 0x0042)
    public static let bdRE = MediaProfile(rawValue: 0x0043)

    public enum MediaClass: Sendable {
        case none, cd, dvd, bluRay, other
    }

    public var mediaClass: MediaClass {
        switch rawValue {
        case 0x0000: return .none
        case 0x0008...0x000A: return .cd
        case 0x0010...0x002B: return .dvd
        case 0x0040...0x0043: return .bluRay
        default: return .other
        }
    }

    /// How 0.1 writes this kind of disc, or nil if it can't yet.
    public var writeMethod: WriteMethod? {
        switch self {
        case .cdR, .cdRW: return .cdTrackAtOnce
        case .dvdRSequential, .dvdRWSequential, .dvdRDualLayerSequential: return .dvdMinusDiscAtOnce
        case .dvdPlusR: return .dvdPlusR
        case .dvdPlusRDualLayer: return .dvdPlusRDualLayer
        case .bdRSequential: return .bluRayR
        default: return nil
        }
    }

    /// Discs that can be erased and written again.
    public var isRewritable: Bool {
        [.cdRW, .dvdRWRestrictedOverwrite, .dvdRWSequential, .dvdPlusRW, .dvdPlusRWDualLayer, .bdRE, .dvdRAM]
            .contains(self)
    }

    /// Whether the engine can blank this disc with BLANK. DVD+RW and BD-RE are overwritten instead, in a later version.
    public var supportsBlank: Bool {
        self == .cdRW || self == .dvdRWSequential || self == .dvdRWRestrictedOverwrite
    }

    /// Whether this disc supports a simulated (laser off) write.
    public var supportsTestWrite: Bool {
        [.cdR, .cdRW, .dvdRSequential, .dvdRWSequential, .dvdRDualLayerSequential].contains(self)
    }

    /// Short name for people, such as "DVD+R".
    public var name: String {
        switch self {
        case .none: return "No disc"
        case .cdROM: return "CD-ROM"
        case .cdR: return "CD-R"
        case .cdRW: return "CD-RW"
        case .dvdROM: return "DVD-ROM"
        case .dvdRSequential: return "DVD-R"
        case .dvdRAM: return "DVD-RAM"
        case .dvdRWRestrictedOverwrite, .dvdRWSequential: return "DVD-RW"
        case .dvdRDualLayerSequential, .dvdRDualLayerJump: return "DVD-R DL"
        case .dvdPlusRW: return "DVD+RW"
        case .dvdPlusR: return "DVD+R"
        case .dvdPlusRWDualLayer: return "DVD+RW DL"
        case .dvdPlusRDualLayer: return "DVD+R DL"
        case .bdROM: return "BD-ROM"
        case .bdRSequential, .bdRRandom: return "BD-R"
        case .bdRE: return "BD-RE"
        default: return String(format: "Disc type %04Xh", rawValue)
        }
    }

    public var description: String { name }
}

/// The command sequence used to write a disc. Each needs confirming on real drives.
public enum WriteMethod: Sendable, Equatable {
    /// CD-R and CD-RW: track at once, Mode 1 data, then close the track and the session.
    case cdTrackAtOnce
    /// DVD-R and DVD-RW sequential: disc at once. Reserve the whole track first.
    case dvdMinusDiscAtOnce
    /// DVD+R: write, close the track, then finalise the disc.
    case dvdPlusR
    /// DVD+R DL: as DVD+R, with the double-layer finalise function.
    case dvdPlusRDualLayer
    /// BD-R in sequential recording mode: write, close the track, then finalise the disc.
    case bluRayR

    /// Blocks written must be a multiple of this. The engine pads with zeros.
    public var blockAlignment: Int {
        switch self {
        case .cdTrackAtOnce: return 1
        case .dvdMinusDiscAtOnce, .dvdPlusR, .dvdPlusRDualLayer: return 16
        case .bluRayR: return 32
        }
    }
}

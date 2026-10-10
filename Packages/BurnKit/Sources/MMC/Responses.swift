import Foundation

/// Who made the drive, from INQUIRY.
public struct InquiryData: Sendable, Equatable {
    public var vendor: String
    public var product: String
    public var revision: String
    /// Peripheral device type. Optical drives report 5.
    public var deviceType: UInt8

    public init(vendor: String, product: String, revision: String, deviceType: UInt8 = 5) {
        self.vendor = vendor
        self.product = product
        self.revision = revision
        self.deviceType = deviceType
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 36 else { return nil }
        deviceType = bytes[0] & 0x1F
        vendor = bytes.asciiString(at: 8, length: 8)
        product = bytes.asciiString(at: 16, length: 16)
        revision = bytes.asciiString(at: 32, length: 4)
    }

    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0x20, count: 36)
        result[0] = deviceType
        result[1] = 0x80 // removable medium
        result[2] = 0x05
        result[3] = 0x02
        result[4] = 31
        result[5] = 0
        result[6] = 0
        result[7] = 0
        func put(_ text: String, at offset: Int, length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() {
                result[offset + index] = byte
            }
        }
        put(vendor, at: 8, length: 8)
        put(product, at: 16, length: 16)
        put(revision, at: 32, length: 4)
        return result
    }
}

/// The parts of a GET CONFIGURATION response the engine uses.
public struct ConfigurationData: Sendable, Equatable {
    public var currentProfile: MediaProfile
    /// Every profile the drive supports, from the Profile List feature.
    public var supportedProfiles: [MediaProfile]

    public init(currentProfile: MediaProfile, supportedProfiles: [MediaProfile]) {
        self.currentProfile = currentProfile
        self.supportedProfiles = supportedProfiles
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        currentProfile = MediaProfile(rawValue: bytes.uint16(at: 6))
        let dataLength = Int(bytes.uint32(at: 0)) + 4
        let end = min(dataLength, bytes.count)
        var profiles: [MediaProfile] = []
        var offset = 8
        while offset + 4 <= end {
            let feature = bytes.uint16(at: offset)
            let additional = Int(bytes[offset + 3])
            if feature == 0x0000 {
                var descriptor = offset + 4
                while descriptor + 4 <= min(offset + 4 + additional, end) {
                    profiles.append(MediaProfile(rawValue: bytes.uint16(at: descriptor)))
                    descriptor += 4
                }
            }
            offset += 4 + additional
        }
        supportedProfiles = profiles
    }

    public var bytes: [UInt8] {
        var feature = [UInt8](repeating: 0, count: 4 + supportedProfiles.count * 4)
        feature[2] = 0x03 // persistent, current
        feature[3] = UInt8(supportedProfiles.count * 4)
        for (index, profile) in supportedProfiles.enumerated() {
            feature.put(profile.rawValue, at: 4 + index * 4)
            if profile == currentProfile { feature[4 + index * 4 + 2] = 0x01 }
        }
        var header = [UInt8](repeating: 0, count: 8)
        header.put(UInt32(4 + feature.count), at: 0)
        header.put(currentProfile.rawValue, at: 6)
        return header + feature
    }
}

/// State of the disc as a whole, from READ DISC INFORMATION.
public struct DiscInformation: Sendable, Equatable {
    public enum Status: UInt8, Sendable {
        case blank = 0
        case appendable = 1
        case complete = 2
        case other = 3
    }

    /// State of the last session.
    public enum SessionState: UInt8, Sendable {
        case empty = 0
        /// Written to but not closed, as after a burn that stopped part-way.
        case incomplete = 1
        case damaged = 2
        case complete = 3
    }

    public var status: Status
    public var lastSessionState: SessionState
    public var isErasable: Bool
    public var sessions: Int
    public var firstTrackInLastSession: Int
    public var lastTrackInLastSession: Int

    public init(status: Status, lastSessionState: SessionState? = nil, isErasable: Bool, sessions: Int,
                firstTrackInLastSession: Int, lastTrackInLastSession: Int) {
        self.status = status
        self.lastSessionState = lastSessionState ?? (status == .blank ? .empty : .complete)
        self.isErasable = isErasable
        self.sessions = sessions
        self.firstTrackInLastSession = firstTrackInLastSession
        self.lastTrackInLastSession = lastTrackInLastSession
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 12 else { return nil }
        status = Status(rawValue: bytes[2] & 0x03) ?? .other
        lastSessionState = SessionState(rawValue: (bytes[2] >> 2) & 0x03) ?? .damaged
        isErasable = bytes[2] & 0x10 != 0
        sessions = Int(bytes[4]) | Int(bytes[9]) << 8
        firstTrackInLastSession = Int(bytes[5]) | Int(bytes[10]) << 8
        lastTrackInLastSession = Int(bytes[6]) | Int(bytes[11]) << 8
    }

    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0, count: 34)
        result.put(UInt16(32), at: 0)
        result[2] = status.rawValue | (isErasable ? 0x10 : 0) | lastSessionState.rawValue << 2
        result[3] = 1
        result[4] = UInt8(truncatingIfNeeded: sessions)
        result[5] = UInt8(truncatingIfNeeded: firstTrackInLastSession)
        result[6] = UInt8(truncatingIfNeeded: lastTrackInLastSession)
        result[9] = UInt8(truncatingIfNeeded: sessions >> 8)
        result[10] = UInt8(truncatingIfNeeded: firstTrackInLastSession >> 8)
        result[11] = UInt8(truncatingIfNeeded: lastTrackInLastSession >> 8)
        return result
    }
}

/// One track, from READ TRACK INFORMATION.
public struct TrackInformation: Sendable, Equatable {
    public var track: Int
    public var session: Int
    public var isBlank: Bool
    public var isReserved: Bool
    public var start: UInt32
    /// Where the next write must start, when `nextWritableValid` is set.
    public var nextWritable: UInt32
    public var nextWritableValid: Bool
    public var freeBlocks: UInt32
    public var size: UInt32

    public init(track: Int, session: Int, isBlank: Bool, isReserved: Bool = false, start: UInt32,
                nextWritable: UInt32, nextWritableValid: Bool, freeBlocks: UInt32, size: UInt32) {
        self.track = track
        self.session = session
        self.isBlank = isBlank
        self.isReserved = isReserved
        self.start = start
        self.nextWritable = nextWritable
        self.nextWritableValid = nextWritableValid
        self.freeBlocks = freeBlocks
        self.size = size
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 28 else { return nil }
        track = Int(bytes[2]) | Int(bytes.byte(at: 32)) << 8
        session = Int(bytes[3]) | Int(bytes.byte(at: 33)) << 8
        isReserved = bytes[6] & 0x80 != 0
        isBlank = bytes[6] & 0x40 != 0
        nextWritableValid = bytes[7] & 0x01 != 0
        start = bytes.uint32(at: 8)
        nextWritable = bytes.uint32(at: 12)
        freeBlocks = bytes.uint32(at: 16)
        size = bytes.uint32(at: 24)
    }

    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0, count: 48)
        result.put(UInt16(46), at: 0)
        result[2] = UInt8(truncatingIfNeeded: track)
        result[3] = UInt8(truncatingIfNeeded: session)
        result[5] = 0x04
        result[6] = (isReserved ? 0x80 : 0) | (isBlank ? 0x40 : 0) | 0x01
        result[7] = nextWritableValid ? 0x01 : 0
        result.put(start, at: 8)
        result.put(nextWritable, at: 12)
        result.put(freeBlocks, at: 16)
        result.put(size, at: 24)
        result[32] = UInt8(truncatingIfNeeded: track >> 8)
        result[33] = UInt8(truncatingIfNeeded: session >> 8)
        return result
    }
}

/// READ CAPACITY: the last readable block.
public struct CapacityData: Sendable, Equatable {
    public var lastBlock: UInt32
    public var blockLength: UInt32

    public init(lastBlock: UInt32, blockLength: UInt32 = 2048) {
        self.lastBlock = lastBlock
        self.blockLength = blockLength
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        lastBlock = bytes.uint32(at: 0)
        blockLength = bytes.uint32(at: 4)
    }

    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0, count: 8)
        result.put(lastBlock, at: 0)
        result.put(blockLength, at: 4)
        return result
    }
}

/// The Write Parameters mode page (05h), which CD and DVD-R writing needs.
public struct WriteParameters: Sendable, Equatable {
    public enum WriteType: UInt8, Sendable {
        case packetIncremental = 0
        case trackAtOnce = 1
        case sessionAtOnce = 2
        case raw = 3
    }

    public var writeType: WriteType
    public var testWrite: Bool
    public var bufferUnderrunProtection: Bool
    /// 0: no next session, so the disc is closed.
    public var multiSession: UInt8
    public var trackMode: UInt8
    public var dataBlockType: UInt8

    public init(writeType: WriteType, testWrite: Bool = false, bufferUnderrunProtection: Bool = true,
                multiSession: UInt8 = 0, trackMode: UInt8 = 4, dataBlockType: UInt8 = 8) {
        self.writeType = writeType
        self.testWrite = testWrite
        self.bufferUnderrunProtection = bufferUnderrunProtection
        self.multiSession = multiSession
        self.trackMode = trackMode
        self.dataBlockType = dataBlockType
    }

    /// Applies these settings to a page read with MODE SENSE, keeping the drive's other fields.
    /// `page` starts at the page code byte.
    public func applied(to page: [UInt8]) -> [UInt8] {
        var result = page
        if result.count < 16 {
            result += [UInt8](repeating: 0, count: 16 - result.count)
        }
        result[0] = 0x05
        result[2] = (result[2] & 0x80) | (bufferUnderrunProtection ? 0x40 : 0) | (testWrite ? 0x10 : 0) | writeType.rawValue
        result[3] = (multiSession & 0x03) << 6 | (trackMode & 0x0F)
        result[4] = dataBlockType & 0x0F
        result[8] = 0x00 // session format: CD-ROM / CD-DA
        return result
    }

    public init?(page: [UInt8]) {
        guard page.count >= 5, page[0] & 0x3F == 0x05 else { return nil }
        writeType = WriteType(rawValue: page[2] & 0x0F) ?? .packetIncremental
        testWrite = page[2] & 0x10 != 0
        bufferUnderrunProtection = page[2] & 0x40 != 0
        multiSession = page[3] >> 6
        trackMode = page[3] & 0x0F
        dataBlockType = page[4] & 0x0F
    }
}

/// Splits a MODE SENSE (10) response into its header and first page.
public enum ModePage {
    /// Returns the first page's bytes (from the page code), skipping the 8-byte header and any block descriptors.
    public static func firstPage(inModeSense bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 8 else { return nil }
        let blockDescriptorLength = Int(bytes.uint16(at: 6))
        let pageStart = 8 + blockDescriptorLength
        guard pageStart + 2 <= bytes.count else { return nil }
        let pageLength = Int(bytes[pageStart + 1]) + 2
        let end = min(pageStart + pageLength, bytes.count)
        return Array(bytes[pageStart..<end])
    }

    /// Builds MODE SELECT (10) parameters for one page: an 8-byte header with no block descriptors, then the page.
    public static func selectParameters(page: [UInt8]) -> [UInt8] {
        var pageBytes = page
        pageBytes[0] &= 0x3F // the PS bit must be zero for MODE SELECT
        return [UInt8](repeating: 0, count: 8) + pageBytes
    }

    /// A MODE SENSE (10) response carrying one page, for the simulated drive.
    public static func senseResponse(page: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 8)
        header.put(UInt16(6 + page.count), at: 0)
        return header + page
    }
}

/// One format the drive can apply to the disc, from READ FORMAT CAPACITIES.
/// A speed the drive can write the disc in it at, from GET PERFORMANCE (type 03h).
public struct WriteSpeed: Sendable, Hashable, Comparable, Codable {
    /// Kilobytes (1,000 bytes) a second, as the drive reports it.
    public var kilobytesPerSecond: UInt32

    public init(kilobytesPerSecond: UInt32) {
        self.kilobytesPerSecond = kilobytesPerSecond
    }

    public static func < (lhs: WriteSpeed, rhs: WriteSpeed) -> Bool {
        lhs.kilobytesPerSecond < rhs.kilobytesPerSecond
    }

    /// The disc type's 1x in kilobytes a second: a CD's 75 blocks of 2,352 bytes, and the
    /// DVD and Blu-ray standards' own.
    public static func single(for mediaClass: MediaProfile.MediaClass) -> Double {
        switch mediaClass {
        case .cd: return 176.4
        case .bluRay: return 4_495.5
        default: return 1_385
        }
    }

    /// Such as "2x", or "2.4x" when it isn't a whole multiple.
    public func label(for mediaClass: MediaProfile.MediaClass) -> String {
        let multiple = Double(kilobytesPerSecond) / Self.single(for: mediaClass)
        let rounded = multiple.rounded()
        if abs(multiple - rounded) < 0.1 { return "\(Int(rounded))x" }
        return String(format: "%.1fx", multiple)
    }

    /// The speeds in a GET PERFORMANCE (type 03h) answer, slowest first, each once. Drives list
    /// a speed again for each way of spinning the disc.
    public static func list(from bytes: [UInt8]) -> [WriteSpeed] {
        guard bytes.count >= 8 else { return [] }
        let end = min(bytes.count, 4 + Int(bytes.uint32(at: 0)))
        var speeds = Set<WriteSpeed>()
        var offset = 8
        while offset + 16 <= end {
            let speed = bytes.uint32(at: offset + 12)
            if speed > 0 { speeds.insert(WriteSpeed(kilobytesPerSecond: speed)) }
            offset += 16
        }
        return speeds.sorted()
    }

    /// Write speed descriptors in the form GET PERFORMANCE returns them, for the simulated drive.
    public static func descriptors(_ speeds: [WriteSpeed], endBlock: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes.put(UInt32(4 + speeds.count * 16), at: 0)
        for speed in speeds {
            var descriptor = [UInt8](repeating: 0, count: 16)
            descriptor.put(endBlock, at: 4)
            descriptor.put(speed.kilobytesPerSecond, at: 8)
            descriptor.put(speed.kilobytesPerSecond, at: 12)
            bytes += descriptor
        }
        return bytes
    }
}

public struct FormatDescriptor: Sendable, Equatable {
    public var blocks: UInt32
    /// Such as 10h, a full format of a DVD-RW.
    public var formatType: UInt8
    /// The format type's own parameter, 24 bits.
    public var parameter: UInt32

    public init(blocks: UInt32, formatType: UInt8, parameter: UInt32) {
        self.blocks = blocks
        self.formatType = formatType
        self.parameter = parameter
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        blocks = bytes.uint32(at: 0)
        formatType = bytes[4] >> 2
        parameter = UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
    }

    public var bytes: [UInt8] {
        var result = [UInt8](repeating: 0, count: 8)
        result.put(blocks, at: 0)
        result[4] = formatType << 2
        result[5] = UInt8(truncatingIfNeeded: parameter >> 16)
        result[6] = UInt8(truncatingIfNeeded: parameter >> 8)
        result[7] = UInt8(truncatingIfNeeded: parameter)
        return result
    }
}

/// READ FORMAT CAPACITIES: the disc's current capacity and the formats on offer.
public struct FormatCapacities: Sendable, Equatable {
    public var currentBlocks: UInt32
    /// 1: unformatted or blank, 2: formatted, 3: no disc.
    public var currentDescriptorType: UInt8
    public var formats: [FormatDescriptor]

    public init(currentBlocks: UInt32, currentDescriptorType: UInt8, formats: [FormatDescriptor]) {
        self.currentBlocks = currentBlocks
        self.currentDescriptorType = currentDescriptorType
        self.formats = formats
    }

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 12 else { return nil }
        let listLength = Int(bytes[3])
        currentBlocks = bytes.uint32(at: 4)
        currentDescriptorType = bytes[8] & 0x03
        var formats: [FormatDescriptor] = []
        var offset = 12
        while offset + 8 <= min(bytes.count, 4 + listLength) {
            if let descriptor = FormatDescriptor(bytes: Array(bytes[offset..<(offset + 8)])) {
                formats.append(descriptor)
            }
            offset += 8
        }
        self.formats = formats
    }

    public var bytes: [UInt8] {
        var result: [UInt8] = [0, 0, 0, UInt8(8 * (formats.count + 1))]
        var current = [UInt8](repeating: 0, count: 8)
        current.put(currentBlocks, at: 0)
        current[4] = currentDescriptorType & 0x03
        current[6] = 0x08 // 2,048-byte blocks
        result += current
        for format in formats { result += format.bytes }
        return result
    }
}


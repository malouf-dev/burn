import Foundation
import MMC

/// An in-memory optical drive that follows the MMC rules the engine depends on.
///
/// It is strict on purpose: writes must start at the next writable block, CDs need the
/// write parameters page set, DVD-R needs a reserved track, and writing needs exclusive access.
/// That way engine mistakes fail in tests instead of on real discs.
public final class SimulatedDrive: SCSITransport, @unchecked Sendable {
    public struct Media: Sendable {
        public var profile: MediaProfile
        public var capacityBlocks: UInt32
        public var blocks: [UInt32: [UInt8]] = [:]
        public var nextWritable: UInt32 = 0
        public var closed = false
        /// A close that was cut off part-way, as when the connection reset during it.
        public var closeInterrupted = false
        /// The drive reports a quick erase of this disc as failed. A full erase works.
        public var quickEraseFails = false
        /// The drive reports every erase of this disc as failed. Formatting works. Hardware runs 12 to 14.
        public var eraseFails = false
        /// Written blocks that don't read back. macOS gets stuck reading a disc like this: it
        /// holds the drive, so exclusive access is refused as busy and eject isn't permitted,
        /// unless the drive was taken before the disc went in. Hardware run 9.
        public var unreadable = false
        public var reserved: UInt32?

        public init(profile: MediaProfile, capacityBlocks: UInt32) {
            self.profile = profile
            self.capacityBlocks = capacityBlocks
        }

        /// A disc that already has `blockCount` blocks of data and is closed.
        public static func written(profile: MediaProfile, capacityBlocks: UInt32, blockCount: UInt32) -> Media {
            var media = Media(profile: profile, capacityBlocks: capacityBlocks)
            for block in 0..<blockCount {
                media.blocks[block] = [UInt8](repeating: 0xAB, count: MMC.blockSize)
            }
            media.nextWritable = blockCount
            media.closed = true
            return media
        }

        var isBlank: Bool { nextWritable == 0 && !closed }
    }

    private let lock = NSLock()
    private var inquiry: InquiryData
    private var supportedProfiles: [MediaProfile]
    private var media: Media?
    private var exclusive = false
    private var writeParametersPage: [UInt8]
    private var history: [[UInt8]] = []
    private var writeCount = 0
    private var pendingUnitAttention = false
    /// Sense data for the next TEST UNIT READY, as when an immediate operation fails.
    private var pendingSense: SenseData?

    /// When set, reads of this block return corrupted data.
    public var corruptReadBlock: UInt32? {
        get { withLock { _corruptReadBlock } }
        set { withLock { _corruptReadBlock = newValue } }
    }
    private var _corruptReadBlock: UInt32?

    /// When set, the next READ starting at this block returns its data 8,184 bytes late, with no
    /// error, then reads work again. The BD-R drive did this during verify in hardware runs 18
    /// and 20, while the disc itself held the right data.
    public var misplacedReadAt: UInt32? {
        get { withLock { _misplacedReadAt } }
        set { withLock { _misplacedReadAt = newValue } }
    }
    private var _misplacedReadAt: UInt32?
    public static let misplacedReadShift = 8184

    /// When set, every nth WRITE first answers "long write in progress", as busy drives do.
    public var longWriteEvery: Int? {
        get { withLock { _longWriteEvery } }
        set { withLock { _longWriteEvery = newValue } }
    }
    private var _longWriteEvery: Int?

    /// When set, the disc disappears after this many successful writes.
    public var removeMediaAfterWrites: Int? {
        get { withLock { _removeMediaAfterWrites } }
        set { withLock { _removeMediaAfterWrites = newValue } }
    }
    private var _removeMediaAfterWrites: Int?

    /// Like a USB drive, a long command sent without the immediate bit times out in the transport.
    /// A close cut off this way leaves the disc unfinished, which hardware run 7 suggests but
    /// hasn't shown for certain. On by default so the engine must poll.
    public var timesOutLongCommands: Bool {
        get { withLock { _timesOutLongCommands } }
        set { withLock { _timesOutLongCommands = newValue } }
    }
    private var _timesOutLongCommands = true

    /// When true, long commands sent with the immediate bit are rejected as an invalid field.
    public var rejectsImmediateBit: Bool {
        get { withLock { _rejectsImmediateBit } }
        set { withLock { _rejectsImmediateBit = newValue } }
    }
    private var _rejectsImmediateBit = false

    /// After a long command sent with the immediate bit, TEST UNIT READY reports "operation in
    /// progress" this many times, with progress, before the drive is ready.
    public var busyPollsAfterLongCommand: Int {
        get { withLock { _busyPollsAfterLongCommand } }
        set { withLock { _busyPollsAfterLongCommand = newValue } }
    }
    private var _busyPollsAfterLongCommand = 0
    private var busyPollsRemaining = 0

    /// True while macOS has the disc mounted. Ejecting without exclusive access is then refused,
    /// and taking exclusive access unmounts it, as the IOKit transport does.
    public var isMounted: Bool {
        get { withLock { _isMounted } }
        set { withLock { _isMounted = newValue } }
    }
    private var _isMounted = false

    /// True while the tray is locked, as macOS locks it for a mounted disc. The lock outlasts an
    /// unmount, and eject is refused with 05/53/02 until PREVENT ALLOW MEDIUM REMOVAL unlocks it.
    public var mediumRemovalPrevented: Bool {
        get { withLock { _mediumRemovalPrevented } }
        set { withLock { _mediumRemovalPrevented = newValue } }
    }
    private var _mediumRemovalPrevented = false

    /// When true, exclusive access is refused, as when a disc can't be unmounted.
    public var refusesExclusiveAccess: Bool {
        get { withLock { _refusesExclusiveAccess } }
        set { withLock { _refusesExclusiveAccess = newValue } }
    }
    private var _refusesExclusiveAccess = false

    /// Exclusive access is refused as busy this many times, then allowed, as while macOS is
    /// still reading a disc.
    public var exclusiveAccessRefusals: Int {
        get { withLock { _exclusiveAccessRefusals } }
        set { withLock { _exclusiveAccessRefusals = newValue } }
    }
    private var _exclusiveAccessRefusals = 0

    public init(inquiry: InquiryData = InquiryData(vendor: "SIMULATE", product: "Disc Burner", revision: "1.00"),
                supportedProfiles: [MediaProfile] = [.bdRE, .bdRSequential, .dvdPlusRDualLayer, .dvdPlusR, .dvdPlusRW,
                                                     .dvdRWSequential, .dvdRSequential, .cdRW, .cdR],
                media: Media? = nil) {
        self.inquiry = inquiry
        self.supportedProfiles = supportedProfiles
        self.media = media
        var page = [UInt8](repeating: 0, count: 52)
        page[0] = 0x05
        page[1] = 0x32
        page[2] = 0x40 // buffer underrun protection on, packet writing
        page[3] = 0x04
        page[4] = 0x08
        writeParametersPage = page
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Test controls

    public func insert(_ newMedia: Media) {
        withLock {
            media = newMedia
            pendingUnitAttention = true
        }
    }

    public func removeMedia() {
        withLock { media = nil }
    }

    public var currentMedia: Media? {
        withLock { media }
    }

    public var hasExclusiveAccess: Bool {
        withLock { exclusive }
    }

    /// The format type of the last FORMAT UNIT received.
    public var lastFormatType: UInt8? {
        withLock { _lastFormatType }
    }
    private var _lastFormatType: UInt8?

    /// Operation codes of every command received, in order.
    public var operationCodes: [UInt8] {
        withLock { history.compactMap { $0.first } }
    }

    public var commandHistory: [[UInt8]] {
        withLock { history }
    }

    /// The bytes written from `block`, for comparing with the image.
    public func recordedBytes(from block: UInt32, count: UInt32) -> [UInt8] {
        withLock {
            var result: [UInt8] = []
            for index in block..<(block + count) {
                result += media?.blocks[index] ?? [UInt8](repeating: 0, count: MMC.blockSize)
            }
            return result
        }
    }

    // MARK: - SCSITransport

    public func beginExclusiveAccess() throws {
        try withLock {
            if _refusesExclusiveAccess { throw TransportError.exclusiveAccessDenied(code: -536870187) }
            if !exclusive, media?.unreadable == true { throw TransportError.exclusiveAccessDenied(code: -536870187) }
            if _exclusiveAccessRefusals > 0 {
                _exclusiveAccessRefusals -= 1
                throw TransportError.exclusiveAccessDenied(code: -536870187)
            }
            _isMounted = false
            exclusive = true
        }
    }

    public func endExclusiveAccess() {
        withLock { exclusive = false }
    }

    public func execute(_ command: SCSICommand) throws -> SCSIResponse {
        try withLock { try handle(command) }
    }

    private static let sharedCommands: Set<UInt8> = [0x00, 0x12, 0x46, 0x51, 0x52, 0x5A, 0x43, 0x1B]

    private func handle(_ command: SCSICommand) throws -> SCSIResponse {
        let cdb = command.cdb
        history.append(cdb)
        if !exclusive && !Self.sharedCommands.contains(command.operationCode) {
            throw TransportError.needsExclusiveAccess
        }

        if (_isMounted || media?.unreadable == true) && !exclusive && command.operationCode == 0x1B
            && cdb[4] & 0x03 == 0x02 {
            // IOKit's kIOReturnNotPermitted, as for a real drive with a mounted disc.
            throw TransportError.ioError(code: Int32(bitPattern: 0xE000_02E2))
        }

        if busyPollsRemaining > 0 && command.operationCode != 0x00 {
            return .check(.operationInProgress)
        }

        if let immediateBit = Self.longCommandImmediateBits[command.operationCode] {
            if cdb[1] & immediateBit != 0 && _rejectsImmediateBit {
                return .check(.invalidFieldInCDB)
            }
            if cdb[1] & immediateBit == 0 && _timesOutLongCommands {
                if command.operationCode != 0xA1, var media, media.nextWritable > 0 {
                    media.closeInterrupted = true
                    self.media = media
                }
                throw TransportError.notDelivered(reason: "the connection timed out (simulated)")
            }
            let response = try handleCommand(command)
            if cdb[1] & immediateBit != 0 && response.isGood {
                busyPollsRemaining = _busyPollsAfterLongCommand
            }
            return response
        }
        return try handleCommand(command)
    }

    /// Long operations, and the immediate bit in byte 1 of each.
    private static let longCommandImmediateBits: [UInt8: UInt8] = [0x35: 0x02, 0x5B: 0x01, 0xA1: 0x10]

    private func handleCommand(_ command: SCSICommand) throws -> SCSIResponse {
        let cdb = command.cdb
        switch command.operationCode {
        case 0x00: return testUnitReady()
        case 0x12: return .good(Array(inquiry.bytes.prefix(allocation(command))))
        case 0x46: return getConfiguration(command)
        case 0x51: return readDiscInformation(command)
        case 0x52: return readTrackInformation(command)
        case 0x25: return readCapacity()
        case 0x5A: return modeSense(command)
        case 0x55: return modeSelect(command)
        case 0x53: return reserveTrack(cdb)
        case 0x2A: return write(command)
        case 0x28: return read(cdb)
        case 0x35: return synchronizeCache()
        case 0x5B: return closeTrackSession(cdb)
        case 0xA1: return blank(cdb)
        case 0x23: return readFormatCapacities(command)
        case 0x04: return formatUnit(command)
        case 0x1B: return startStopUnit(cdb)
        case 0x1E:
            _mediumRemovalPrevented = cdb[4] & 0x01 != 0
            return .good()
        default: return .check(.invalidCommand)
        }
    }

    private func allocation(_ command: SCSICommand) -> Int {
        if case .fromDevice(let length) = command.direction { return length }
        return 0
    }

    private func testUnitReady() -> SCSIResponse {
        guard media != nil else { return .check(.mediumNotPresent) }
        if busyPollsRemaining > 0 {
            let total = max(1, _busyPollsAfterLongCommand)
            let done = Double(total - busyPollsRemaining) / Double(total)
            busyPollsRemaining -= 1
            return .check(SenseData(key: 0x02, asc: 0x04, ascq: 0x07, progress: done))
        }
        if let sense = pendingSense {
            pendingSense = nil
            return .check(sense)
        }
        if pendingUnitAttention {
            pendingUnitAttention = false
            return .check(.mediumChanged)
        }
        return .good()
    }

    private func getConfiguration(_ command: SCSICommand) -> SCSIResponse {
        let data = ConfigurationData(currentProfile: media?.profile ?? .none, supportedProfiles: supportedProfiles).bytes
        return .good(Array(data.prefix(allocation(command))))
    }

    private func readDiscInformation(_ command: SCSICommand) -> SCSIResponse {
        guard let media else { return .check(.mediumNotPresent) }
        let status: DiscInformation.Status = media.closed ? .complete : (media.isBlank ? .blank : .appendable)
        let info = DiscInformation(status: status, lastSessionState: media.closeInterrupted ? .incomplete : nil,
                                   isErasable: media.profile.isRewritable, sessions: 1,
                                   firstTrackInLastSession: 1, lastTrackInLastSession: 1)
        return .good(Array(info.bytes.prefix(allocation(command))))
    }

    private func readTrackInformation(_ command: SCSICommand) -> SCSIResponse {
        guard let media else { return .check(.mediumNotPresent) }
        let track = command.cdb.uint32(at: 2)
        guard track == 1 else { return .check(.invalidFieldInCDB) }
        let limit = media.reserved ?? media.capacityBlocks
        let free = media.closed ? 0 : limit - min(limit, media.nextWritable)
        let info = TrackInformation(track: 1, session: 1, isBlank: media.nextWritable == 0,
                                    isReserved: media.reserved != nil, start: 0,
                                    nextWritable: media.nextWritable, nextWritableValid: !media.closed,
                                    freeBlocks: free, size: media.closed ? media.nextWritable : limit)
        return .good(Array(info.bytes.prefix(allocation(command))))
    }

    private func readCapacity() -> SCSIResponse {
        guard let media else { return .check(.mediumNotPresent) }
        let last = media.nextWritable == 0 ? 0 : media.nextWritable - 1
        return .good(CapacityData(lastBlock: last).bytes)
    }

    private func modeSense(_ command: SCSICommand) -> SCSIResponse {
        guard command.cdb[2] & 0x3F == 0x05 else { return .check(.invalidFieldInCDB) }
        return .good(Array(ModePage.senseResponse(page: writeParametersPage).prefix(allocation(command))))
    }

    private func modeSelect(_ command: SCSICommand) -> SCSIResponse {
        guard case .toDevice(let parameters) = command.direction, parameters.count > 10 else {
            return .check(.invalidFieldInCDB)
        }
        let page = Array(parameters[8...])
        guard page[0] & 0x3F == 0x05, WriteParameters(page: page) != nil else { return .check(.invalidFieldInCDB) }
        writeParametersPage = page
        return .good()
    }

    private var writeParameters: WriteParameters? {
        WriteParameters(page: writeParametersPage)
    }

    private func reserveTrack(_ cdb: [UInt8]) -> SCSIResponse {
        guard var media else { return .check(.mediumNotPresent) }
        guard media.profile.writeMethod == .dvdMinusDiscAtOnce, media.isBlank, media.reserved == nil else {
            return .check(.invalidFieldInCDB)
        }
        let size = cdb.uint32(at: 5)
        guard size > 0, size <= media.capacityBlocks else { return .check(.invalidFieldInCDB) }
        media.reserved = size
        self.media = media
        return .good()
    }

    private func write(_ command: SCSICommand) -> SCSIResponse {
        guard var media else { return .check(.mediumNotPresent) }
        guard case .toDevice(let data) = command.direction else { return .check(.invalidFieldInCDB) }
        guard !media.closed else { return .check(.invalidAddressForWrite) }

        if let every = _longWriteEvery, every > 0 {
            writeCount += 1
            if writeCount % every == 0 { return .check(.longWriteInProgress) }
        }

        let lba = command.cdb.uint32(at: 2)
        let blocks = UInt32(command.cdb.uint16(at: 7))
        guard data.count == Int(blocks) * MMC.blockSize else { return .check(.invalidFieldInCDB) }

        switch media.profile.writeMethod {
        case .cdTrackAtOnce:
            guard let parameters = writeParameters, parameters.writeType == .trackAtOnce,
                  parameters.dataBlockType == 8 else { return .check(.illegalModeForTrack) }
        case .dvdMinusDiscAtOnce:
            guard let parameters = writeParameters, parameters.writeType == .sessionAtOnce,
                  media.reserved != nil else { return .check(.illegalModeForTrack) }
        case .some:
            break
        case nil:
            return .check(.incompatibleMedium)
        }

        guard lba == media.nextWritable else { return .check(.invalidAddressForWrite) }
        let limit = media.reserved ?? media.capacityBlocks
        guard lba + blocks <= limit else { return .check(SenseData(key: 0x05, asc: 0x63, ascq: 0x00)) }

        let testWrite = writeParameters?.testWrite ?? false
        if !testWrite {
            for index in 0..<Int(blocks) {
                let start = index * MMC.blockSize
                media.blocks[lba + UInt32(index)] = Array(data[start..<(start + MMC.blockSize)])
            }
        }
        media.nextWritable += blocks
        self.media = media

        if let remaining = _removeMediaAfterWrites {
            if remaining <= 1 {
                self.media = nil
                _removeMediaAfterWrites = nil
            } else {
                _removeMediaAfterWrites = remaining - 1
            }
        }
        return .good()
    }

    private func read(_ cdb: [UInt8]) -> SCSIResponse {
        guard let media else { return .check(.mediumNotPresent) }
        let lba = cdb.uint32(at: 2)
        let blocks = UInt32(cdb.uint16(at: 7))
        guard lba + blocks <= media.nextWritable else { return .check(.lbaOutOfRange) }
        if media.unreadable { return .check(.unrecoveredReadError) }
        var result: [UInt8] = []
        result.reserveCapacity(Int(blocks) * MMC.blockSize)
        for block in lba..<(lba + blocks) {
            var bytes = media.blocks[block] ?? [UInt8](repeating: 0, count: MMC.blockSize)
            if block == _corruptReadBlock { bytes[100] ^= 0xFF }
            result += bytes
        }
        if lba == _misplacedReadAt {
            _misplacedReadAt = nil
            let shift = Self.misplacedReadShift
            var after: [UInt8] = []
            for block in (lba + blocks)..<(lba + blocks + UInt32(shift / MMC.blockSize + 1)) {
                after += media.blocks[block] ?? [UInt8](repeating: 0, count: MMC.blockSize)
            }
            result = Array((result + after)[shift..<(shift + result.count)])
        }
        return .good(result)
    }

    private func synchronizeCache() -> SCSIResponse {
        guard var media else { return .check(.mediumNotPresent) }
        // Disc at once closes the disc once the reserved track is full.
        if media.profile.writeMethod == .dvdMinusDiscAtOnce, let reserved = media.reserved,
           media.nextWritable == reserved, !(writeParameters?.testWrite ?? false) {
            media.closed = true
            self.media = media
        }
        return .good()
    }

    private func closeTrackSession(_ cdb: [UInt8]) -> SCSIResponse {
        guard var media else { return .check(.mediumNotPresent) }
        let function = cdb[2] & 0x07
        switch function {
        case 0x01:
            return .good()
        case 0x02, 0x05, 0x06:
            guard media.nextWritable > 0 else { return .check(SenseData(key: 0x05, asc: 0x2C, ascq: 0x00)) }
            media.closed = true
            self.media = media
            return .good()
        default:
            return .check(.invalidFieldInCDB)
        }
    }

    private func readFormatCapacities(_ command: SCSICommand) -> SCSIResponse {
        guard let media else { return .check(.mediumNotPresent) }
        var formats: [FormatDescriptor] = []
        if media.profile == .dvdRWSequential || media.profile == .dvdRWRestrictedOverwrite {
            formats.append(FormatDescriptor(blocks: media.capacityBlocks, formatType: 0x10, parameter: 16))
            formats.append(FormatDescriptor(blocks: media.capacityBlocks, formatType: 0x15, parameter: 16))
        }
        let formatted = media.profile == .dvdRWRestrictedOverwrite
        let capacities = FormatCapacities(currentBlocks: media.capacityBlocks,
                                          currentDescriptorType: formatted ? 2 : 1, formats: formats)
        return .good(Array(capacities.bytes.prefix(allocation(command))))
    }

    private func formatUnit(_ command: SCSICommand) -> SCSIResponse {
        guard var media else { return .check(.mediumNotPresent) }
        guard case .toDevice(let parameters) = command.direction, parameters.count >= 12,
              command.cdb[1] & 0x17 == 0x11 else {
            return .check(.invalidFieldInCDB)
        }
        guard let descriptor = FormatDescriptor(bytes: Array(parameters[4..<12])),
              descriptor.formatType == 0x10 || descriptor.formatType == 0x15,
              media.profile == .dvdRWSequential || media.profile == .dvdRWRestrictedOverwrite else {
            return .check(SenseData(key: 0x05, asc: 0x26, ascq: 0x00))
        }
        _lastFormatType = descriptor.formatType
        media.profile = .dvdRWRestrictedOverwrite
        media.blocks = [:]
        media.nextWritable = 0
        media.closed = true
        media.reserved = nil
        media.closeInterrupted = false
        media.unreadable = false
        media.quickEraseFails = false
        media.eraseFails = false
        self.media = media
        if parameters[1] & 0x02 != 0 { busyPollsRemaining = _busyPollsAfterLongCommand }
        return .good()
    }

    private func blank(_ cdb: [UInt8]) -> SCSIResponse {
        guard var media else { return .check(.mediumNotPresent) }
        guard media.profile.supportsBlank else { return .check(.incompatibleMedium) }
        let quick = cdb[1] & 0x07 == 0x01
        if media.eraseFails || (quick && media.quickEraseFails) {
            // Like the real drive: the command is accepted and the failure shows up afterwards.
            pendingSense = .eraseFailure
            return .good()
        }
        media.quickEraseFails = false
        // Blanking a restricted-overwrite DVD-RW returns it to sequential recording.
        if media.profile == .dvdRWRestrictedOverwrite { media.profile = .dvdRWSequential }
        media.blocks = [:]
        media.nextWritable = 0
        media.closed = false
        media.closeInterrupted = false
        media.unreadable = false
        media.reserved = nil
        self.media = media
        return .good()
    }

    private func startStopUnit(_ cdb: [UInt8]) -> SCSIResponse {
        let loadEject = cdb[4] & 0x02 != 0
        let start = cdb[4] & 0x01 != 0
        if loadEject && !start {
            if _mediumRemovalPrevented { return .check(SenseData(key: 0x05, asc: 0x53, ascq: 0x02)) }
            media = nil
        }
        return .good()
    }
}

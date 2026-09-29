import Foundation

public struct WriteOptions: Sendable {
    /// Laser-off test write, on media that support it. Nothing is recorded, so nothing is verified.
    public var simulate: Bool
    /// Read the disc back and compare it with the image. Always on in the app.
    public var verify: Bool
    public var ejectWhenDone: Bool

    public init(simulate: Bool = false, verify: Bool = true, ejectWhenDone: Bool = false) {
        self.simulate = simulate
        self.verify = verify
        self.ejectWhenDone = ejectWhenDone
    }
}

public enum WritePhase: Sendable, Equatable {
    case preparing
    case writing
    case closing
    case verifying
}

public struct WriteProgress: Sendable, Equatable {
    public var phase: WritePhase
    public var completedBlocks: Int
    public var totalBlocks: Int
    /// Progress the drive reports while closing the disc, if it reports any.
    public var driveProgress: Double?

    public init(phase: WritePhase, completedBlocks: Int, totalBlocks: Int, driveProgress: Double? = nil) {
        self.phase = phase
        self.completedBlocks = completedBlocks
        self.totalBlocks = totalBlocks
        self.driveProgress = driveProgress
    }

    public var fraction: Double {
        switch phase {
        case .preparing: return 0
        case .closing: return driveProgress ?? 0
        case .writing, .verifying: return totalBlocks == 0 ? 0 : Double(completedBlocks) / Double(totalBlocks)
        }
    }

    /// True when there is no meaningful fraction to show.
    public var isIndeterminate: Bool {
        phase == .preparing || (phase == .closing && driveProgress == nil)
    }
}

public struct WriteReport: Sendable, Equatable {
    public var profile: MediaProfile
    public var startBlock: UInt32
    public var imageBlocks: Int
    public var writtenBlocks: Int
    public var verified: Bool
    public var simulated: Bool
    public var duration: TimeInterval
}

/// The burning engine for one drive. Commands run one at a time on a private queue,
/// so blocking calls never tie up Swift's cooperative threads.
public actor DiscDrive {
    public nonisolated let transport: any SCSITransport
    public nonisolated let log: CommandLog
    private let queue = DispatchQueue(label: "BurnKit.DiscDrive")
    private var isBusy = false

    /// Blocks per WRITE(10) and READ(10): 32 KiB, a whole DVD ECC block pair.
    static let transferBlocks = 16

    /// How long to wait between polls while the drive finishes a long operation.
    private let pollInterval: Duration

    public init(transport: any SCSITransport, log: CommandLog = CommandLog(), pollInterval: Duration = .seconds(1)) {
        self.transport = transport
        self.log = log
        self.pollInterval = pollInterval
    }

    // MARK: - Status

    public func identify() async throws -> InquiryData {
        let data = try await run(MMC.inquiry(), "INQUIRY")
        guard let inquiry = InquiryData(bytes: data) else {
            throw DriveError.commandFailed(operation: "INQUIRY", status: 0, sense: nil)
        }
        return inquiry
    }

    /// Reads the drive and disc state. Throws `.busy` while a burn or erase is running.
    public func state() async throws -> DriveState {
        guard !isBusy else { throw DriveError.busy }
        return try await readState()
    }

    private func readState() async throws -> DriveState {
        var ready = false
        for _ in 0..<3 {
            let response = try await perform(MMC.testUnitReady())
            if response.isGood {
                ready = true
                break
            }
            guard let sense = response.sense else { break }
            if sense.isNoMedium { return .noDisc }
            if sense.isTransientNotReady { return .becomingReady }
            if sense.isUnitAttention { continue }
            break
        }
        if !ready {
            // Some drives report odd sense data for blank discs. Carry on and let GET CONFIGURATION decide.
            log.note("TEST UNIT READY did not report ready; checking the configuration anyway")
        }

        let configurationBytes = try await run(MMC.getConfiguration(), "GET CONFIGURATION")
        guard let configuration = ConfigurationData(bytes: configurationBytes) else {
            throw DriveError.commandFailed(operation: "GET CONFIGURATION", status: 0, sense: nil)
        }
        let profile = configuration.currentProfile
        if profile == .none { return .noDisc }

        let infoBytes = try await run(MMC.readDiscInformation(), "READ DISC INFORMATION")
        guard let info = DiscInformation(bytes: infoBytes) else {
            throw DriveError.commandFailed(operation: "READ DISC INFORMATION", status: 0, sense: nil)
        }

        var freeBlocks: UInt32 = 0
        if info.status != .complete, info.lastTrackInLastSession > 0 {
            let trackBytes = try await run(MMC.readTrackInformation(track: UInt32(info.lastTrackInLastSession)),
                                           "READ TRACK INFORMATION")
            if let track = TrackInformation(bytes: trackBytes) {
                freeBlocks = track.freeBlocks
            }
        }

        let writability = Writability.classify(profile: profile, info: info)
        return .disc(DiscState(profile: profile, status: info.status, isErasable: info.isErasable,
                               freeBlocks: freeBlocks, writability: writability))
    }

    // MARK: - Writing

    /// Writes `image` to a blank disc, closes it, then reads it back and compares every block.
    public func write(_ image: any ImageSource, options: WriteOptions = WriteOptions(),
                      progress: @escaping @Sendable (WriteProgress) -> Void = { _ in }) async throws -> WriteReport {
        guard !isBusy else { throw DriveError.busy }
        isBusy = true
        defer { isBusy = false }
        let started = Date()

        progress(WriteProgress(phase: .preparing, completedBlocks: 0, totalBlocks: image.blockCount))
        guard case .disc(let disc) = try await readState() else { throw DriveError.noDisc }
        guard disc.writability == .blank else { throw DriveError.notWritable(disc.writability) }
        guard let method = disc.profile.writeMethod else { throw DriveError.unsupportedMedia(disc.profile) }
        if options.simulate && !disc.profile.supportsTestWrite {
            throw DriveError.simulationUnsupported(disc.profile)
        }

        let imageBlocks = image.blockCount
        let alignment = method.blockAlignment
        let paddedBlocks = (imageBlocks + alignment - 1) / alignment * alignment
        guard paddedBlocks <= Int(disc.freeBlocks) else {
            throw DriveError.doesNotFit(neededBlocks: paddedBlocks, freeBlocks: Int(disc.freeBlocks))
        }
        log.note("Writing \(imageBlocks) blocks (\(paddedBlocks) with padding) to \(disc.profile.name) using \(method)")

        try await beginExclusiveAccess()
        do {
            let report = try await writeLocked(image, disc: disc, method: method, paddedBlocks: paddedBlocks,
                                               options: options, started: started, progress: progress)
            await endExclusiveAccess()
            return report
        } catch {
            _ = try? await perform(MMC.preventAllowMediumRemoval(prevent: false))
            await endExclusiveAccess()
            throw error
        }
    }

    private func writeLocked(_ image: any ImageSource, disc: DiscState, method: WriteMethod, paddedBlocks: Int,
                             options: WriteOptions, started: Date,
                             progress: @escaping @Sendable (WriteProgress) -> Void) async throws -> WriteReport {
        let imageBlocks = image.blockCount
        _ = try? await perform(MMC.preventAllowMediumRemoval(prevent: true))

        switch method {
        case .cdTrackAtOnce:
            try await setWriteParameters(WriteParameters(writeType: .trackAtOnce, testWrite: options.simulate,
                                                         multiSession: 0, trackMode: 4, dataBlockType: 8))
        case .dvdMinusDiscAtOnce:
            try await setWriteParameters(WriteParameters(writeType: .sessionAtOnce, testWrite: options.simulate,
                                                         multiSession: 0, trackMode: 5, dataBlockType: 8))
            _ = try await run(MMC.reserveTrack(blocks: UInt32(paddedBlocks)), "RESERVE TRACK")
        case .dvdPlusR, .dvdPlusRDualLayer, .bluRayR:
            break
        }

        // Find where the track starts.
        let infoBytes = try await run(MMC.readDiscInformation(), "READ DISC INFORMATION")
        guard let info = DiscInformation(bytes: infoBytes), info.lastTrackInLastSession > 0 else {
            throw DriveError.commandFailed(operation: "READ DISC INFORMATION", status: 0, sense: nil)
        }
        let trackNumber = method == .dvdMinusDiscAtOnce ? info.firstTrackInLastSession : info.lastTrackInLastSession
        let trackBytes = try await run(MMC.readTrackInformation(track: UInt32(trackNumber)), "READ TRACK INFORMATION")
        guard let track = TrackInformation(bytes: trackBytes) else {
            throw DriveError.commandFailed(operation: "READ TRACK INFORMATION", status: 0, sense: nil)
        }
        let startBlock = track.nextWritableValid ? track.nextWritable : track.start
        log.note("Track \(track.track) starts at block \(startBlock)")

        // Write.
        var written = 0
        var cancelled = false
        var lastReport = Date.distantPast
        while written < paddedBlocks {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let count = min(Self.transferBlocks, paddedBlocks - written)
            var data: [UInt8]
            if written + count <= imageBlocks {
                data = try readImage(image, block: written, count: count)
            } else {
                let fromImage = max(0, imageBlocks - written)
                data = fromImage > 0 ? try readImage(image, block: written, count: fromImage) : []
                data += [UInt8](repeating: 0, count: (count - fromImage) * MMC.blockSize)
            }
            _ = try await run(MMC.write10(lba: startBlock + UInt32(written), data: data), "WRITE",
                              notReadyRetries: 3000)
            written += count
            if Date().timeIntervalSince(lastReport) > 0.2 || written == paddedBlocks {
                lastReport = Date()
                progress(WriteProgress(phase: .writing, completedBlocks: written, totalBlocks: paddedBlocks))
            }
        }

        // Flush and close. After a cancel, still flush so the drive stops cleanly.
        progress(WriteProgress(phase: .closing, completedBlocks: written, totalBlocks: paddedBlocks))
        let writtenBlocks = written
        let reportClosing: @Sendable (Double?) -> Void = { fraction in
            progress(WriteProgress(phase: .closing, completedBlocks: writtenBlocks, totalBlocks: paddedBlocks,
                                   driveProgress: fraction))
        }
        try await runLong(MMC.synchronizeCache(immediate: true), fallback: MMC.synchronizeCache(),
                          "SYNCHRONIZE CACHE", progress: reportClosing)
        if cancelled {
            log.note("Cancelled after \(written) blocks")
            throw DriveError.cancelled
        }
        if !options.simulate {
            try await close(method: method, track: track.track, progress: reportClosing)
        }
        _ = try? await perform(MMC.preventAllowMediumRemoval(prevent: false))

        // Verify.
        var verified = false
        if options.verify && !options.simulate {
            try await verify(image, startBlock: startBlock, progress: progress)
            verified = true
        }

        if options.ejectWhenDone {
            _ = try? await run(MMC.startStopUnit(load: false), "EJECT")
        }

        return WriteReport(profile: disc.profile, startBlock: startBlock, imageBlocks: imageBlocks,
                           writtenBlocks: written, verified: verified, simulated: options.simulate,
                           duration: Date().timeIntervalSince(started))
    }

    private func close(method: WriteMethod, track: Int, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let trackNumber = UInt16(clamping: track)
        var functions: [(MMC.CloseFunction, UInt16, String)] = []
        switch method {
        case .cdTrackAtOnce:
            functions = [(.track, trackNumber, "CLOSE TRACK"), (.session, 0, "CLOSE SESSION")]
        case .dvdMinusDiscAtOnce:
            // Disc at once closes itself during SYNCHRONIZE CACHE.
            break
        case .dvdPlusR:
            functions = [(.track, trackNumber, "CLOSE TRACK"), (.finaliseDVDPlusR, 0, "FINALISE")]
        case .dvdPlusRDualLayer, .bluRayR:
            functions = [(.track, trackNumber, "CLOSE TRACK"), (.finaliseDisc, 0, "FINALISE")]
        }
        for (function, number, name) in functions {
            try await runLong(MMC.closeTrackSession(function, track: number, immediate: true),
                              fallback: MMC.closeTrackSession(function, track: number), name, progress: progress)
        }
    }

    private func verify(_ image: any ImageSource, startBlock: UInt32,
                        progress: @escaping @Sendable (WriteProgress) -> Void) async throws {
        let total = image.blockCount
        var checked = 0
        var lastReport = Date.distantPast
        while checked < total {
            if Task.isCancelled { throw DriveError.cancelled }
            let count = min(Self.transferBlocks, total - checked)
            let fromDisc = try await run(MMC.read10(lba: startBlock + UInt32(checked), blocks: UInt16(count)),
                                         "READ", notReadyRetries: 3000)
            let fromImage = try readImage(image, block: checked, count: count)
            if fromDisc != fromImage {
                let firstBad = (0..<count).first { index in
                    let range = index * MMC.blockSize..<(index + 1) * MMC.blockSize
                    return fromDisc.count < range.upperBound || fromDisc[range] != fromImage[range]
                } ?? 0
                log.note("Verification mismatch at image block \(checked + firstBad)")
                throw DriveError.verificationFailed(block: checked + firstBad)
            }
            checked += count
            if Date().timeIntervalSince(lastReport) > 0.2 || checked == total {
                lastReport = Date()
                progress(WriteProgress(phase: .verifying, completedBlocks: checked, totalBlocks: total))
            }
        }
        log.note("Verified \(total) blocks")
    }

    private func setWriteParameters(_ parameters: WriteParameters) async throws {
        let senseBytes = try await run(MMC.modeSense(page: 0x05), "MODE SENSE (write parameters)")
        guard let page = ModePage.firstPage(inModeSense: senseBytes) else {
            throw DriveError.commandFailed(operation: "MODE SENSE (write parameters)", status: 0, sense: nil)
        }
        let updated = parameters.applied(to: page)
        _ = try await run(MMC.modeSelect(parameters: ModePage.selectParameters(page: updated)),
                          "MODE SELECT (write parameters)")
    }

    private func readImage(_ image: any ImageSource, block: Int, count: Int) throws -> [UInt8] {
        do {
            return try image.read(block: block, count: count)
        } catch {
            throw DriveError.image("Couldn't read the image: \(error)")
        }
    }

    // MARK: - Erase and eject

    /// Quick-erases a CD-RW or DVD-RW. `progress` receives the drive's progress when it reports it.
    public func quickErase(progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        guard !isBusy else { throw DriveError.busy }
        isBusy = true
        defer { isBusy = false }

        guard case .disc(let disc) = try await readState() else { throw DriveError.noDisc }
        guard disc.profile.supportsBlank else { throw DriveError.unsupportedMedia(disc.profile) }

        try await beginExclusiveAccess()
        do {
            try await runLong(MMC.blank(quick: true, immediate: true), fallback: MMC.blank(quick: true),
                              "BLANK", progress: progress)
            await endExclusiveAccess()
        } catch {
            await endExclusiveAccess()
            throw error
        }
    }

    /// Ejects the disc, or opens the tray when the drive is empty.
    public func eject() async throws {
        guard !isBusy else { throw DriveError.busy }
        do {
            _ = try await run(MMC.startStopUnit(load: false), "EJECT")
            return
        } catch let error as DriveError {
            // macOS refuses to eject a mounted disc through the shared interface. Taking
            // exclusive access unmounts it first.
            switch error {
            case .transport(.needsExclusiveAccess), .transport(.ioError):
                log.note("EJECT was refused without exclusive access, taking it")
            default:
                throw error
            }
        }
        try await beginExclusiveAccess()
        do {
            _ = try await run(MMC.startStopUnit(load: false), "EJECT")
            await endExclusiveAccess()
        } catch {
            await endExclusiveAccess()
            throw error
        }
    }

    /// Closes the tray.
    public func load() async throws {
        guard !isBusy else { throw DriveError.busy }
        _ = try await run(MMC.startStopUnit(load: true), "LOAD")
    }

    // MARK: - Plumbing

    /// Runs a long operation without holding one command open for its whole length: the command
    /// goes with the immediate bit set, then TEST UNIT READY is polled until the drive is ready.
    /// Drives that reject the immediate bit get `fallback` instead.
    private func runLong(_ command: SCSICommand, fallback: SCSICommand, _ operation: String,
                         progress: @escaping @Sendable (Double?) -> Void) async throws {
        do {
            _ = try await run(command, operation, notReadyRetries: 3000)
        } catch DriveError.commandFailed(_, _, let sense?) where sense.key == 0x05 && sense.asc == 0x24 {
            log.note("\(operation): the drive rejected the immediate bit, sending it without")
            _ = try await run(fallback, operation, notReadyRetries: 3000)
        }
        try await waitUntilReady(progress: progress)
    }

    private func waitUntilReady(timeout: TimeInterval = 3600,
                                progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await perform(MMC.testUnitReady())
            if response.isGood { return }
            if let sense = response.sense, sense.isTransientNotReady || sense.isUnitAttention {
                progress(sense.progress)
                try? await Task.sleep(for: pollInterval)
                continue
            }
            throw DriveError.commandFailed(operation: "TEST UNIT READY", status: response.status, sense: response.sense)
        }
        throw DriveError.commandFailed(operation: "Waiting for the drive", status: 0, sense: nil)
    }

    /// Sends a command and returns its data, retrying while the drive reports it is briefly busy.
    private func run(_ command: SCSICommand, _ operation: String, notReadyRetries: Int = 20) async throws -> [UInt8] {
        var attempts = 0
        var unitAttentions = 0
        while true {
            let response = try await perform(command)
            if response.isGood { return response.data }
            if let sense = response.sense {
                if sense.isTransientNotReady && attempts < notReadyRetries {
                    attempts += 1
                    try? await Task.sleep(for: .milliseconds(20))
                    continue
                }
                if sense.isUnitAttention && unitAttentions < 2 {
                    unitAttentions += 1
                    continue
                }
            }
            throw DriveError.commandFailed(operation: operation, status: response.status, sense: response.sense)
        }
    }

    private func perform(_ command: SCSICommand) async throws -> SCSIResponse {
        let transport = self.transport
        let log = self.log
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let start = Date()
                let dataLength: Int
                switch command.direction {
                case .none: dataLength = 0
                case .fromDevice(let length): dataLength = length
                case .toDevice(let bytes): dataLength = bytes.count
                }
                do {
                    let response = try transport.execute(command)
                    log.record(CommandLog.Entry(time: start, cdb: command.cdb, dataLength: dataLength,
                                                status: response.status, sense: response.sense, error: nil,
                                                duration: Date().timeIntervalSince(start)))
                    continuation.resume(returning: response)
                } catch let error as TransportError {
                    log.record(CommandLog.Entry(time: start, cdb: command.cdb, dataLength: dataLength,
                                                status: nil, sense: nil, error: error.description,
                                                duration: Date().timeIntervalSince(start)))
                    continuation.resume(throwing: DriveError.transport(error))
                } catch {
                    log.record(CommandLog.Entry(time: start, cdb: command.cdb, dataLength: dataLength,
                                                status: nil, sense: nil, error: "\(error)",
                                                duration: Date().timeIntervalSince(start)))
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func beginExclusiveAccess() async throws {
        let transport = self.transport
        let log = self.log
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try transport.beginExclusiveAccess()
                    log.note("Exclusive access taken")
                    continuation.resume()
                } catch let error as TransportError {
                    log.note("Exclusive access refused: \(error)")
                    continuation.resume(throwing: DriveError.transport(error))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func endExclusiveAccess() async {
        let transport = self.transport
        let log = self.log
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                transport.endExclusiveAccess()
                log.note("Exclusive access released")
                continuation.resume()
            }
        }
    }
}

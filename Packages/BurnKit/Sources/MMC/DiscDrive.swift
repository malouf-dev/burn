import Foundation

public struct WriteOptions: Sendable {
    /// Laser-off test write, on media that support it. Nothing is recorded, so nothing is verified.
    public var simulate: Bool
    /// Read the disc back and compare it with the image. Always on in the app.
    public var verify: Bool
    public var ejectWhenDone: Bool
    /// Erase a rewritable disc that has data on it, then burn. The drive is held throughout, so
    /// macOS never reads the disc in between.
    public var eraseFirst: Bool
    /// The speed to write at, set before anything is written. Nil leaves it to the drive.
    public var writeSpeed: WriteSpeed?
    /// How long to wait before each automatic try of a step that failed: five more tries over
    /// about a minute, before the burn holds and asks.
    public var retryWaits: [Duration]
    /// Asked once a step has failed every automatic try. The burn holds the drive and the disc
    /// until it answers. Without one, the burn stops, as burnctl's does.
    public var whenHeld: @Sendable (HeldBurn) async -> HeldBurnChoice
    /// Told what's being tried again while a step is retried, and nil once it works.
    public var onRetry: @Sendable (String?) -> Void

    public init(simulate: Bool = false, verify: Bool = true, ejectWhenDone: Bool = false, eraseFirst: Bool = false,
                writeSpeed: WriteSpeed? = nil,
                retryWaits: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(15), .seconds(30)],
                whenHeld: @escaping @Sendable (HeldBurn) async -> HeldBurnChoice = { _ in .abandon },
                onRetry: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.simulate = simulate
        self.verify = verify
        self.ejectWhenDone = ejectWhenDone
        self.eraseFirst = eraseFirst
        self.writeSpeed = writeSpeed
        self.retryWaits = retryWaits
        self.whenHeld = whenHeld
        self.onRetry = onRetry
    }
}

/// A step of a burn that failed every automatic try. The burn holds the drive and the disc while
/// the user decides whether to try again.
public struct HeldBurn: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case readingFiles, writing, closing, verifying
    }

    public var step: Step
    /// What went wrong, in plain words.
    public var problem: String
    /// What to check before trying again.
    public var advice: String
    /// Tries made so far, the first included.
    public var tries: Int

    public init(step: Step, problem: String, advice: String, tries: Int) {
        self.step = step
        self.problem = problem
        self.advice = advice
        self.tries = tries
    }
}

public enum HeldBurnChoice: Sendable {
    /// Go round the automatic tries again.
    case tryAgain
    /// End the burn. The disc is settled as after any failed burn.
    case abandon
}

public enum WritePhase: Sendable, Equatable {
    case preparing
    /// Erasing a rewritable disc before burning, with `WriteOptions.eraseFirst`.
    case erasing
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
        case .closing, .erasing: return driveProgress ?? 0
        case .writing, .verifying: return totalBlocks == 0 ? 0 : Double(completedBlocks) / Double(totalBlocks)
        }
    }

    /// True when there is no meaningful fraction to show.
    public var isIndeterminate: Bool {
        phase == .preparing || ((phase == .closing || phase == .erasing) && driveProgress == nil)
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
    /// How many times verify reads blocks that don't match before calling the burn failed.
    static let verifyReads = 3

    /// How long to wait between polls while the drive finishes a long operation.
    private let pollInterval: Duration

    /// True between `holdDrive()` and `releaseDrive()`, and after a burn fails once it has
    /// changed the disc.
    private var holdingDrive = false

    /// Set once the current burn has changed the disc.
    private var discTouched = false

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

    // MARK: - Holding the drive

    /// Takes the drive and keeps it until `releaseDrive()`. Burns, erases and ejects in between
    /// use it as it is. Taken while the drive is empty, it stops macOS from reading the next disc
    /// put in, which is the way to reach a disc that macOS gets stuck reading.
    public func holdDrive() async throws {
        guard !holdingDrive else { return }
        try await beginExclusiveAccess()
        holdingDrive = true
    }

    /// Gives the drive back to macOS after `holdDrive()`.
    public func releaseDrive() async {
        guard holdingDrive else { return }
        holdingDrive = false
        await endExclusiveAccess()
    }

    public var isHoldingDrive: Bool { holdingDrive }

    /// Waits for a disc to be put in and for the drive to finish reading it.
    public func waitForDisc(timeout: TimeInterval = 300) async throws -> DriveState {
        guard !isBusy else { throw DriveError.busy }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await perform(MMC.testUnitReady())
            if response.isGood { break }
            if let sense = response.sense, sense.isNoMedium || sense.isTransientNotReady || sense.isUnitAttention {
                try? await Task.sleep(for: pollInterval)
                continue
            }
            break
        }
        let state = try await readState()
        if state == .noDisc { throw DriveError.noDisc }
        return state
    }

    /// Reads the drive and disc state. Throws `.busy` while a burn or erase is running.
    public func state() async throws -> DriveState {
        guard !isBusy else { throw DriveError.busy }
        return try await readState()
    }

    /// The speeds the drive can write the disc in it at, slowest first, or none when the drive
    /// doesn't say. Needs no exclusive access, so it can be asked while macOS has the drive.
    public func writeSpeeds() async throws -> [WriteSpeed] {
        guard !isBusy else { throw DriveError.busy }
        return WriteSpeed.list(from: try await run(MMC.getWriteSpeeds(), "GET PERFORMANCE (write speeds)"))
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
        var usedBlocks: UInt32 = 0
        if info.status != .blank, info.lastTrackInLastSession > 0 {
            // What's recorded in each track, and the space left in the last one.
            for number in 1...min(info.lastTrackInLastSession, 99) {
                let trackBytes = try await run(MMC.readTrackInformation(track: UInt32(number)), "READ TRACK INFORMATION")
                guard let track = TrackInformation(bytes: trackBytes) else { continue }
                usedBlocks += track.nextWritableValid ? track.nextWritable - min(track.nextWritable, track.start)
                                                      : track.size
                if number == info.lastTrackInLastSession && info.status != .complete {
                    freeBlocks = track.freeBlocks
                }
            }
        } else if info.lastTrackInLastSession > 0 {
            let trackBytes = try await run(MMC.readTrackInformation(track: UInt32(info.lastTrackInLastSession)),
                                           "READ TRACK INFORMATION")
            if let track = TrackInformation(bytes: trackBytes) {
                freeBlocks = track.freeBlocks
            }
        }

        let writability = Writability.classify(profile: profile, info: info)
        if info.lastSessionState == .incomplete || info.lastSessionState == .damaged {
            log.note("The last session is \(info.lastSessionState): a burn didn't finish")
        }
        return .disc(DiscState(profile: profile, status: info.status, lastSessionState: info.lastSessionState,
                               isErasable: info.isErasable, freeBlocks: freeBlocks, usedBlocks: usedBlocks,
                               writability: writability))
    }

    // MARK: - Writing

    /// Writes `image` to a blank disc, closes it, then reads it back and compares every block.
    public func write(_ image: any ImageSource, options: WriteOptions = WriteOptions(),
                      progress: @escaping @Sendable (WriteProgress) -> Void = { _ in }) async throws -> WriteReport {
        guard !isBusy else { throw DriveError.busy }
        isBusy = true
        defer { isBusy = false }
        let started = Date()
        discTouched = false

        progress(WriteProgress(phase: .preparing, completedBlocks: 0, totalBlocks: image.blockCount))
        guard case .disc(var disc) = try await readState() else { throw DriveError.noDisc }

        // Erase first if asked. The drive stays held from here to the end of the burn.
        var heldForErase = false
        if disc.writability == .needsErase && options.eraseFirst && disc.profile.supportsBlank {
            heldForErase = !holdingDrive
            try await holdDrive()
            do {
                let total = image.blockCount
                progress(WriteProgress(phase: .erasing, completedBlocks: 0, totalBlocks: total))
                try await blankLocked(.quickThenFull) { erase in
                    progress(WriteProgress(phase: .erasing, completedBlocks: 0, totalBlocks: total,
                                           driveProgress: erase.fraction))
                }
                guard case .disc(let erased) = try await readState() else { throw DriveError.noDisc }
                disc = erased
            } catch {
                if heldForErase { await releaseDrive() }
                throw error
            }
        }
        do {
            let report = try await writeDisc(image, disc: disc, options: options, started: started, progress: progress)
            if heldForErase { await releaseDrive() }
            return report
        } catch {
            // A burn that changed the disc keeps the drive for settleAfterFailedBurn.
            if heldForErase && !discTouched { await releaseDrive() }
            throw error
        }
    }

    private func writeDisc(_ image: any ImageSource, disc: DiscState, options: WriteOptions, started: Date,
                           progress: @escaping @Sendable (WriteProgress) -> Void) async throws -> WriteReport {
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
            if discTouched {
                // The disc may not read back, and macOS can get stuck reading a disc like that
                // (hardware run 9). Keep the drive until settleAfterFailedBurn.
                log.note("Keeping the drive: the burn failed after it changed the disc")
                holdingDrive = true
            } else {
                await endExclusiveAccess()
            }
            throw error
        }
    }

    private func writeLocked(_ image: any ImageSource, disc: DiscState, method: WriteMethod, paddedBlocks: Int,
                             options: WriteOptions, started: Date,
                             progress: @escaping @Sendable (WriteProgress) -> Void) async throws -> WriteReport {
        let imageBlocks = image.blockCount
        _ = try? await perform(MMC.preventAllowMediumRemoval(prevent: true))
        if let speed = options.writeSpeed {
            let endBlock = UInt32(max(Int(disc.freeBlocks), paddedBlocks) - 1)
            try await setWriteSpeed(speed, profile: disc.profile, endBlock: endBlock)
        }

        switch method {
        case .cdTrackAtOnce:
            try await setWriteParameters(WriteParameters(writeType: .trackAtOnce, testWrite: options.simulate,
                                                         multiSession: 0, trackMode: 4, dataBlockType: 8))
        case .dvdMinusDiscAtOnce:
            try await setWriteParameters(WriteParameters(writeType: .sessionAtOnce, testWrite: options.simulate,
                                                         multiSession: 0, trackMode: 5, dataBlockType: 8))
            if !options.simulate { discTouched = true }
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
                data = try await readImage(image, block: written, count: count, step: .writing, options: options)
            } else {
                let fromImage = max(0, imageBlocks - written)
                data = fromImage > 0
                    ? try await readImage(image, block: written, count: fromImage, step: .writing, options: options) : []
                data += [UInt8](repeating: 0, count: (count - fromImage) * MMC.blockSize)
            }
            if !options.simulate { discTouched = true }
            try await writeBlocks(data, at: startBlock + UInt32(written), track: trackNumber, options: options)
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
        try await runLong(MMC.synchronizeCache(immediate: true), "SYNCHRONIZE CACHE", progress: reportClosing)
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
            // SET STREAMING held reading to the write speed too. Verify reads at the drive's own.
            if options.writeSpeed != nil && disc.profile.mediaClass != .cd {
                do {
                    _ = try await run(MMC.restoreDefaultSpeeds(), "SET STREAMING (drive's own speeds)")
                } catch {
                    log.note("Verifying at the write speed: the drive didn't go back to its own speeds. \(error)")
                }
            }
            try await verify(image, startBlock: startBlock, options: options, progress: progress)
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
            try await runLong(MMC.closeTrackSession(function, track: number, immediate: true), name, progress: progress)
        }
    }

    private func verify(_ image: any ImageSource, startBlock: UInt32, options: WriteOptions,
                        progress: @escaping @Sendable (WriteProgress) -> Void) async throws {
        let total = image.blockCount
        var checked = 0
        var lastReport = Date.distantPast
        while checked < total {
            if Task.isCancelled { throw DriveError.cancelled }
            let count = min(Self.transferBlocks, total - checked)
            let read = MMC.read10(lba: startBlock + UInt32(checked), blocks: UInt16(count))
            var fromDisc = try await run(read, "READ", notReadyRetries: 3000)
            let fromImage = try await readImage(image, block: checked, count: count, step: .verifying,
                                                options: options)
            // The drive can hand back data from the wrong place with no error, while the disc holds
            // the right data (hardware runs 18 and 20). A bad disc reads the same way every time,
            // so a mismatch fails only when it survives reading again.
            var attempt = 1
            while fromDisc != fromImage {
                let firstBad = (0..<count).first { index in
                    let range = index * MMC.blockSize..<(index + 1) * MMC.blockSize
                    return fromDisc.count < range.upperBound || fromDisc[range] != fromImage[range]
                } ?? 0
                log.note("Verification mismatch at image block \(checked + firstBad), "
                    + "read \(attempt) of \(Self.verifyReads)")
                log.note(Self.mismatchDetail(disc: fromDisc, image: fromImage, blockInRead: firstBad,
                                             part: image.describe(block: checked + firstBad)))
                guard attempt < Self.verifyReads else {
                    throw DriveError.verificationFailed(block: checked + firstBad)
                }
                attempt += 1
                fromDisc = try await run(read, "READ", notReadyRetries: 3000)
                if fromDisc == fromImage {
                    log.note("Blocks \(checked) to \(checked + count - 1) read back correctly on read \(attempt)")
                }
            }
            checked += count
            if Date().timeIntervalSince(lastReport) > 0.2 || checked == total {
                lastReport = Date()
                progress(WriteProgress(phase: .verifying, completedBlocks: checked, totalBlocks: total))
            }
        }
        log.note("Verified \(total) blocks")
    }

    /// Sets the write speed before anything is written. A drive that won't take it stops the
    /// burn while the disc is still as it was, rather than writing at a speed nobody chose.
    private func setWriteSpeed(_ speed: WriteSpeed, profile: MediaProfile, endBlock: UInt32) async throws {
        let label = speed.label(for: profile.mediaClass)
        let command = profile.mediaClass == .cd
            ? MMC.setCDSpeed(writeKilobytesPerSecond: UInt16(clamping: speed.kilobytesPerSecond))
            : MMC.setStreaming(writeKilobytesPerSecond: speed.kilobytesPerSecond, endBlock: endBlock)
        do {
            _ = try await run(command, profile.mediaClass == .cd ? "SET CD SPEED" : "SET STREAMING")
        } catch {
            throw DriveError.speedNotAccepted(label: label, reason: "\(error)")
        }
        log.note("Write speed set to \(label), \(speed.kilobytesPerSecond) kB/s")
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

    /// How one mismatched block differs, so a failed verify can be traced to the disc or the image.
    static func mismatchDetail(disc: [UInt8], image: [UInt8], blockInRead: Int, part: String?) -> String {
        let start = blockInRead * MMC.blockSize
        let end = start + MMC.blockSize
        guard disc.count >= end, image.count >= end else {
            return "The drive returned \(disc.count) bytes where \(image.count) were expected"
        }
        let differing = (start..<end).filter { disc[$0] != image[$0] }
        let first = differing.first ?? start
        func sample(_ bytes: [UInt8]) -> String {
            bytes[first..<min(first + 16, end)].map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        var text = "\(differing.count) of \(MMC.blockSize) bytes differ, the first at byte \(first - start)."
        text += " Disc: \(sample(disc)). Image: \(sample(image))."
        if disc[start..<end].allSatisfy({ $0 == 0 }) { text += " The disc block is all zeros." }
        if image[start..<end].allSatisfy({ $0 == 0 }) { text += " The image block is all zeros." }
        // Data from the wrong place shows up elsewhere in what the image holds for this read.
        // A probe of one repeated byte, such as zeros, would match too easily to mean anything.
        let probe = disc[first..<min(first + 16, end)]
        if probe.count == 16, Set(probe).count > 1,
           let found = (0...(image.count - 16)).first(where: { image[$0..<($0 + 16)].elementsEqual(probe) }),
           found != first {
            text += " The disc's bytes match the image \(found - first) bytes further on, so they came from the wrong place."
        }
        if let part { text += " The block holds \(part)." }
        return text
    }

    /// Reads blocks of the image, patiently: a file on a drive that drops out for a moment is
    /// read again once it's back (hardware run 26).
    private func readImage(_ image: any ImageSource, block: Int, count: Int, step: HeldBurn.Step,
                           options: WriteOptions) async throws -> [UInt8] {
        try await patiently(step, options: options, explain: { error in
            let place = image.describe(block: block) ?? "block \(block) of the image"
            return (problem: "Burn couldn't read \(place): \(Self.plain(error)).",
                    advice: "Check that the drive the files are on is connected and mounted, then try again. "
                        + "The disc waits where it stopped.")
        }) {
            try image.read(block: block, count: count)
        }
    }

    /// Writes blocks patiently. After a failed WRITE, the drive is asked which block it expects
    /// next. If it's still the first of these, nothing was recorded, so the WRITE is sent again.
    /// If it's the block after them, the WRITE was recorded after all. Anything else means part
    /// of them was recorded and can't be written again, so the disc can't pass verify and the
    /// burn stops at once (hardware run 28).
    private func writeBlocks(_ data: [UInt8], at lba: UInt32, track: Int, options: WriteOptions) async throws {
        let count = UInt32(data.count / MMC.blockSize)
        try await patiently(.writing, options: options, explain: { error in
            let place = "block \(lba.grouped), \(Self.gigabytes(lba)) into the disc"
            if case DriveError.transport(let transport) = error {
                return (problem: "The drive stopped answering while writing \(place): \(transport).",
                        advice: "Check the drive's USB cable and power, then try again. The disc waits where it stopped.")
            }
            return (problem: "The drive couldn't write \(place): \(Self.reason(error)).",
                    advice: "Check the drive's cable and power. If it has been writing for hours, let it cool for a while, "
                        + "then try again. The disc waits where it stopped.")
        }, canRetry: { error in
            if case DriveError.partlyWritten = error { return false }
            return true
        }) {
            do {
                _ = try await run(MMC.write10(lba: lba, data: data), "WRITE", notReadyRetries: 3000)
            } catch {
                let next = await nextWritable(track: track)
                if next == lba + count {
                    log.note("The drive had recorded blocks \(lba) to \(lba + count - 1) before the error")
                } else if let next, next != lba {
                    throw DriveError.partlyWritten(block: Int(lba), nextBlock: Int(next), reason: Self.reason(error))
                } else {
                    throw error
                }
            }
        }
    }

    /// The block the drive expects to write next in a track, or nil when it can't say.
    private func nextWritable(track: Int) async -> UInt32? {
        guard let bytes = try? await run(MMC.readTrackInformation(track: UInt32(track)), "READ TRACK INFORMATION",
                                         notReadyRetries: 3000),
              let info = TrackInformation(bytes: bytes), info.nextWritableValid else { return nil }
        return info.nextWritable
    }

    /// How far into the disc a block is, such as "4.1 GB".
    static func gigabytes(_ block: UInt32) -> String {
        String(format: "%.1f GB", Double(block) * Double(MMC.blockSize) / 1e9)
    }

    /// Why a command failed, in a few plain words that fit after a colon.
    static func reason(_ error: any Error) -> String {
        var text: String
        switch error {
        case DriveError.commandFailed(_, _, let sense?): text = sense.explanation
        case DriveError.transport(let transport): text = transport.description
        default: text = plain(error)
        }
        if text.hasSuffix(".") { text.removeLast() }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    // MARK: - Patience

    /// Runs one step of a burn, trying it again after each wait in `options.retryWaits`. If every
    /// try fails, the burn holds the drive and the disc and asks `options.whenHeld` whether to go
    /// round again. `explain` turns the last error into what went wrong and what to check.
    /// A cancel ends the waiting at once.
    private func patiently<T>(_ step: HeldBurn.Step, options: WriteOptions,
                              explain: (any Error) -> (problem: String, advice: String),
                              canRetry: (any Error) -> Bool = { _ in true },
                              _ body: () async throws -> T) async throws -> T {
        var tries = 0
        while true {
            var lastError: (any Error)?
            let waits = [Duration.zero] + options.retryWaits
            for (index, wait) in waits.enumerated() {
                if let lastError {
                    let problem = explain(lastError).problem
                    log.note("\(problem) Trying again in \(wait.components.seconds) s, try \(index + 1) of \(waits.count)")
                    options.onRetry("\(problem) Trying again, \(index + 1) of \(waits.count)…")
                    do {
                        try await Task.sleep(for: wait)
                    } catch {
                        throw DriveError.cancelled
                    }
                }
                do {
                    let result = try await body()
                    if lastError != nil {
                        log.note("Worked on try \(index + 1)")
                        options.onRetry(nil)
                    }
                    return result
                } catch DriveError.cancelled {
                    throw DriveError.cancelled
                } catch {
                    guard canRetry(error) else { throw error }
                    tries += 1
                    lastError = error
                }
            }
            let (problem, advice) = explain(lastError ?? DriveError.cancelled)
            log.note("Holding the burn after \(tries) tries. \(problem)")
            options.onRetry(nil)
            switch await options.whenHeld(HeldBurn(step: step, problem: problem, advice: advice, tries: tries)) {
            case .tryAgain:
                log.note("Trying again, as asked")
            case .abandon:
                log.note("Stopped, as asked")
                throw DriveError.abandoned(problem: problem, tries: tries)
            }
        }
    }

    /// An error in a few plain words, such as "input/output error" for EIO.
    static func plain(_ error: any Error) -> String {
        if let posix = error as? POSIXError {
            return String(cString: strerror(posix.code.rawValue)).lowercased()
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(nsError.code))).lowercased()
        }
        return "\(error)"
    }

    // MARK: - After a failed burn

    public enum Recovery: Sendable, Equatable {
        /// The disc was still blank or had been taken out, so it was left as it was.
        case nothingNeeded
        /// The rewritable disc was erased and is blank.
        case erased
        /// The disc was ejected. It may not read back.
        case ejected
        /// A write-once disc that closed before verify failed. It's finished like any other, so it
        /// was left in the drive for macOS to mount and its files to be checked (hardware run 21).
        case leftClosed
    }

    /// A burn that fails after changing the disc keeps the drive, so macOS never reads a disc
    /// it may get stuck on. This puts the disc in a safe state and gives the drive back:
    /// a rewritable disc is erased when `erase` is true, anything else is ejected.
    public func settleAfterFailedBurn(erase: Bool,
                                      progress: @escaping @Sendable (EraseProgress) -> Void = { _ in })
        async throws -> Recovery {
        guard holdingDrive else { return .nothingNeeded }
        guard !isBusy else { throw DriveError.busy }
        isBusy = true
        defer { isBusy = false }
        do {
            guard case .disc(let disc) = try await readState(), disc.writability != .blank else {
                await releaseDrive()
                return .nothingNeeded
            }
            if disc.writability == .notWritable {
                await releaseDrive()
                return .leftClosed
            }
            if erase && disc.profile.supportsBlank {
                try await blankLocked(.quickThenFull, progress: progress)
                await releaseDrive()
                return .erased
            }
            try await ejectLocked()
            await releaseDrive()
            return .ejected
        } catch {
            // Get the disc out before macOS can read it. Once it's out, that's what happened to
            // it, whatever stopped the disc being read first (hardware run 28).
            do {
                try await ejectLocked()
            } catch {
                await releaseDrive()
                throw error
            }
            log.note("Ejected the disc, since its state couldn't be read: \(error)")
            await releaseDrive()
            return .ejected
        }
    }

    // MARK: - Inspecting

    /// Everything the drive reports about the disc, and whether a few key blocks read back:
    /// the first block, the volume descriptor at block 16 and the last block. For discs that
    /// won't mount.
    public func inspect() async throws -> DiscReport {
        guard !isBusy else { throw DriveError.busy }
        isBusy = true
        defer { isBusy = false }

        guard case .disc(let disc) = try await readState() else { throw DriveError.noDisc }
        let infoBytes = try await run(MMC.readDiscInformation(), "READ DISC INFORMATION")
        guard let info = DiscInformation(bytes: infoBytes) else {
            throw DriveError.commandFailed(operation: "READ DISC INFORMATION", status: 0, sense: nil)
        }
        var tracks: [TrackInformation] = []
        if info.lastTrackInLastSession > 0 {
            for number in 1...min(info.lastTrackInLastSession, 99) {
                let bytes = try await run(MMC.readTrackInformation(track: UInt32(number)), "READ TRACK INFORMATION")
                if let track = TrackInformation(bytes: bytes) { tracks.append(track) }
            }
        }

        try await beginExclusiveAccess()
        var capacity: CapacityData?
        var reads: [DiscReport.BlockRead] = []
        do {
            let capacityBytes = try await run(MMC.readCapacity(), "READ CAPACITY")
            capacity = CapacityData(bytes: capacityBytes)
            var blocks: [UInt32] = [0, 16]
            if let last = capacity?.lastBlock, last > 16 { blocks.append(last) }
            for block in blocks {
                var command = MMC.read10(lba: block, blocks: 1)
                command.timeout = 30
                let started = Date()
                var failure: String?
                do {
                    _ = try await run(command, "READ", notReadyRetries: 0)
                } catch {
                    failure = "\(error)"
                }
                reads.append(DiscReport.BlockRead(block: block, error: failure,
                                                  duration: Date().timeIntervalSince(started)))
            }
            await endExclusiveAccess()
        } catch {
            await endExclusiveAccess()
            throw error
        }
        return DiscReport(disc: disc, information: info, tracks: tracks, capacity: capacity, reads: reads)
    }

    // MARK: - Erase and eject

    /// Quick-erases a CD-RW or DVD-RW. `progress` receives the drive's progress when it reports it.
    public func quickErase(progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        try await erase(.quick) { progress($0.fraction) }
    }

    public enum EraseMode: Sendable {
        /// Clears the disc's lead-in only. Takes a minute or so.
        case quick
        /// Rewrites the whole disc. Can take an hour.
        case full
        /// A quick erase, then a full one if the drive reports the quick one failed.
        case quickThenFull
    }

    public struct EraseProgress: Sendable, Equatable {
        /// True during a full erase.
        public var full: Bool
        /// The drive's progress, when it reports it.
        public var fraction: Double?
    }

    /// Erases a CD-RW or DVD-RW. `progress` is called with no fraction when a full erase starts,
    /// then with the drive's progress when it reports it.
    ///
    /// Hardware run 11: the drive reported a quick erase of the DVD-RW left by run 7 as failed,
    /// so `.quickThenFull` goes on to a full erase.
    public func erase(_ mode: EraseMode = .quickThenFull,
                      progress: @escaping @Sendable (EraseProgress) -> Void = { _ in }) async throws {
        guard !isBusy else { throw DriveError.busy }
        isBusy = true
        defer { isBusy = false }

        guard case .disc(let disc) = try await readState() else { throw DriveError.noDisc }
        guard disc.profile.supportsBlank else { throw DriveError.unsupportedMedia(disc.profile) }

        try await beginExclusiveAccess()
        do {
            try await blankLocked(mode, progress: progress)
            await endExclusiveAccess()
        } catch {
            await endExclusiveAccess()
            throw error
        }
    }

    private func blankLocked(_ mode: EraseMode, progress: @escaping @Sendable (EraseProgress) -> Void) async throws {
        if mode == .full {
            try await blank(full: true, progress: progress)
            return
        }
        do {
            try await blank(full: false, progress: progress)
        } catch DriveError.commandFailed(_, _, let sense?) where sense.isEraseFailure && mode == .quickThenFull {
            log.note("The quick erase failed, erasing the whole disc")
            try await blank(full: true, progress: progress)
        }
    }

    private func blank(full: Bool, progress: @escaping @Sendable (EraseProgress) -> Void) async throws {
        if full { progress(EraseProgress(full: true, fraction: nil)) }
        try await runLong(MMC.blank(quick: !full, immediate: true), full ? "BLANK (full)" : "BLANK", timeout: full ? 4 * 3600 : 3600) { fraction in
            progress(EraseProgress(full: full, fraction: fraction))
        }
    }

    /// Formats a DVD-RW with a full format (type 10h), or a quick one (type 15h), using the
    /// size and parameter the drive lists for it, and returns the disc's profile afterwards. The disc ends up in restricted
    /// overwrite mode, and `erase` switches it back to sequential recording.
    ///
    /// Hardware runs 12 to 14: a DVD-RW left by run 7 failed every erase, from burnctl and
    /// drutil alike. Formatting takes a different route through the drive.
    ///
    /// Hardware run 15: the full format failed with 03/31/01 at 13.8%, which may be where run 7's
    /// cut-off write stopped. A quick format writes far less of the disc.
    public func formatDVDRW(quick: Bool = false,
                            progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> MediaProfile {
        guard !isBusy else { throw DriveError.busy }
        isBusy = true
        defer { isBusy = false }

        guard case .disc(let disc) = try await readState() else { throw DriveError.noDisc }
        guard disc.profile == .dvdRWSequential || disc.profile == .dvdRWRestrictedOverwrite else {
            throw DriveError.unsupportedMedia(disc.profile)
        }

        try await beginExclusiveAccess()
        do {
            let bytes = try await run(MMC.readFormatCapacities(), "READ FORMAT CAPACITIES")
            guard let capacities = FormatCapacities(bytes: bytes) else {
                throw DriveError.commandFailed(operation: "READ FORMAT CAPACITIES", status: 0, sense: nil)
            }
            log.note("Formats offered: " + capacities.formats.map {
                "\(hex($0.formatType)) (\($0.blocks) blocks, parameter \($0.parameter))"
            }.joined(separator: ", "))
            let wanted: UInt8 = quick ? 0x15 : 0x10
            guard let descriptor = capacities.formats.first(where: { $0.formatType == wanted }) else {
                throw DriveError.formatNotOffered(wanted: wanted, offered: capacities.formats.map(\.formatType))
            }
            try await runLong(MMC.formatUnit(descriptor, immediate: true), "FORMAT UNIT", timeout: 4 * 3600, progress: progress)
            await endExclusiveAccess()
        } catch {
            await endExclusiveAccess()
            throw error
        }
        guard case .disc(let after) = try await readState() else { throw DriveError.noDisc }
        return after.profile
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
            try await ejectLocked()
            await endExclusiveAccess()
        } catch {
            await endExclusiveAccess()
            throw error
        }
    }

    /// Unlocks the tray, then ejects. macOS locks the tray while a disc is mounted, and the lock
    /// outlasts the unmount, so without this the drive answers 05/53/02, medium removal
    /// prevented (from the first eject in the app).
    private func ejectLocked() async throws {
        _ = try? await perform(MMC.preventAllowMediumRemoval(prevent: false))
        _ = try await run(MMC.startStopUnit(load: false), "EJECT")
    }

    /// Closes the tray.
    public func load() async throws {
        guard !isBusy else { throw DriveError.busy }
        _ = try await run(MMC.startStopUnit(load: true), "LOAD")
    }

    // MARK: - Plumbing

    /// Runs a long operation without holding one command open for its whole length: the command
    /// goes with the immediate bit set, then TEST UNIT READY is polled until the drive is ready.
    ///
    /// A drive that rejects the immediate bit gets no plain retry. Over USB a plain command this
    /// long times out part-way, and the reset that follows can cut the drive off mid-write, which
    /// left run 7's DVD-RW unusable. Failing cleanly is safer.
    private func runLong(_ command: SCSICommand, _ operation: String, timeout: TimeInterval = 3600,
                         progress: @escaping @Sendable (Double?) -> Void) async throws {
        do {
            _ = try await run(command, operation, notReadyRetries: 3000)
        } catch DriveError.commandFailed(_, _, let sense?)
                    where sense.key == 0x05 && (sense.asc == 0x24 || sense.asc == 0x26) {
            log.note("\(operation): the drive rejected the immediate bit. Not retrying without it, "
                     + "since a long command could time out part-way.")
            throw DriveError.commandFailed(operation: operation, status: SCSIStatus.checkCondition.rawValue,
                                           sense: sense)
        }
        try await waitUntilReady(timeout: timeout, progress: progress)
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

    /// IOKit's kIOReturnBusy.
    static let ioReturnBusy = Int32(bitPattern: 0xE000_02D5)
    /// How many times to retry exclusive access while the drive is busy, one poll interval apart.
    static let exclusiveAccessRetries = 30

    /// Takes exclusive access, retrying while macOS is still busy with the disc, as it is for a
    /// moment after an unmount or while it reads a newly inserted disc.
    private func beginExclusiveAccess() async throws {
        guard !holdingDrive else { return }
        var attempts = 0
        while true {
            do {
                try await takeExclusiveAccess()
                return
            } catch DriveError.transport(.exclusiveAccessDenied(let code))
                        where code == Self.ioReturnBusy && attempts < Self.exclusiveAccessRetries {
                attempts += 1
                if attempts == 1 { log.note("The drive is busy, retrying exclusive access") }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func takeExclusiveAccess() async throws {
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
        guard !holdingDrive else { return }
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

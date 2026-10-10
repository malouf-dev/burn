import Testing
import Foundation
@testable import MMC
import MMCSimulator

/// An image whose every byte depends on its position, so misplaced blocks are caught.
func patternImage(blocks: Int) -> MemoryImageSource {
    var bytes = [UInt8](repeating: 0, count: blocks * MMC.blockSize)
    for index in bytes.indices {
        bytes[index] = UInt8(truncatingIfNeeded: index / MMC.blockSize &* 31 &+ index)
    }
    return MemoryImageSource(bytes: bytes)
}

func discState(_ drive: DiscDrive) async throws -> DiscState? {
    if case .disc(let disc) = try await drive.state() { return disc }
    return nil
}

@Suite("Drive state")
struct StateTests {
    @Test func noDisc() async throws {
        let drive = DiscDrive(transport: SimulatedDrive())
        #expect(try await drive.state() == .noDisc)
    }

    @Test func blankDVDPlusR() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 2_295_104))
        let drive = DiscDrive(transport: simulator)
        let disc = try await discState(drive)
        #expect(disc?.profile == .dvdPlusR)
        #expect(disc?.writability == .blank)
        #expect(disc?.freeBlocks == 2_295_104)
        #expect(disc?.freeBytes == 4_700_372_992)
    }

    @Test func newlyInsertedDiscIsReadAfterUnitAttention() async throws {
        let simulator = SimulatedDrive()
        simulator.insert(.init(profile: .cdR, capacityBlocks: 359_847))
        let drive = DiscDrive(transport: simulator)
        #expect(try await discState(drive)?.writability == .blank)
    }

    @Test func rewritableWithDataNeedsErase() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .cdRW, capacityBlocks: 300_000, blockCount: 500))
        let drive = DiscDrive(transport: simulator)
        #expect(try await discState(drive)?.writability == .needsErase)
    }

    @Test func closedWriteOnceDiscIsNotWritable() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdPlusR, capacityBlocks: 2_295_104, blockCount: 500))
        let drive = DiscDrive(transport: simulator)
        #expect(try await discState(drive)?.writability == .notWritable)
    }

    // Hardware run 7: the connection timed out while a DVD-RW was closing.
    @Test func closeCutOffByTheConnectionShowsAsUnfinished() async throws {
        var media = SimulatedDrive.Media.written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176)
        media.closed = false
        let simulator = SimulatedDrive(media: media)
        try simulator.beginExclusiveAccess()
        #expect(throws: TransportError.self) { try simulator.execute(MMC.synchronizeCache()) }
        simulator.endExclusiveAccess()

        let disc = try #require(try await discState(DiscDrive(transport: simulator)))
        #expect(disc.lastSessionState == .incomplete)
        #expect(disc.isUnfinished)
        #expect(disc.writability == .needsErase)
    }

    @Test func blankDVDPlusRWIsNotYetSupported() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusRW, capacityBlocks: 2_295_104))
        let drive = DiscDrive(transport: simulator)
        #expect(try await discState(drive)?.writability == .unsupported)
    }

    @Test func identify() async throws {
        let drive = DiscDrive(transport: SimulatedDrive())
        let inquiry = try await drive.identify()
        #expect(inquiry.vendor == "SIMULATE")
        #expect(inquiry.deviceType == 5)
    }
}

@Suite("Writing and verifying")
struct WriteTests {
    @Test(arguments: [MediaProfile.cdR, .cdRW, .dvdRSequential, .dvdRWSequential, .dvdRDualLayerSequential, .dvdPlusR,
                      .dvdPlusRDualLayer, .bdRSequential])
    func writeAndVerify(profile: MediaProfile) async throws {
        let simulator = SimulatedDrive(media: .init(profile: profile, capacityBlocks: 20_000))
        let drive = DiscDrive(transport: simulator)
        let image = patternImage(blocks: 1_001)

        let report = try await drive.write(image)

        #expect(report.verified)
        #expect(report.imageBlocks == 1_001)
        #expect(report.writtenBlocks % (profile.writeMethod?.blockAlignment ?? 1) == 0)
        #expect(simulator.recordedBytes(from: 0, count: 1_001) == image.bytes)
        #expect(simulator.currentMedia?.closed == true)
        #expect(!simulator.hasExclusiveAccess)
        let expected: Writability = profile.isRewritable ? .needsErase : .notWritable
        #expect(try await discState(drive)?.writability == expected)
    }

    @Test func cdSetsTrackAtOnceBeforeWriting() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .cdR, capacityBlocks: 20_000))
        _ = try await DiscDrive(transport: simulator).write(patternImage(blocks: 10))
        let codes = simulator.operationCodes
        let select = try #require(codes.firstIndex(of: 0x55))
        let firstWrite = try #require(codes.firstIndex(of: 0x2A))
        #expect(select < firstWrite)
        #expect(codes.contains(0x5B))
    }

    @Test func dvdMinusRReservesTrack() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdRSequential, capacityBlocks: 20_000))
        _ = try await DiscDrive(transport: simulator).write(patternImage(blocks: 10))
        let reserve = try #require(simulator.commandHistory.first { $0.first == 0x53 })
        #expect(reserve.uint32(at: 5) == 16) // 10 blocks rounded up to a DVD ECC block
    }

    @Test func progressReachesEveryPhase() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        let phases = PhaseRecorder()
        _ = try await DiscDrive(transport: simulator).write(patternImage(blocks: 64)) { progress in
            phases.add(progress.phase)
        }
        #expect(phases.seen == [.preparing, .writing, .closing, .verifying])
    }

    @Test func verificationMismatchIsReported() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        simulator.corruptReadBlock = 42
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.verificationFailed(block: 42)) {
            try await drive.write(patternImage(blocks: 100))
        }
        // The drive stays out of macOS's hands until it's settled. The disc closed before verify,
        // so it reads like any finished disc and stays in the drive to be checked.
        #expect(await drive.isHoldingDrive)
        #expect(simulator.hasExclusiveAccess)
        #expect(try await drive.settleAfterFailedBurn(erase: true) == .leftClosed)
        #expect(!simulator.hasExclusiveAccess)
        #expect(simulator.currentMedia != nil)
    }

    @Test func aMisplacedReadDuringVerifyIsReadAgain() async throws {
        // Hardware runs 18 and 20: once, the drive handed back data from 8,184 bytes on, with no
        // error, while the disc held the right data.
        let simulator = SimulatedDrive(media: .init(profile: .bdRSequential, capacityBlocks: 20_000))
        simulator.misplacedReadAt = 48
        let log = CommandLog()
        let report = try await DiscDrive(transport: simulator, log: log).write(patternImage(blocks: 100))
        #expect(report.verified)
        #expect(simulator.misplacedReadAt == nil)
        let text = log.render()
        #expect(text.contains("Verification mismatch at image block 48, read 1 of 3"))
        #expect(text.contains("match the image 8184 bytes further on"))
        #expect(text.contains("Blocks 48 to 63 read back correctly on read 2"))
    }

    @Test func failedBurnOnARewritableDiscIsErased() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdRWSequential, capacityBlocks: 2_297_888))
        simulator.corruptReadBlock = 5
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.verificationFailed(block: 5)) {
            try await drive.write(patternImage(blocks: 100))
        }
        #expect(simulator.hasExclusiveAccess)
        #expect(try await drive.settleAfterFailedBurn(erase: true) == .erased)
        #expect(!simulator.hasExclusiveAccess)
        #expect(try await discState(drive)?.writability == .blank)
    }

    @Test func theWriteSpeedIsSetBeforeAnythingIsWritten() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .bdRSequential, capacityBlocks: 20_000))
        let speeds = [26_970, 8_990, 17_980, 8_990].map { WriteSpeed(kilobytesPerSecond: UInt32($0)) }
        simulator.offeredWriteSpeeds = speeds
        let log = CommandLog()
        let drive = DiscDrive(transport: simulator, log: log)
        // Asked without taking the drive, slowest first, each once.
        let offered = try await drive.writeSpeeds()
        #expect(offered.map(\.kilobytesPerSecond) == [8_990, 17_980, 26_970])
        #expect(!simulator.hasExclusiveAccess)

        let report = try await drive.write(patternImage(blocks: 100), options: WriteOptions(writeSpeed: offered[0]))
        #expect(report.verified)
        let codes = simulator.operationCodes
        let speedSet = try #require(codes.firstIndex(of: 0xB6))
        let firstWrite = try #require(codes.firstIndex(of: 0x2A))
        let firstRead = try #require(codes.firstIndex(of: 0x28))
        #expect(speedSet < firstWrite)
        // Verify reads at the drive's own speed again.
        let restored = try #require(codes.lastIndex(of: 0xB6))
        #expect(restored > firstWrite && restored < firstRead)
        #expect(simulator.writeSpeedSet == nil)
        #expect(log.render().contains("Write speed set to 2x, 8990 kB/s"))
    }

    @Test func aCDTakesItsSpeedFromSetCDSpeed() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .cdR, capacityBlocks: 359_844))
        let speed = WriteSpeed(kilobytesPerSecond: 2_822)
        let drive = DiscDrive(transport: simulator)
        _ = try await drive.write(patternImage(blocks: 100), options: WriteOptions(writeSpeed: speed))
        let codes = simulator.operationCodes
        #expect(try #require(codes.firstIndex(of: 0xBB)) < (try #require(codes.firstIndex(of: 0x2A))))
        #expect(!codes.contains(0xB6))
        #expect(simulator.writeSpeedSet == 2_822)
    }

    @Test func aRefusedSpeedStopsTheBurnBeforeAnythingIsWritten() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .bdRSequential, capacityBlocks: 20_000))
        simulator.refusesWriteSpeed = true
        let drive = DiscDrive(transport: simulator)
        await #expect {
            try await drive.write(patternImage(blocks: 100),
                                  options: WriteOptions(writeSpeed: WriteSpeed(kilobytesPerSecond: 8_990)))
        } throws: { error in
            guard case DriveError.speedNotAccepted(let label, _) = error else { return false }
            return label == "2x"
        }
        #expect(!simulator.operationCodes.contains(0x2A))
        #expect(!(await drive.isHoldingDrive))
        #expect(!simulator.hasExclusiveAccess)
        #expect(try await discState(drive)?.writability == .blank)
    }

    @Test func aDiscEjectedAfterAWriteErrorIsReportedAsEjected() async throws {
        // Hardware run 28: a BD-R XL write failed with 03/0C/00, then READ DISC INFORMATION
        // answered "operation in progress" for longer than the engine waits. The disc was
        // ejected anyway, but the app said it couldn't be.
        let simulator = SimulatedDrive(media: .init(profile: .bdRSequential, capacityBlocks: 20_000))
        simulator.writeErrorAt = 48
        simulator.busyAfterWriteError = 1_000
        let drive = DiscDrive(transport: simulator)
        let quick = WriteOptions(retryWaits: Array(repeating: .milliseconds(1), count: 5))
        await #expect(throws: DriveError.self) { try await drive.write(patternImage(blocks: 100), options: quick) }
        #expect(await drive.isHoldingDrive)
        #expect(try await drive.settleAfterFailedBurn(erase: true) == .ejected)
        #expect(simulator.currentMedia == nil)
        #expect(!simulator.hasExclusiveAccess)
    }

    @Test func failedBurnOnARewritableDiscCanBeEjectedInstead() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdRWSequential, capacityBlocks: 2_297_888))
        simulator.corruptReadBlock = 5
        let drive = DiscDrive(transport: simulator)
        _ = try? await drive.write(patternImage(blocks: 100))
        #expect(try await drive.settleAfterFailedBurn(erase: false) == .ejected)
        #expect(simulator.currentMedia == nil)
        #expect(!simulator.hasExclusiveAccess)
    }


    @Test func tooBigForTheDisc() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .cdR, capacityBlocks: 100))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.doesNotFit(neededBlocks: 101, freeBlocks: 100)) {
            try await drive.write(patternImage(blocks: 101))
        }
        #expect(!simulator.operationCodes.contains(0x2A))
    }

    @Test func busyDriveIsRetried() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .bdRSequential, capacityBlocks: 20_000))
        simulator.longWriteEvery = 3
        let report = try await DiscDrive(transport: simulator).write(patternImage(blocks: 500))
        #expect(report.verified)
    }

    @Test func discRemovedDuringBurn() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        simulator.removeMediaAfterWrites = 3
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.self) {
            try await drive.write(patternImage(blocks: 500),
                                  options: WriteOptions(retryWaits: Array(repeating: .milliseconds(1), count: 5)))
        }
        #expect(try await drive.settleAfterFailedBurn(erase: true) == .nothingNeeded)
        #expect(!simulator.hasExclusiveAccess)
        #expect(try await drive.state() == .noDisc)
    }

    @Test func exclusiveAccessRefused() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        simulator.refusesExclusiveAccess = true
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        await #expect(throws: DriveError.transport(.exclusiveAccessDenied(code: -536870187))) {
            try await drive.write(patternImage(blocks: 10))
        }
    }

    // Hardware run 8: exclusive access was refused as busy while macOS read the disc.
    @Test func exclusiveAccessIsRetriedWhileBusy() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        simulator.exclusiveAccessRefusals = 3
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        let report = try await drive.write(patternImage(blocks: 10))
        #expect(report.verified)
        #expect(simulator.exclusiveAccessRefusals == 0)
    }

    @Test func notBlankIsRefused() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .cdRW, capacityBlocks: 20_000, blockCount: 10))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.notWritable(.needsErase)) {
            try await drive.write(patternImage(blocks: 10))
        }
    }

    @Test func simulatedBurnRecordsNothing() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .cdR, capacityBlocks: 20_000))
        let drive = DiscDrive(transport: simulator)
        let report = try await drive.write(patternImage(blocks: 50), options: WriteOptions(simulate: true))
        #expect(report.simulated)
        #expect(!report.verified)
        #expect(simulator.currentMedia?.blocks.isEmpty == true)
        #expect(!simulator.operationCodes.contains(0x5B))
    }

    @Test func simulationNeedsSupportingMedia() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.simulationUnsupported(.dvdPlusR)) {
            try await drive.write(patternImage(blocks: 10), options: WriteOptions(simulate: true))
        }
    }

    @Test func cancelStopsBeforeWriting() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        let drive = DiscDrive(transport: simulator)
        let task = Task { try await drive.write(patternImage(blocks: 500)) }
        task.cancel()
        await #expect(throws: DriveError.cancelled) {
            try await task.value
        }
        // Nothing reached the disc, so the drive goes straight back to macOS.
        #expect(!(await drive.isHoldingDrive))
        #expect(!simulator.hasExclusiveAccess)
        #expect(!simulator.operationCodes.contains(0x2A))
    }

    @Test func ejectWhenDone() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        _ = try await DiscDrive(transport: simulator).write(patternImage(blocks: 10), options: WriteOptions(ejectWhenDone: true))
        #expect(simulator.currentMedia == nil)
    }
}

@Suite("Long operations")
struct LongOperationTests {
    /// Hardware run 7: a Pioneer BDR-UD04 over USB failed a DVD-RW burn when SYNCHRONIZE CACHE,
    /// sent without the immediate bit, ran past the transport's timeout while the drive closed the disc.
    @Test func dvdRWClosesWithoutHittingTheTransportTimeout() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdRWSequential, capacityBlocks: 2_297_888))
        #expect(simulator.timesOutLongCommands)
        let report = try await DiscDrive(transport: simulator).write(patternImage(blocks: 176))
        #expect(report.verified)
        let sync = try #require(simulator.commandHistory.first { $0.first == 0x35 })
        #expect(sync[1] & 0x02 != 0, "SYNCHRONIZE CACHE must use the immediate bit")
    }

    @Test func closeCommandsUseTheImmediateBit() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .cdR, capacityBlocks: 20_000))
        _ = try await DiscDrive(transport: simulator).write(patternImage(blocks: 20))
        let closes = simulator.commandHistory.filter { $0.first == 0x5B }
        #expect(closes.count == 2)
        #expect(closes.allSatisfy { $0[1] & 0x01 != 0 })
    }

    // Before hardware run 17: a plain retry of a long command could time out as in run 7.
    @Test func aDriveThatRejectsTheImmediateBitGetsNoPlainRetry() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdRWSequential, capacityBlocks: 2_297_888))
        simulator.rejectsImmediateBit = true
        let drive = DiscDrive(transport: simulator)
        do {
            _ = try await drive.write(patternImage(blocks: 176))
            Issue.record("Expected the burn to fail")
        } catch DriveError.commandFailed(let operation, _, let sense?) {
            #expect(operation == "SYNCHRONIZE CACHE")
            #expect(sense.asc == 0x24)
        }
        let syncs = simulator.commandHistory.filter { $0.first == 0x35 }
        #expect(syncs.count == 1)
        #expect(syncs.allSatisfy { $0[1] & 0x02 != 0 })
        // The disc was written to, so the drive stays held until it's settled.
        #expect(await drive.isHoldingDrive)
        #expect(try await drive.settleAfterFailedBurn(erase: false) == .ejected)
    }

    @Test func closingReportsTheDrivesProgress() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        simulator.busyPollsAfterLongCommand = 4
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        let recorder = ClosingRecorder()
        let report = try await drive.write(patternImage(blocks: 50)) { progress in
            if progress.phase == .closing { recorder.add(progress.driveProgress) }
        }
        #expect(report.verified)
        #expect(recorder.values.contains(0.25))
        #expect(recorder.values.contains(0.75))
    }

    @Test func eraseWaitsForTheDriveAndReportsProgress() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 500))
        simulator.busyPollsAfterLongCommand = 2
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        let recorder = ClosingRecorder()
        try await drive.quickErase { recorder.add($0) }
        #expect(recorder.values.contains(0.5))
        let blank = simulator.commandHistory.first { $0.first == 0xA1 }
        #expect(blank.map { $0[1] & 0x10 != 0 } == true)
        #expect(try await discState(drive)?.writability == .blank)
    }
}

/// Collects reported fractions from any thread.
/// Collects values from any thread.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Value] = []

    func add(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

final class ClosingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    func add(_ value: Double?) {
        guard let value else { return }
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

@Suite("Erase and eject")
struct EraseTests {
    @Test func quickEraseMakesTheDiscBlank() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .cdRW, capacityBlocks: 300_000, blockCount: 500))
        let drive = DiscDrive(transport: simulator)
        try await drive.quickErase()
        #expect(try await discState(drive)?.writability == .blank)
        #expect(!simulator.hasExclusiveAccess)
    }

    @Test func eraseClearsAnUnfinishedBurn() async throws {
        var media = SimulatedDrive.Media.written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176)
        media.closed = false
        media.closeInterrupted = true
        let simulator = SimulatedDrive(media: media)
        let drive = DiscDrive(transport: simulator)
        try await drive.quickErase()
        let disc = try #require(try await discState(drive))
        #expect(disc.writability == .blank)
        #expect(!disc.isUnfinished)
    }

    // Hardware run 9: macOS got stuck reading a DVD-RW and held the drive, so erase and eject failed.
    @Test func aDiscMacOSIsStuckOnBlocksTheDrive() async throws {
        var media = SimulatedDrive.Media.written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176)
        media.unreadable = true
        let simulator = SimulatedDrive(media: media)
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        await #expect(throws: DriveError.transport(.exclusiveAccessDenied(code: -536870187))) {
            try await drive.quickErase()
        }
        await #expect(throws: DriveError.self) { try await drive.eject() }
        #expect(simulator.currentMedia != nil)
    }

    @Test func takingTheDriveFirstReachesADiscMacOSIsStuckOn() async throws {
        let simulator = SimulatedDrive()
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        #expect(try await drive.state() == .noDisc)
        try await drive.holdDrive()

        var media = SimulatedDrive.Media.written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176)
        media.unreadable = true
        simulator.insert(media)
        let state = try await drive.waitForDisc(timeout: 5)
        guard case .disc(let disc) = state else {
            Issue.record("Expected a disc, got \(state)")
            return
        }
        #expect(disc.writability == .needsErase)

        let report = try await drive.inspect()
        #expect(report.capacity?.lastBlock == 175)
        #expect(report.reads.map(\.block) == [0, 16, 175])
        #expect(report.reads.allSatisfy { $0.error != nil })
        #expect(simulator.hasExclusiveAccess)

        try await drive.quickErase()
        #expect(simulator.hasExclusiveAccess)
        await drive.releaseDrive()
        #expect(!simulator.hasExclusiveAccess)
        #expect(try await discState(drive)?.writability == .blank)
    }

    @Test func inspectReadsBackAGoodDisc() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdRSequential, capacityBlocks: 2_298_496, blockCount: 176))
        let drive = DiscDrive(transport: simulator)
        let report = try await drive.inspect()
        #expect(report.information.status == .complete)
        #expect(report.tracks.count == 1)
        #expect(report.reads.allSatisfy { $0.error == nil })
        #expect(!simulator.hasExclusiveAccess)
    }

    // Hardware run 11: a quick erase of the DVD-RW left by run 7 ended in an erase failure.
    @Test func quickEraseFailureFallsBackToAFullErase() async throws {
        var media = SimulatedDrive.Media.written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176)
        media.quickEraseFails = true
        let simulator = SimulatedDrive(media: media)
        let drive = DiscDrive(transport: simulator)
        let recorder = Recorder<DiscDrive.EraseProgress>()
        try await drive.erase { recorder.add($0) }

        #expect(try await discState(drive)?.writability == .blank)
        let blanks = simulator.commandHistory.filter { $0.first == 0xA1 }
        #expect(blanks.map { $0[1] & 0x07 } == [0x01, 0x00])
        #expect(blanks.allSatisfy { $0[1] & 0x10 != 0 })
        #expect(recorder.values.contains(DiscDrive.EraseProgress(full: true, fraction: nil)))
        #expect(!simulator.hasExclusiveAccess)
    }

    @Test func quickEraseAloneReportsTheFailure() async throws {
        var media = SimulatedDrive.Media.written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176)
        media.quickEraseFails = true
        let simulator = SimulatedDrive(media: media)
        let drive = DiscDrive(transport: simulator)
        do {
            try await drive.erase(.quick)
            Issue.record("Expected the quick erase to fail")
        } catch DriveError.commandFailed(_, _, let sense?) {
            #expect(sense.isEraseFailure)
        }
        #expect(!simulator.hasExclusiveAccess)
    }

    // Hardware run 13: the log showed the drive was busy but not how far it had got.
    @Test func logShowsTheDrivesProgress() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176))
        simulator.busyPollsAfterLongCommand = 4
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        try await drive.erase(.full)
        #expect(drive.log.render().contains("(progress 50.0%)"))
    }

    // Hardware runs 12 to 14: every erase of the DVD-RW from run 7 failed, drutil's too.
    @Test func formatRecoversADVDRWThatWontErase() async throws {
        var media = SimulatedDrive.Media.written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176)
        media.closed = false
        media.closeInterrupted = true
        media.eraseFails = true
        let simulator = SimulatedDrive(media: media)
        simulator.busyPollsAfterLongCommand = 2
        let drive = DiscDrive(transport: simulator, pollInterval: .milliseconds(1))
        await #expect(throws: DriveError.self) { try await drive.erase() }

        let recorder = ClosingRecorder()
        let profile = try await drive.formatDVDRW { recorder.add($0) }
        #expect(profile == .dvdRWRestrictedOverwrite)
        #expect(recorder.values == [0, 0.5])
        let format = try #require(simulator.commandHistory.first { $0.first == 0x04 })
        #expect(format[1] == 0x11)
        #expect(simulator.lastFormatType == 0x10)
        #expect(!simulator.hasExclusiveAccess)

        // Erasing switches it back to sequential recording, which burnctl writes.
        try await drive.erase()
        let disc = try #require(try await discState(drive))
        #expect(disc.profile == .dvdRWSequential)
        #expect(disc.writability == .blank)
    }

    @Test func quickFormatUsesType15() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176))
        let drive = DiscDrive(transport: simulator)
        #expect(try await drive.formatDVDRW(quick: true) == .dvdRWRestrictedOverwrite)
        let format = try #require(simulator.commandHistory.first { $0.first == 0x04 })
        #expect(format == [0x04, 0x11, 0, 0, 0, 0])
        #expect(simulator.lastFormatType == 0x15)
    }

    @Test func formatNeedsADVDRW() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 20_000))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.unsupportedMedia(.dvdPlusR)) { _ = try await drive.formatDVDRW() }
    }

    // From the first run of the app: a rewritable disc with data should be offered for burning,
    // erased first.
    @Test func overwriteErasesThenBurns() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 500))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.notWritable(.needsErase)) {
            try await drive.write(patternImage(blocks: 100))
        }
        let phases = PhaseRecorder()
        let report = try await drive.write(patternImage(blocks: 100), options: WriteOptions(eraseFirst: true)) { progress in
            phases.add(progress.phase)
        }
        #expect(report.verified)
        #expect(phases.seen == [.preparing, .erasing, .writing, .closing, .verifying])
        #expect(simulator.commandHistory.contains { $0.first == 0xA1 })
        #expect(!simulator.hasExclusiveAccess)
        #expect(!(await drive.isHoldingDrive))
    }

    @Test func overwriteLeavesWriteOnceDiscsAlone() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdPlusR, capacityBlocks: 20_000, blockCount: 50))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.notWritable(.notWritable)) {
            try await drive.write(patternImage(blocks: 10), options: WriteOptions(eraseFirst: true))
        }
        #expect(!simulator.commandHistory.contains { $0.first == 0xA1 })
        #expect(!simulator.hasExclusiveAccess)
    }

    @Test func overwriteThatDoesNotFitGivesTheDriveBack() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .cdRW, capacityBlocks: 300, blockCount: 50))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.doesNotFit(neededBlocks: 400, freeBlocks: 300)) {
            try await drive.write(patternImage(blocks: 400), options: WriteOptions(eraseFirst: true))
        }
        #expect(!simulator.hasExclusiveAccess)
        #expect(!(await drive.isHoldingDrive))
    }

    @Test func burnedDiscsReportWhatTheyHold() async throws {
        let written = SimulatedDrive(media: .written(profile: .cdR, capacityBlocks: 300_000, blockCount: 326))
        let disc = try #require(try await discState(DiscDrive(transport: written)))
        #expect(disc.usedBlocks == 326)
        #expect(disc.usedBytes == 326 * 2048)
        #expect(!disc.canOverwrite)
        let rewritable = SimulatedDrive(media: .written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176))
        #expect(try await discState(DiscDrive(transport: rewritable))?.canOverwrite == true)
        let blank = SimulatedDrive(media: .init(profile: .cdR, capacityBlocks: 300_000))
        #expect(try await discState(DiscDrive(transport: blank))?.usedBlocks == 0)
    }

    @Test func eraseRefusesWriteOnceDiscs() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdPlusR, capacityBlocks: 20_000, blockCount: 5))
        let drive = DiscDrive(transport: simulator)
        await #expect(throws: DriveError.unsupportedMedia(.dvdPlusR)) {
            try await drive.quickErase()
        }
    }

    @Test func eject() async throws {
        let simulator = SimulatedDrive(media: .init(profile: .cdR, capacityBlocks: 1_000))
        let drive = DiscDrive(transport: simulator)
        try await drive.eject()
        #expect(try await drive.state() == .noDisc)
    }

    // Hardware run 8: ejecting a mounted DVD-RW failed with kIOReturnNotPermitted.
    @Test func ejectUnmountsAMountedDisc() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176))
        simulator.isMounted = true
        let drive = DiscDrive(transport: simulator)
        try await drive.eject()
        #expect(try await drive.state() == .noDisc)
        #expect(!simulator.isMounted)
        #expect(!simulator.hasExclusiveAccess)
    }

    // First eject in the app: the unmounted CD-R stayed locked in the drive (05/53/02).
    @Test func ejectUnlocksTheTrayMacOSLocked() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .cdR, capacityBlocks: 300_000, blockCount: 326))
        simulator.isMounted = true
        simulator.mediumRemovalPrevented = true
        let drive = DiscDrive(transport: simulator)
        try await drive.eject()
        #expect(simulator.currentMedia == nil)
        let codes = simulator.operationCodes
        let unlock = try #require(codes.lastIndex(of: 0x1E))
        let eject = try #require(codes.lastIndex(of: 0x1B))
        #expect(unlock < eject)
        #expect(!simulator.hasExclusiveAccess)
    }

    // Hardware run 8: erasing a mounted DVD-RW failed because exclusive access was refused.
    @Test func eraseUnmountsAMountedDisc() async throws {
        let simulator = SimulatedDrive(media: .written(profile: .dvdRWSequential, capacityBlocks: 2_297_888, blockCount: 176))
        simulator.isMounted = true
        let drive = DiscDrive(transport: simulator)
        try await drive.quickErase()
        #expect(try await discState(drive)?.writability == .blank)
        #expect(!simulator.isMounted)
    }
}

/// Collects distinct phases in order, from any thread.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [WritePhase] = []

    func add(_ phase: WritePhase) {
        lock.lock()
        defer { lock.unlock() }
        if phases.last != phase { phases.append(phase) }
    }

    var seen: [WritePhase] {
        lock.lock()
        defer { lock.unlock() }
        return phases
    }
}

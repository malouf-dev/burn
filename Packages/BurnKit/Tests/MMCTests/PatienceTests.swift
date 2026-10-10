import Foundation
import Testing
@testable import MMC
import MMCSimulator

/// An image whose reads covering one block fail on the reads chosen, counting from 1, as a file
/// on a drive that drops out does (hardware run 26).
final class FlakyImage: ImageSource, @unchecked Sendable {
    private let base: MemoryImageSource
    private let block: Int
    private let failing: @Sendable (Int) -> Bool
    private let lock = NSLock()
    private var reads = 0

    init(_ base: MemoryImageSource, block: Int, failing: @escaping @Sendable (Int) -> Bool) {
        self.base = base
        self.block = block
        self.failing = failing
    }

    var blockCount: Int { base.blockCount }
    var readsOfBlock: Int { lock.withLock { reads } }

    func read(block start: Int, count: Int) throws -> [UInt8] {
        if (start..<(start + count)).contains(block) {
            let read = lock.withLock {
                reads += 1
                return reads
            }
            if failing(read) { throw POSIXError(.EIO) }
        }
        return try base.read(block: start, count: count)
    }

    func describe(block: Int) -> String? {
        "Show/E1.mkv from byte \((block * MMC.blockSize).grouped)"
    }
}

/// Collects what the engine reports from its own tasks.
final class Collected<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Element] = []

    var all: [Element] { lock.withLock { stored } }

    func append(_ element: Element) {
        lock.withLock { stored.append(element) }
    }
}

@Suite("Retrying, then holding")
struct PatienceTests {
    /// Five more tries, without the real waits.
    let quick: [Duration] = Array(repeating: .milliseconds(1), count: 5)

    func bluRay() -> SimulatedDrive {
        SimulatedDrive(media: .init(profile: .bdRSequential, capacityBlocks: 20_000))
    }

    @Test func aSourceReadThatFailsTwiceIsReadAgain() async throws {
        let image = FlakyImage(patternImage(blocks: 100), block: 40) { $0 <= 2 }
        let log = CommandLog()
        let retries = Collected<String?>()
        let options = WriteOptions(retryWaits: quick, onRetry: { retries.append($0) })
        let report = try await DiscDrive(transport: bluRay(), log: log).write(image, options: options)
        #expect(report.verified)
        let text = log.render()
        #expect(text.contains("Burn couldn't read Show/E1.mkv from byte 65,536: input/output error. Trying again"))
        #expect(text.contains("Worked on try 3"))
        #expect(retries.all.count == 3)
        #expect(retries.all.last == .some(nil))
    }

    @Test func aSourceThatStaysUnreadableHoldsTheBurnUntilTriedAgain() async throws {
        // The first round of six tries fails, then the file can be read again. Reads go 16 blocks
        // at a time, so the read that fails starts at block 32, byte 65,536.
        let image = FlakyImage(patternImage(blocks: 100), block: 40) { $0 <= 6 }
        let held = Collected<HeldBurn>()
        let options = WriteOptions(retryWaits: quick, whenHeld: { burn in
            held.append(burn)
            return .tryAgain
        })
        let report = try await DiscDrive(transport: bluRay()).write(image, options: options)
        #expect(report.verified)
        let burn = try #require(held.all.first)
        #expect(held.all.count == 1)
        #expect(burn.step == .writing)
        #expect(burn.tries == 6)
        #expect(burn.problem == "Burn couldn't read Show/E1.mkv from byte 65,536: input/output error.")
        #expect(burn.advice.contains("connected and mounted"))
    }

    @Test func anAbandonedBurnStopsSayingWhatWentWrong() async throws {
        let image = FlakyImage(patternImage(blocks: 100), block: 40) { _ in true }
        let drive = DiscDrive(transport: bluRay())
        await #expect {
            try await drive.write(image, options: WriteOptions(retryWaits: quick))
        } throws: { error in
            guard case DriveError.abandoned(let problem, let tries) = error else { return false }
            return tries == 6 && problem.contains("input/output error")
        }
        // Blocks before the failure were written, so the drive is kept until the disc is settled.
        #expect(await drive.isHoldingDrive)
    }

    @Test func aSourceReadDuringVerifyIsReadAgain() async throws {
        // Read 1 is while writing. Reads 2 and 3 are during verify, and fail.
        let image = FlakyImage(patternImage(blocks: 100), block: 40) { $0 == 2 || $0 == 3 }
        let held = Collected<HeldBurn>()
        let options = WriteOptions(retryWaits: quick, whenHeld: { burn in
            held.append(burn)
            return .abandon
        })
        let report = try await DiscDrive(transport: bluRay()).write(image, options: options)
        #expect(report.verified)
        #expect(image.readsOfBlock == 4)
        #expect(held.all.isEmpty)
    }

    @Test func aCancelEndsTheWaiting() async throws {
        let image = FlakyImage(patternImage(blocks: 100), block: 40) { _ in true }
        let drive = DiscDrive(transport: bluRay())
        let started = Date()
        let burn = Task {
            try await drive.write(image, options: WriteOptions(retryWaits: [.seconds(60)]))
        }
        try await Task.sleep(for: .milliseconds(300))
        burn.cancel()
        await #expect(throws: DriveError.cancelled) { try await burn.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

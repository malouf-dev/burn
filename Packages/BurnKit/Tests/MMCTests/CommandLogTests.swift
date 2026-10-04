import Foundation
import Testing
@testable import MMC

@Suite("Command log")
struct CommandLogTests {
    func entry(_ cdb: [UInt8], at seconds: TimeInterval, status: UInt8? = 0) -> CommandLog.Entry {
        CommandLog.Entry(time: Date(timeIntervalSince1970: 1_790_000_000 + seconds), cdb: cdb, dataLength: 0,
                         status: status, sense: nil, error: nil, duration: 0.01)
    }

    func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func linesReachTheFileAsTheyAreLogged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = CommandLog(mirror: url)
        log.note("Burn started")
        log.record(entry([0x00, 0, 0, 0, 0, 0], at: 0))
        // Read back without rendering, as after a crash.
        let written = try lines(url)
        #expect(written.count == 2)
        #expect(written[0].hasSuffix("  Burn started"))
        #expect(written[1].contains("CDB 00 00 00 00 00 00"))
        #expect(log.render().split(separator: "\n").map(String.init) == written)
    }

    @Test func longTransferRunsLeaveALineNowAndThen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = CommandLog(mirror: url)
        let write: [UInt8] = [0x2A, 0, 0, 0, 0, 0, 0, 0, 16, 0]
        for second in 0...100 {
            log.record(entry(write, at: TimeInterval(second)))
        }
        let written = try lines(url)
        // The first write, then a line at 30, 60 and 90 seconds.
        #expect(written.count == 4)
        #expect(written[1].hasSuffix("… 30 transfers of the same kind so far"))
        #expect(written[3].hasSuffix("… 90 transfers of the same kind so far"))

        log.note("Done")
        let after = try lines(url)
        #expect(after[4].hasSuffix("… 100 more transfers of the same kind succeeded, 1.000s in total"))
        #expect(after[5].hasSuffix("  Done"))
    }

    @Test func logsCanShareAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        CommandLog(mirror: url).note("first")
        CommandLog(mirror: url).note("second")
        let written = try lines(url)
        #expect(written.count == 2)
        #expect(written[0].hasSuffix("first"))
        #expect(written[1].hasSuffix("second"))
    }
}

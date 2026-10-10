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

    @Test func aRepeatedAnswerIsLoggedOnlyWhenItChanges() throws {
        // Hardware run 24 and on: polling the empty drive logged every TEST UNIT READY, about
        // 1,800 identical lines an hour.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = CommandLog(mirror: url)
        let testUnitReady: [UInt8] = [0x00, 0, 0, 0, 0, 0]
        func poll(_ sense: SenseData?, at seconds: TimeInterval) {
            log.record(CommandLog.Entry(time: Date(timeIntervalSince1970: 1_790_000_000 + seconds), cdb: testUnitReady,
                                        dataLength: 0, status: sense == nil ? 0 : 2, sense: sense, error: nil,
                                        duration: 0.005))
        }
        log.note("Started")
        for second in 0..<5 { poll(.mediumNotPresent, at: Double(second) * 2) }
        poll(SenseData(key: 0x02, asc: 0x04, ascq: 0x01), at: 10)
        for second in 6..<9 { poll(nil, at: Double(second) * 2) }
        poll(.mediumNotPresent, at: 20)
        // A note starts something new, so its commands are logged even when nothing changed.
        log.note("Burn requested")
        poll(.mediumNotPresent, at: 22)
        poll(.mediumNotPresent, at: 24)

        let written = try lines(url)
        #expect(written.count == 7)
        #expect(written[1].contains("ASC 3Ah"))
        #expect(written[2].contains("ASC 04h ASCQ 01h"))
        #expect(written[3].contains("status 00h"))
        #expect(written[4].contains("ASC 3Ah"))
        #expect(written[5].hasSuffix("  Burn requested"))
        #expect(written[6].contains("ASC 3Ah"))
        #expect(log.render().split(separator: "\n").map(String.init) == written)
    }

    @Test func aRunOfWritesStaysOneLineWhileTheLogIsReadOrFull() throws {
        // Hardware run 26: with the Log panel open, reading the log every second ended the run of
        // writes each time, and once the log held its limit of lines every write was logged on
        // its own, 885 MB in all.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = CommandLog(limit: 3, mirror: url)
        for code in UInt8(0x40)..<0x45 {
            log.record(entry([code, 0, 0, 0, 0, 0], at: 0))
        }
        let write: [UInt8] = [0x2A, 0, 0, 0, 0, 0, 0, 0, 16, 0]
        for index in 0..<100 {
            log.record(entry(write, at: 1 + Double(index) / 10))
            if index % 10 == 0 { _ = log.render() }
        }
        #expect(log.render().hasSuffix("… 99 more transfers of the same kind succeeded, 0.990s in total"))
        log.note("Done")

        let written = try lines(url)
        #expect(written.count == 8)
        #expect(written[5].contains("CDB 2A"))
        #expect(written[6].hasSuffix("… 99 more transfers of the same kind succeeded, 0.990s in total"))
        #expect(written[7].hasSuffix("  Done"))
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

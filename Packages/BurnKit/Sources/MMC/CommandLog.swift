import Foundation

/// A record of every command sent to a drive, for diagnostic reports.
public final class CommandLog: @unchecked Sendable {
    public struct Entry: Sendable {
        public var time: Date
        public var cdb: [UInt8]
        public var dataLength: Int
        public var status: UInt8?
        public var sense: SenseData?
        public var error: String?
        public var duration: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var notes: [(Date, String)] = []
    /// Consecutive successful WRITE or READ commands are counted, not stored, to keep logs small.
    /// The run is the operation code being counted; its first command is logged in full.
    private var runOpcode: UInt8?
    private var repeatedTransfers = 0
    private var repeatStart: Date?
    private var repeatDuration: TimeInterval = 0
    /// Each other command's last answer since the last note. A command that gets the same answer
    /// again, as TEST UNIT READY does every 2 s while the drive is polled, isn't logged again
    /// until the answer changes or a note starts something new.
    private var lastAnswers: [[UInt8]: Answer] = [:]
    private struct Answer: Equatable {
        let status: UInt8?
        let sense: SenseData?
        let error: String?
    }
    private let limit: Int
    /// A file every line is appended to as it's logged, so a crash or a hang leaves the log behind.
    private let mirror: FileHandle?
    private var lastMirrorLine = Date.distantPast
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// - Parameter mirror: a file to append each line to as it's logged. It's created if needed
    ///   and opened for appending, so several logs can share one file.
    public init(limit: Int = 20_000, mirror: URL? = nil) {
        self.limit = limit
        if let mirror {
            let descriptor = open(mirror.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
            self.mirror = descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
        } else {
            self.mirror = nil
        }
    }

    public func record(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        let opcode = entry.cdb.first
        let isTransfer = opcode == 0x2A || opcode == 0x28
        let isGood = entry.status == SCSIStatus.good.rawValue && entry.error == nil
        if isTransfer, isGood, runOpcode == opcode {
            repeatedTransfers += 1
            if repeatStart == nil { repeatStart = entry.time }
            repeatDuration += entry.duration
            // The file gets a line now and then during a long run, so a hang shows where it stopped.
            if mirror != nil, entry.time.timeIntervalSince(lastMirrorLine) >= 30 {
                write(Entry(time: entry.time, cdb: [], dataLength: 0, status: nil, sense: nil,
                            error: "… \(repeatedTransfers) transfers of the same kind so far", duration: 0))
            }
            return
        }
        if !isTransfer {
            let answer = Answer(status: entry.status, sense: entry.sense, error: entry.error)
            if lastAnswers[entry.cdb] == answer { return }
            lastAnswers[entry.cdb] = answer
        }
        flushRepeats()
        runOpcode = isTransfer && isGood ? opcode : nil
        if entries.count < limit {
            entries.append(entry)
        }
        write(entry)
    }

    public func note(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        flushRepeats()
        runOpcode = nil
        lastAnswers = [:]
        notes.append((Date(), text))
        let entry = Entry(time: Date(), cdb: [], dataLength: 0, status: nil, sense: nil, error: text, duration: 0)
        entries.append(entry)
        write(entry)
    }

    private func flushRepeats() {
        if let entry = repeatSummary {
            entries.append(entry)
            write(entry)
            repeatedTransfers = 0
            repeatStart = nil
            repeatDuration = 0
        }
    }

    /// The line for the run being counted, if any.
    private var repeatSummary: Entry? {
        guard repeatedTransfers > 0 else { return nil }
        let summary = "… \(repeatedTransfers) more transfers of the same kind succeeded, "
            + String(format: "%.3fs in total", repeatDuration)
        return Entry(time: repeatStart ?? Date(), cdb: [], dataLength: 0, status: nil, sense: nil,
                     error: summary, duration: 0)
    }

    /// Everything logged, with the run being counted so far. Reading the log leaves the run
    /// going, so a Log panel that reads it every second doesn't split a burn into many lines.
    public func render() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (entries + [repeatSummary].compactMap { $0 }).map(line).joined(separator: "\n")
    }

    /// One write per line, straight to the file, so nothing waits in a buffer if the app dies.
    private func write(_ entry: Entry) {
        guard let mirror else { return }
        try? mirror.writeBytes(Array((line(entry) + "\n").utf8))
        lastMirrorLine = entry.time
    }

    private func line(_ entry: Entry) -> String {
        let time = formatter.string(from: entry.time)
        if entry.cdb.isEmpty {
            return "\(time)  \(entry.error ?? "")"
        }
        var line = "\(time)  CDB \(entry.cdb.hexString)  data \(entry.dataLength)"
        line += String(format: "  %.3fs", entry.duration)
        if let status = entry.status { line += "  status \(hex(status))" }
        if let sense = entry.sense {
            line += "  sense \(sense)"
            if let progress = sense.progress { line += String(format: " (progress %.1f%%)", progress * 100) }
        }
        if let error = entry.error { line += "  error \(error)" }
        return line
    }
}

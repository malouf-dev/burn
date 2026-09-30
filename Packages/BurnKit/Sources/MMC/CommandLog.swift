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
    /// Consecutive identical WRITE and READ commands are counted, not stored, to keep logs small.
    private var repeatedTransfers = 0
    private var repeatStart: Date?
    private var repeatDuration: TimeInterval = 0
    private let limit: Int

    public init(limit: Int = 20_000) {
        self.limit = limit
    }

    public func record(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        let isTransfer = entry.cdb.first == 0x2A || entry.cdb.first == 0x28
        let isGood = entry.status == SCSIStatus.good.rawValue && entry.error == nil
        if isTransfer, isGood, let last = entries.last, last.cdb.first == entry.cdb.first,
           last.status == SCSIStatus.good.rawValue {
            repeatedTransfers += 1
            if repeatStart == nil { repeatStart = entry.time }
            repeatDuration += entry.duration
            return
        }
        flushRepeats()
        if entries.count < limit {
            entries.append(entry)
        }
    }

    public func note(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        flushRepeats()
        notes.append((Date(), text))
        entries.append(Entry(time: Date(), cdb: [], dataLength: 0, status: nil, sense: nil, error: text, duration: 0))
    }

    private func flushRepeats() {
        if repeatedTransfers > 0 {
            let summary = "… \(repeatedTransfers) more transfers of the same kind succeeded, "
                + String(format: "%.3fs in total", repeatDuration)
            entries.append(Entry(time: repeatStart ?? Date(), cdb: [], dataLength: 0, status: nil, sense: nil,
                                 error: summary, duration: 0))
            repeatedTransfers = 0
            repeatStart = nil
            repeatDuration = 0
        }
    }

    public func render() -> String {
        lock.lock()
        defer { lock.unlock() }
        flushRepeats()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { entry in
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
        }.joined(separator: "\n")
    }
}

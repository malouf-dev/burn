import AppKit
import Foundation
import ISOBuilder
import Observation

/// The Verify view's state: one disc (or folder) with a `.burn` checksum folder at a time, and
/// every file on it with its result (decision D12).
@MainActor
@Observable
final class VerifyModel {
    /// Somewhere to check: a mounted disc, a mounted disc image, or a folder chosen by hand.
    struct Source: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let info: DiscInfo?
        var id: URL { url }
    }

    enum Status: Sendable, Equatable {
        case pending
        case matched
        case changed
        case missing
        case unreadable
        /// On the disc but not in the checksum list.
        case unexpected

        init(_ check: FileCheck) {
            switch check {
            case .matched: self = .matched
            case .changed: self = .changed
            case .missing: self = .missing
            case .unreadable: self = .unreadable
            }
        }
    }

    /// One listed file. `id` is its path from the disc's root.
    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let size: Int64?
        var status: Status

        var name: String { (id as NSString).lastPathComponent }
        var folder: String { (id as NSString).deletingLastPathComponent }
    }

    enum Phase: Sendable, Equatable {
        case idle
        case checking(ChecksumProgress)
        case finished(ChecksumReport)
        case failed(String)
    }

    private(set) var sources: [Source] = []
    var selectedID: URL? {
        didSet { if oldValue != selectedID { cancel(); load() } }
    }
    private(set) var rows: [Row] = []
    private(set) var phase: Phase = .idle
    private var rowIndex: [String: Int] = [:]
    private var chosen: [URL] = []
    private var preferred: URL?
    private var task: Task<Void, Never>?

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    var selected: Source? {
        sources.first { $0.id == selectedID }
    }

    var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    /// Prefers the disc in the drive when it has checksums.
    func prefer(_ url: URL?) {
        preferred = url
        refresh()
        if let url, sources.contains(where: { $0.url == url }), !isChecking { selectedID = url }
    }

    /// Finds mounted discs, disc images and chosen folders that have checksums.
    func refresh() {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        var found: [Source] = []
        for url in mounted + chosen where ChecksumVerifier.hasChecksums(at: url) {
            guard !found.contains(where: { $0.url == url }) else { continue }
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            found.append(Source(url: url, name: name, info: ChecksumVerifier.info(at: url)))
        }
        sources = found
        if let selectedID, !found.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if selectedID == nil {
            selectedID = found.first { $0.url == preferred }?.id ?? found.first?.id
        }
    }

    func choose(_ url: URL) {
        if !chosen.contains(url) { chosen.append(url) }
        refresh()
        if sources.contains(where: { $0.url == url }) { selectedID = url }
    }

    /// Lists the selected disc's files, not yet checked.
    private func load() {
        phase = .idle
        guard let root = selected?.url else {
            setRows([])
            return
        }
        do {
            let paths = try ChecksumVerifier.listedFiles(at: root)
            setRows(paths.map { Row(id: $0, size: Self.size(root.appendingPathComponent($0)), status: .pending) })
        } catch {
            setRows([])
            phase = .failed("\(error)")
        }
    }

    func check() {
        guard let source = selected, !isChecking else { return }
        let root = source.url
        setRows(rows.filter { $0.status != .unexpected }.map { Row(id: $0.id, size: $0.size, status: .pending) })
        phase = .checking(ChecksumProgress(checkedFiles: 0, totalFiles: rows.count, checkedBytes: 0,
                                           totalBytes: source.info?.totalBytes ?? 0))
        let throttle = ProgressThrottle()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Phase
            do {
                let report = try ChecksumVerifier.verify(root: root, progress: { progress in
                    guard throttle.shouldReport(progress) else { return }
                    Task { @MainActor in self?.update(progress, root: root) }
                }, file: { path, check in
                    Task { @MainActor in self?.update(path, Status(check), root: root) }
                })
                result = .finished(report)
            } catch is CancellationError {
                result = .idle
            } catch {
                result = .failed("\(error)")
            }
            await MainActor.run { self?.finish(result, root: root) }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Updates

    private func update(_ progress: ChecksumProgress, root: URL) {
        guard selectedID == root, case .checking = phase else { return }
        phase = .checking(progress)
    }

    private func update(_ path: String, _ status: Status, root: URL) {
        guard selectedID == root, let index = rowIndex[path] else { return }
        rows[index].status = status
    }

    private func finish(_ result: Phase, root: URL) {
        guard selectedID == root else { return }
        if case .finished(let report) = result {
            // Settle every row from the report, in case a file's update arrived late.
            for path in report.matched { update(path, .matched, root: root) }
            for path in report.changed { update(path, .changed, root: root) }
            for path in report.missing { update(path, .missing, root: root) }
            for path in report.unreadable { update(path, .unreadable, root: root) }
            setRows(rows + report.unexpected.map { Row(id: $0, size: Self.size(root.appendingPathComponent($0)),
                                                       status: .unexpected) })
        } else if case .idle = result {
            setRows(rows.map { Row(id: $0.id, size: $0.size, status: .pending) })
        }
        phase = result
    }

    private func setRows(_ newRows: [Row]) {
        rows = newRows
        rowIndex = Dictionary(newRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func size(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}

/// Passes on at most one progress update every tenth of a second, plus the last one.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func shouldReport(_ progress: ChecksumProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.1 || progress.checkedFiles == progress.totalFiles else { return false }
        last = now
        return true
    }
}

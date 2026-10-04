import AppKit
import Foundation
import ISOBuilder
import Observation

/// The Verify view's state: one disc (or folder) with a `.burn` checksum folder at a time, and
/// every file on it with its result (decision D12).
///
/// Discs and folders are only ever read off the main thread. Reading a removable volume can make
/// macOS stop and ask the user for permission, and the window must not freeze while it waits.
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
        case repairing(Double)
        /// What the repair did, and the folder it wrote the files to.
        case repaired(RepairReport, URL)
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
    /// True while the selected disc's file list is being read.
    private var loading = false
    /// Whether the last check's disc has PAR2 recovery data, found when the check finished.
    private var recoveryAvailable = false
    private var refreshes = 0

    init() {
        Task { await refresh() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                _ = Task { @MainActor in
                    guard let self else { return }
                    await self.refresh()
                }
            }
        }
    }

    var selected: Source? {
        sources.first { $0.id == selectedID }
    }

    var isChecking: Bool {
        switch phase {
        case .checking, .repairing: return true
        default: return false
        }
    }

    /// True when a check found damage and the disc has PAR2 recovery data to repair it from.
    var canRepair: Bool {
        guard case .finished(let report) = phase, !report.isIntact else { return false }
        return recoveryAvailable
    }

    /// Copies the disc's files into a new folder inside `folder`, rebuilding damaged ones from the
    /// disc's recovery data. The disc itself is never written to.
    func repair(into folder: URL) {
        guard let source = selected, !isChecking else { return }
        let root = source.url
        let name = source.info?.discName ?? source.name
        var destination = folder.appendingPathComponent(String(localized: "\(name) (repaired)"))
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(String(localized: "\(name) (repaired \(number))"))
            number += 1
        }
        let target = destination
        phase = .repairing(0)
        SessionLog.events.note("Repair started: \(root.path) into \(target.path)")
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let hold = SessionLog.Hold("Repairing files")
            defer { hold.release() }
            let result: Phase
            do {
                let report = try RecoveryRepair.repair(root: root, into: target) { fraction in
                    Task { @MainActor in
                        guard let self, self.selectedID == root, case .repairing = self.phase else { return }
                        self.phase = .repairing(fraction)
                    }
                }
                result = .repaired(report, target)
                SessionLog.events.note("Repair finished: \(report.intact.count) intact, \(report.repaired.count) repaired, "
                    + "\(report.unrepairable.count) unrepairable, \(report.damagedSlices) damaged slices, "
                    + "\(report.recoverySlices) recovery slices")
            } catch is CancellationError {
                result = .idle
                SessionLog.events.note("Repair stopped")
            } catch {
                result = .failed("\(error)")
                SessionLog.events.note("Repair failed: \(error)")
            }
            await MainActor.run {
                guard let self, self.selectedID == root else { return }
                self.phase = result
            }
        }
    }

    /// Prefers the disc in the drive when it has checksums.
    func prefer(_ url: URL?) {
        preferred = url
        Task {
            await refresh()
            if let url, sources.contains(where: { $0.url == url }), !isChecking { selectedID = url }
        }
    }

    /// Finds mounted discs, disc images and chosen folders that have checksums.
    func refresh() async {
        refreshes += 1
        let generation = refreshes
        let chosen = self.chosen
        let found = await Task.detached(priority: .userInitiated) { Self.findSources(chosen: chosen) }.value
        // A later refresh may have finished first; its answer is the newer one.
        guard generation == refreshes else { return }
        sources = found
        if let selectedID, !found.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if selectedID == nil {
            selectedID = found.first { $0.url == preferred }?.id ?? found.first?.id
        }
    }

    nonisolated private static func findSources(chosen: [URL]) -> [Source] {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        var found: [Source] = []
        for url in mounted + chosen where ChecksumVerifier.hasChecksums(at: url) {
            guard !found.contains(where: { $0.url == url }) else { continue }
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            found.append(Source(url: url, name: name, info: ChecksumVerifier.info(at: url)))
        }
        return found
    }

    func choose(_ url: URL) {
        if !chosen.contains(url) { chosen.append(url) }
        Task {
            await refresh()
            if sources.contains(where: { $0.url == url }) { selectedID = url }
        }
    }

    /// Lists the selected disc's files, not yet checked.
    private func load() {
        phase = .idle
        recoveryAvailable = false
        setRows([])
        guard let root = selected?.url else {
            loading = false
            return
        }
        loading = true
        Task {
            let listed = await Task.detached(priority: .userInitiated) { () -> Result<[Row], any Error> in
                Result {
                    try ChecksumVerifier.listedFiles(at: root).map {
                        Row(id: $0, size: Self.size(root.appendingPathComponent($0)), status: .pending)
                    }
                }
            }.value
            guard selectedID == root else { return }
            loading = false
            switch listed {
            case .success(let rows):
                setRows(rows)
            case .failure(let error):
                phase = .failed("\(error)")
            }
        }
    }

    func check() {
        guard let source = selected, !isChecking, !loading else { return }
        let root = source.url
        setRows(rows.filter { $0.status != .unexpected }.map { Row(id: $0.id, size: $0.size, status: .pending) })
        phase = .checking(ChecksumProgress(checkedFiles: 0, totalFiles: rows.count, checkedBytes: 0,
                                           totalBytes: source.info?.totalBytes ?? 0))
        let throttle = ProgressThrottle()
        SessionLog.events.note("Check started: \(root.path), \(rows.count) files")
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let hold = SessionLog.Hold("Checking a disc")
            defer { hold.release() }
            let result: Phase
            var extra: [Row] = []
            var hasRecovery = false
            do {
                let report = try ChecksumVerifier.verify(root: root, progress: { progress in
                    guard throttle.shouldReport(progress) else { return }
                    Task { @MainActor in self?.update(progress, root: root) }
                }, file: { path, check in
                    Task { @MainActor in self?.update(path, Status(check), root: root) }
                })
                result = .finished(report)
                extra = report.unexpected.map {
                    Row(id: $0, size: Self.size(root.appendingPathComponent($0)), status: .unexpected)
                }
                hasRecovery = !report.isIntact && RecoveryRepair.hasRecovery(at: root)
                SessionLog.events.note("Check finished: \(report.matched.count) match, \(report.changed.count) changed, "
                    + "\(report.missing.count) missing, \(report.unreadable.count) unreadable")
            } catch is CancellationError {
                result = .idle
                SessionLog.events.note("Check stopped")
            } catch {
                result = .failed("\(error)")
                SessionLog.events.note("Check failed: \(error)")
            }
            await MainActor.run { [extra, hasRecovery] in
                self?.finish(result, root: root, unexpected: extra, hasRecovery: hasRecovery)
            }
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

    private func finish(_ result: Phase, root: URL, unexpected: [Row], hasRecovery: Bool) {
        guard selectedID == root else { return }
        recoveryAvailable = hasRecovery
        if case .finished(let report) = result {
            // Settle every row from the report, in case a file's update arrived late.
            for path in report.matched { update(path, .matched, root: root) }
            for path in report.changed { update(path, .changed, root: root) }
            for path in report.missing { update(path, .missing, root: root) }
            for path in report.unreadable { update(path, .unreadable, root: root) }
            setRows(rows + unexpected)
        } else if case .idle = result {
            setRows(rows.map { Row(id: $0.id, size: $0.size, status: .pending) })
        }
        phase = result
    }

    private func setRows(_ newRows: [Row]) {
        rows = newRows
        rowIndex = Dictionary(newRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated private static func size(_ url: URL) -> Int64? {
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

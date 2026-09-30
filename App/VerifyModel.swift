import AppKit
import Foundation
import ISOBuilder
import Observation

/// The Verify view's state: mounted discs that carry a `.burn` checksum folder, and the check
/// of the one selected (decision D12).
@MainActor
@Observable
final class VerifyModel {
    struct Volume: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let info: DiscInfo?
        var id: URL { url }
    }

    enum State: Equatable, Sendable {
        case idle
        case checking(ChecksumProgress)
        case finished(ChecksumReport)
        case failed(String)
    }

    private(set) var volumes: [Volume] = []
    var selectedID: URL? {
        didSet { if oldValue != selectedID { cancel(); state = .idle } }
    }
    private(set) var state: State = .idle
    /// Folders chosen by hand, such as a copy of a disc, checked as if they were discs.
    private var chosen: [URL] = []
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

    var selected: Volume? {
        volumes.first { $0.id == selectedID }
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    /// Finds mounted discs and chosen folders that have checksums to check against.
    func refresh() {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                            options: [.skipHiddenVolumes]) ?? []
        var found: [Volume] = []
        for url in mounted + chosen where ChecksumVerifier.hasChecksums(at: url) {
            guard !found.contains(where: { $0.url == url }) else { continue }
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            found.append(Volume(url: url, name: name, info: ChecksumVerifier.info(at: url)))
        }
        volumes = found
        if let selectedID, !found.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if selectedID == nil { selectedID = found.first?.id }
    }

    func choose(_ url: URL) {
        if !chosen.contains(url) { chosen.append(url) }
        refresh()
        if volumes.contains(where: { $0.url == url }) { selectedID = url }
    }

    func check() {
        guard let volume = selected, !isChecking else { return }
        let root = volume.url
        state = .checking(ChecksumProgress(checkedFiles: 0, totalFiles: volume.info?.fileCount ?? 0,
                                           checkedBytes: 0, totalBytes: volume.info?.totalBytes ?? 0))
        let throttle = ProgressThrottle()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: State
            do {
                let report = try ChecksumVerifier.verify(root: root) { progress in
                    guard throttle.shouldReport(progress) else { return }
                    Task { @MainActor in
                        if case .checking = self?.state { self?.state = .checking(progress) }
                    }
                }
                result = .finished(report)
            } catch is CancellationError {
                result = .idle
            } catch {
                result = .failed("\(error)")
            }
            await MainActor.run {
                guard let self, self.selectedID == root else { return }
                self.state = result
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
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

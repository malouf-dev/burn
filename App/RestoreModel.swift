import AppKit
import Foundation
import ISOBuilder
import Observation

/// The Restore view's state: copying discs, and disc sets one disc at a time, back into one
/// folder, checked, repaired and with cut files rejoined (decision D16).
///
/// Discs are only ever read off the main thread, as in Verify.
@MainActor
@Observable
final class RestoreModel {
    enum Phase: Equatable {
        case idle
        case restoring(name: String, fraction: Double)
        case comparing(Double)
        case compared(FolderComparison, original: URL)
        case failed(String)
    }

    /// One disc restored this session, and what happened.
    struct Done: Identifiable {
        let id = UUID()
        let name: String
        let report: RestoreReport
    }

    /// Burn discs mounted now.
    private(set) var discs: [VerifyModel.Source] = []
    /// Sets restored, or partly restored, into the destination.
    private(set) var sets: [DiscSetProgress] = []
    private(set) var phase: Phase = .idle
    private(set) var done: [Done] = []

    /// Where discs are restored to. Kept between runs.
    var destination: URL? {
        didSet {
            UserDefaults.standard.set(destination?.path, forKey: "restoreFolder")
            Task { await refresh() }
        }
    }
    /// Starts restoring a disc of a set as soon as it's inserted, if it isn't in yet, while the
    /// Restore view is showing.
    var startsOnInsert: Bool {
        didSet { UserDefaults.standard.set(startsOnInsert, forKey: "restoreStartsOnInsert") }
    }
    /// Whether the Restore view is the one showing. A set's disc inserted while the Burn or Verify
    /// view is open is left alone, so inserting one to check it doesn't start a whole restore.
    var isShowing = false
    /// Ejects each disc once it's restored, ready for the next.
    var ejectsWhenDone: Bool {
        didSet { UserDefaults.standard.set(ejectsWhenDone, forKey: "restoreEjectsWhenDone") }
    }

    private var task: Task<Void, Never>?
    private var refreshes = 0

    init() {
        let defaults = UserDefaults.standard
        destination = defaults.string(forKey: "restoreFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        startsOnInsert = defaults.bool(forKey: "restoreStartsOnInsert")
        ejectsWhenDone = defaults.object(forKey: "restoreEjectsWhenDone") as? Bool ?? true
        Task { await refresh() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                _ = Task { @MainActor in
                    guard let self else { return }
                    await self.refresh()
                    self.startNextIfWanted()
                }
            }
        }
    }

    var isBusy: Bool {
        switch phase {
        case .restoring, .comparing: return true
        default: return false
        }
    }

    /// Whether a disc's files are already in the destination: a set's disc counts once restored.
    func isRestored(_ disc: VerifyModel.Source) -> Bool {
        guard let set = disc.set else { return false }
        return sets.first { $0.id == set.id }?.discsRestored.contains(set.disc) ?? false
    }

    /// Finds mounted Burn discs, and how far each set in the destination has got. Both are read
    /// off the main thread: a disc can make macOS ask for permission, and the folder may be on a NAS.
    func refresh() async {
        refreshes += 1
        let generation = refreshes
        let destination = self.destination
        let (found, progress) = await Task.detached(priority: .userInitiated) {
            (VerifyModel.findSources(chosen: []), destination.map(DiscRestore.progress(in:)) ?? [])
        }.value
        // A later refresh may have finished first; its answer is the newer one.
        guard generation == refreshes else { return }
        discs = found
        sets = progress
    }

    /// Restores the first inserted disc of a set that isn't in the destination yet. Switching to
    /// the Restore view doesn't call this, so a disc already in the drive waits for its button.
    private func startNextIfWanted() {
        guard isShowing, startsOnInsert, destination != nil, !isBusy else { return }
        if let next = discs.first(where: { $0.set != nil && !isRestored($0) }) {
            restore(next)
        }
    }

    func restore(_ disc: VerifyModel.Source) {
        guard let destination, !isBusy else { return }
        let root = disc.url
        let name = disc.info?.discName ?? disc.name
        phase = .restoring(name: name, fraction: 0)
        SessionLog.events.note("Restore started: \(root.path) into \(destination.path)")
        let eject = ejectsWhenDone
        // Captured weakly here, outside any task, so no closure holds `self` strongly around it.
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .restoring = self.phase else { return }
                self.phase = .restoring(name: name, fraction: fraction)
            }
        }
        task = Task {
            // Stop cancels the detached work too.
            let work = Task.detached(priority: .userInitiated) {
                let hold = SessionLog.Hold("Restoring a disc")
                defer { hold.release() }
                return try DiscRestore.restore(root: root, into: destination, progress: progress)
            }
            let result: Phase
            do {
                let report = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                done.insert(Done(name: name, report: report), at: 0)
                SessionLog.events.note("Restore finished: \(report.restored.count) files, \(report.partsPlaced.count) parts, "
                    + "\(report.completed.count) completed, \(report.repaired.count) repaired, \(report.rereads) re-read, "
                    + "\(report.damaged.count) damaged")
                result = .idle
                if eject && report.isComplete {
                    Self.eject(root)
                }
            } catch is CancellationError {
                result = .idle
                SessionLog.events.note("Restore stopped")
            } catch {
                result = .failed("\(error)")
                SessionLog.events.note("Restore failed: \(error)")
            }
            phase = result
            await refresh()
            startNextIfWanted()
        }
    }

    /// Compares what's been restored with the folder it was burned from. If the destination
    /// holds a folder of the same name, as when a folder was added to the burn, that's compared.
    func compare(with original: URL) {
        guard let destination, !isBusy else { return }
        let inside = destination.appendingPathComponent(original.lastPathComponent, isDirectory: true)
        var isFolder: ObjCBool = false
        let copy = FileManager.default.fileExists(atPath: inside.path, isDirectory: &isFolder) && isFolder.boolValue
            ? inside : destination
        phase = .comparing(0)
        SessionLog.events.note("Compare started: \(original.path) with \(copy.path)")
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .comparing = self.phase else { return }
                self.phase = .comparing(fraction)
            }
        }
        task = Task {
            let work = Task.detached(priority: .userInitiated) {
                try FolderComparison.compare(original: original, copy: copy, progress: progress)
            }
            let result: Phase
            do {
                let comparison = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                result = .compared(comparison, original: original)
                SessionLog.events.note("Compare finished: \(comparison.matching.count) match, \(comparison.differing.count) differ, "
                    + "\(comparison.onlyInOriginal.count) only in the original, \(comparison.onlyInCopy.count) only in the copy")
            } catch is CancellationError {
                result = .idle
            } catch {
                result = .failed("\(error)")
            }
            phase = result
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Ejects a restored disc with diskutil, off the main thread: unmounting can wait on
    /// whatever else has the disc open.
    private static func eject(_ volume: URL) {
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["eject", volume.path]
            do {
                try process.run()
                process.waitUntilExit()
                SessionLog.events.note("Ejected \(volume.path): diskutil exit status \(process.terminationStatus)")
            } catch {
                SessionLog.events.note("Couldn't eject \(volume.path): \(error)")
            }
        }
    }
}

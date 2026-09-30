import AppKit
import Foundation
import IOKitTransport
import ISOBuilder
import MMC
import MMCSimulator
import Observation

/// One file or folder the user added.
struct DiscItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    var size: Int64?

    var name: String { url.lastPathComponent }
}

struct DriveInfo: Identifiable, Hashable {
    let id: UInt64
    let name: String
}

/// App state. Everything here runs on the main actor; drive work runs on each drive's actor.
@MainActor
@Observable
final class AppModel {
    enum Activity: Equatable {
        case idle
        case buildingImage(fraction: Double)
        case burning(WriteProgress)
        case erasing
    }

    struct Outcome: Equatable {
        let succeeded: Bool
        let title: String
        let detail: String
    }

    private(set) var drives: [DriveInfo] = []
    var selectedDriveID: UInt64?
    private(set) var driveState: DriveState?
    private(set) var items: [DiscItem] = []
    var discName = String(localized: "Untitled")
    var ejectWhenDone = false
    /// Put a hidden `.burn` folder with a checksum for every file on the disc (decision D12).
    var includeChecksums = true
    private(set) var activity: Activity = .idle
    var outcome: Outcome?
    private(set) var lastLog = ""

    let isDemo: Bool
    private var engines: [UInt64: DiscDrive] = [:]
    private var burnTask: Task<Void, Never>?

    init(demo: Bool) {
        isDemo = demo
        Task { await self.pollDrives() }
    }

    // MARK: - Drives

    private func pollDrives() async {
        while true {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        guard activity == .idle else { return }
        if isDemo {
            if engines.isEmpty {
                let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 2_295_104))
                engines[1] = DiscDrive(transport: simulator)
                drives = [DriveInfo(id: 1, name: "Simulated DVD burner")]
            }
        } else {
            let references = IOKitDrives.list()
            let ids = Set(references.map(\.id))
            for reference in references where engines[reference.id] == nil {
                guard let transport = try? IOKitTransport(reference) else { continue }
                let engine = DiscDrive(transport: transport)
                engines[reference.id] = engine
                let name: String
                if let inquiry = try? await engine.identify() {
                    name = "\(inquiry.vendor) \(inquiry.product)"
                } else {
                    name = String(localized: "Disc burner")
                }
                if !drives.contains(where: { $0.id == reference.id }) {
                    drives.append(DriveInfo(id: reference.id, name: name))
                }
            }
            engines = engines.filter { ids.contains($0.key) }
            drives.removeAll { !ids.contains($0.id) }
        }

        if let selected = selectedDriveID, engines[selected] == nil { selectedDriveID = nil }
        if selectedDriveID == nil { selectedDriveID = drives.first?.id }
        guard let engine = selectedEngine else {
            driveState = nil
            return
        }
        if let state = try? await engine.state() {
            driveState = state
        }
    }

    private var selectedEngine: DiscDrive? {
        selectedDriveID.flatMap { engines[$0] }
    }

    var hasDrive: Bool { !drives.isEmpty }

    var blankDisc: DiscState? {
        if case .disc(let disc) = driveState, disc.writability == .blank { return disc }
        return nil
    }

    // MARK: - Items

    func add(_ urls: [URL]) {
        for url in urls {
            guard !items.contains(where: { $0.url == url }) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item = DiscItem(url: url, isDirectory: isDirectory, size: nil)
            items.append(item)
            if discName == String(localized: "Untitled") && items.count == 1 {
                discName = url.deletingPathExtension().lastPathComponent
            }
            let id = item.id
            Task.detached(priority: .utility) {
                let size = Self.size(of: url)
                await MainActor.run {
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[index].size = size
                    }
                }
            }
        }
    }

    func remove(_ ids: Set<DiscItem.ID>) {
        items.removeAll { ids.contains($0.id) }
    }

    nonisolated private static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let child = enumerator?.nextObject() as? URL {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// File data, rounded up to whole blocks. The image adds a little for directories.
    var estimatedBytes: Int64 {
        items.reduce(0) { $0 + (($1.size ?? 0) + 2047) / 2048 * 2048 }
    }

    var sizesKnown: Bool { items.allSatisfy { $0.size != nil } }

    var fits: Bool {
        guard let disc = blankDisc else { return false }
        return estimatedBytes + 1_000_000 <= disc.freeBytes
    }

    var canBurn: Bool {
        activity == .idle && !items.isEmpty && sizesKnown && fits
    }

    // MARK: - Burning

    func burn() {
        guard canBurn, let engine = selectedEngine, let disc = blankDisc else { return }
        let urls = items.map(\.url)
        let name = discName.isEmpty ? String(localized: "Untitled") : discName
        let options = WriteOptions(verify: true, ejectWhenDone: ejectWhenDone)
        let checksums = includeChecksums
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        activity = .buildingImage(fraction: 0)
        outcome = nil

        burnTask = Task {
            let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("Burn-\(UUID().uuidString).iso")
            defer { try? FileManager.default.removeItem(at: imageURL) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    var builder = ISOImageBuilder(volumeName: name)
                    builder.includesChecksums = checksums
                    builder.applicationName = "Burn \(version)"
                    for url in urls { try builder.add(url) }
                    try builder.write(to: imageURL) { fraction in
                        Task { @MainActor in
                            if case .buildingImage = self.activity { self.activity = .buildingImage(fraction: fraction) }
                        }
                    }
                }.value
                try Task.checkCancellation()
                let image = try FileImageSource(url: imageURL)
                guard image.blockCount <= Int(disc.freeBlocks) else {
                    throw DriveError.doesNotFit(neededBlocks: image.blockCount, freeBlocks: Int(disc.freeBlocks))
                }
                let report = try await engine.write(image, options: options) { progress in
                    Task { @MainActor in self.activity = .burning(progress) }
                }
                var detail = String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(report.imageBlocks) * 2048, countStyle: .file)) written to \(report.profile.name) in \(Int(report.duration)) seconds.")
                if checksums {
                    detail += " " + String(localized: "The disc carries checksums, so you can check it again any time in Verify.")
                }
                finish(Outcome(succeeded: true, title: String(localized: "Written and verified"), detail: detail),
                       log: engine.log)
            } catch DriveError.cancelled, is CancellationError {
                let settled = await settleDisc(engine)
                finish(Outcome(succeeded: false, title: String(localized: "Burn cancelled"),
                               detail: settled ?? String(localized: "A write-once disc can't be used after a cancelled burn.")),
                       log: engine.log)
            } catch {
                let settled = await settleDisc(engine)
                finish(Outcome(succeeded: false, title: String(localized: "The burn failed"),
                               detail: ["\(error)", settled].compactMap { $0 }.joined(separator: "\n\n")),
                       log: engine.log)
            }
        }
    }

    func cancel() {
        burnTask?.cancel()
    }

    /// A burn that fails after changing the disc leaves the engine holding the drive, so macOS
    /// can't get stuck reading a broken disc. Erase a rewritable disc, eject anything else.
    private func settleDisc(_ engine: DiscDrive) async -> String? {
        guard await engine.isHoldingDrive else { return nil }
        do {
            switch try await engine.settleAfterFailedBurn(erase: true) {
            case .erased:
                return String(localized: "The disc was erased so it can be used again.")
            case .ejected:
                return String(localized: "The disc was ejected. Don't put it back in: macOS may get stuck reading it.")
            case .nothingNeeded:
                return nil
            }
        } catch {
            return String(localized: "The disc couldn't be erased or ejected. Unplug the drive to take it out.")
        }
    }

    var isWriteOnceBurn: Bool {
        if case .disc(let disc) = driveState { return !disc.profile.isRewritable }
        return true
    }

    func erase() {
        guard activity == .idle, let engine = selectedEngine else { return }
        activity = .erasing
        outcome = nil
        Task {
            do {
                try await engine.erase()
                finish(Outcome(succeeded: true, title: String(localized: "Disc erased"), detail: ""), log: engine.log)
            } catch {
                finish(Outcome(succeeded: false, title: String(localized: "The erase failed"), detail: "\(error)"),
                       log: engine.log)
            }
        }
    }

    func eject() {
        guard activity == .idle, let engine = selectedEngine else { return }
        Task {
            do {
                try await engine.eject()
            } catch {
                outcome = Outcome(succeeded: false, title: String(localized: "Couldn't eject the disc"), detail: "\(error)")
            }
            await refresh()
        }
    }

    private func finish(_ result: Outcome, log: CommandLog) {
        lastLog = log.render()
        activity = .idle
        outcome = result
        Task { await refresh() }
    }

    func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastLog, forType: .string)
    }
}

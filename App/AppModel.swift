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
    /// Total bytes, or nil while it's being measured.
    var size: Int64?
    /// Space it takes in the image: each file rounded up to whole blocks, plus a block per file
    /// and folder for its UDF File Entry.
    var imageBytes: Int64 = 0
    /// True when the item couldn't be read to measure it.
    var unreadable = false

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
        case preparingRecovery(fraction: Double)
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
    /// Empty until the user names the disc, or adds a single folder, whose name is suggested.
    var discName = "" {
        didSet {
            let trimmed = Self.trimmedDiscName(discName)
            if trimmed != discName { discName = trimmed }
        }
    }

    /// Joliet holds a disc name of up to 16 characters (UTF-16 code units).
    static let discNameLimit = 16

    static func trimmedDiscName(_ name: String) -> String {
        var result = ""
        for character in name {
            if result.utf16.count + String(character).utf16.count > discNameLimit { break }
            result.append(character)
        }
        return result
    }
    var ejectWhenDone = false
    /// Put a hidden `.burn` folder with a checksum for every file on the disc (decision D12).
    var includeChecksums = true
    /// Add PAR2 recovery data to the `.burn` folder, a tenth the size of the files (decision D15).
    var includeRecovery = true
    static let recoveryPercent = 10
    private(set) var activity: Activity = .idle
    var outcome: Outcome?
    /// The volume macOS mounted from a disc that already has data, if any.
    private(set) var discVolume: IOKitTransport.MountedVolume?
    /// True when that volume carries a `.burn` checksum folder to check in Verify.
    private(set) var discHasChecksums = false
    private var transports: [UInt64: IOKitTransport] = [:]
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
                transports[reference.id] = transport
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
            transports = transports.filter { ids.contains($0.key) }
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
        // A disc with data: its name and whether it has checksums, from its mounted volume.
        if case .disc(let disc)? = driveState, disc.writability != .blank,
           let transport = selectedDriveID.flatMap({ transports[$0] }) {
            discVolume = transport.mountedVolume()
            discHasChecksums = discVolume.map { ChecksumVerifier.hasChecksums(at: $0.url) } ?? false
        } else {
            discVolume = nil
            discHasChecksums = false
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

    /// A disc to burn to: a blank one, or a rewritable one with data that the burn erases first.
    var writableDisc: DiscState? {
        if case .disc(let disc) = driveState, disc.writability == .blank || disc.canOverwrite { return disc }
        return nil
    }

    /// True when the burn will erase the disc first.
    var willOverwrite: Bool {
        writableDisc?.canOverwrite == true
    }

    // MARK: - Items

    func add(_ urls: [URL]) {
        for original in urls {
            // Add what an alias or symbolic link points to, not the link itself.
            let url = ((try? URL(resolvingAliasFileAt: original)) ?? original).resolvingSymlinksInPath()
            guard !items.contains(where: { $0.url == url }) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let item = DiscItem(url: url, isDirectory: isDirectory, size: nil)
            items.append(item)
            // A single folder's name is a good suggestion. A file's name usually isn't.
            if discName.isEmpty && items.count == 1 && isDirectory {
                discName = url.lastPathComponent
            }
            let id = item.id
            Task.detached(priority: .utility) {
                let measured = Self.measure(url)
                await MainActor.run {
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[index].size = measured?.total ?? 0
                        self.items[index].imageBytes = measured?.imageBytes ?? 0
                        self.items[index].unreadable = measured == nil
                    }
                }
            }
        }
    }

    func remove(_ ids: Set<DiscItem.ID>) {
        items.removeAll { ids.contains($0.id) }
    }

    /// Removes added items by URL. Rows inside an added folder can't be removed on their own.
    func remove(urls: Set<URL>) {
        items.removeAll { urls.contains($0.url) }
    }

    var rows: [FileRow] {
        items.map(FileRow.init(item:))
    }

    /// The selected drive's command log, for the log panel.
    var currentLog: CommandLog? {
        selectedEngine?.log
    }

    /// Total bytes, and the space it takes in the image, or nil if the item can't be read.
    nonisolated private static func measure(_ url: URL) -> (total: Int64, imageBytes: Int64)? {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        func inImage(_ size: Int64) -> Int64 { (size + 2047) / 2048 * 2048 + 2048 }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        guard values.isDirectory == true else {
            guard let size = values.fileSize else { return nil }
            return (Int64(size), inImage(Int64(size)))
        }
        var total: Int64 = 0
        var imageBytes: Int64 = 2048
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let child = enumerator?.nextObject() as? URL {
            guard let childValues = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if childValues.isDirectory == true {
                imageBytes += 2048
            } else if childValues.isRegularFile == true {
                let size = Int64(childValues.fileSize ?? 0)
                total += size
                imageBytes += inImage(size)
            }
        }
        return (total, imageBytes)
    }

    /// The image's size, near enough: the files and their entries, plus about 1 MB of volume
    /// structures and padding, plus the recovery data. Folder listings add a little more.
    var estimatedBytes: Int64 {
        let files = items.reduce(1_000_000) { $0 + $1.imageBytes }
        let data = items.reduce(0) { $0 + ($1.size ?? 0) }
        return files + (includeChecksums && includeRecovery ? data * Int64(Self.recoveryPercent) / 100 : 0)
    }

    var sizesKnown: Bool { items.allSatisfy { $0.size != nil } }

    /// A rewritable disc's space is known only once it's erased, so the engine checks then.
    var fits: Bool {
        guard let disc = writableDisc else { return false }
        if disc.canOverwrite { return true }
        return estimatedBytes + 1_000_000 <= disc.freeBytes
    }

    var canBurn: Bool {
        activity == .idle && burnBlocker == nil
    }

    /// Why Burn is disabled, in a few words, or nil when it's ready.
    var burnBlocker: String? {
        guard hasDrive else { return String(localized: "Connect a disc burner.") }
        switch driveState {
        case nil, .becomingReady?:
            return String(localized: "Reading the disc…")
        case .noDisc?:
            return String(localized: "Insert a blank disc.")
        case .disc(let disc)?:
            switch disc.writability {
            case .blank: break
            case .needsErase where disc.canOverwrite: break
            case .needsErase: return String(localized: "Erase the disc first.")
            case .unsupported: return String(localized: "This version can't write \(disc.profile.name) discs yet.")
            case .appendable, .notWritable: return String(localized: "This disc is already burned. Insert a blank disc.")
            }
        }
        if items.isEmpty { return String(localized: "Add files to burn.") }
        if let item = items.first(where: \.unreadable) { return String(localized: "Can't read “\(item.name)”.") }
        if !sizesKnown { return String(localized: "Measuring the files…") }
        if !fits { return String(localized: "Too much for this disc.") }
        return nil
    }

    // MARK: - Burning

    func burn() {
        guard canBurn, let engine = selectedEngine, let disc = writableDisc else { return }
        let urls = items.map(\.url)
        let name = discName.isEmpty ? String(localized: "Untitled") : discName
        let options = WriteOptions(verify: true, ejectWhenDone: ejectWhenDone, eraseFirst: disc.canOverwrite)
        let checksums = includeChecksums
        let recovery = includeChecksums && includeRecovery ? Self.recoveryPercent : 0
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        activity = .buildingImage(fraction: 0)
        outcome = nil

        burnTask = Task {
            do {
                // The image is made as the drive asks for it, so nothing is written to disk first.
                let image = try await Task.detached(priority: .userInitiated) {
                    var builder = ISOImageBuilder(volumeName: name)
                    builder.includesChecksums = checksums
                    builder.recoveryPercent = recovery
                    builder.applicationName = "Burn \(version)"
                    for url in urls { try builder.add(url) }
                    return try builder.image()
                }.value
                try Task.checkCancellation()
                // Recovery data needs every file read first, before the drive is taken.
                if image.needsPreparing {
                    activity = .preparingRecovery(fraction: 0)
                    try await withTaskCancellationHandler {
                        try await Task.detached(priority: .userInitiated) {
                            try image.prepare { fraction in
                                Task { @MainActor in
                                    if case .preparingRecovery = self.activity {
                                        self.activity = .preparingRecovery(fraction: fraction)
                                    }
                                }
                            }
                        }.value
                    } onCancel: {
                        image.cancelPreparing()
                    }
                }
                guard disc.canOverwrite || image.blockCount <= Int(disc.freeBlocks) else {
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

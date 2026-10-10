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
    /// Files with data, which PAR2 recovery data covers up to a limit.
    var dataFileCount = 0
    /// True when the item couldn't be read to measure it.
    var unreadable = false
    /// For a file named like a disc image, what's in it, once read.
    var imageKind: DiscImageFile.Kind?

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

    /// UDF holds a disc name of up to 63 characters (UTF-16 code units), or more when every
    /// character fits in 8 bits; 63 always fits. Joliet keeps only the first 16 for older systems.
    static let discNameLimit = 63

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

    /// Burn a single disc image block for block, rather than as a file on a data disc. On by
    /// default whenever one is added alone.
    var burnsImageAsIs = true

    /// The one item, when it's a file named like a disc image.
    var discImage: DiscItem? {
        guard items.count == 1, let item = items.first, !item.isDirectory,
              DiscImageFile.hasImageExtension(item.url) else { return nil }
        return item
    }

    /// True when the burn copies a disc image as it is: no name, checksums or recovery data.
    var burningImage: Bool {
        burnsImageAsIs && discImage != nil && discSet == nil
    }

    /// True when recovery data is on but the files are too many for it.
    var recoveryOmitted: Bool {
        includeChecksums && includeRecovery
            && items.reduce(0) { $0 + $1.dataFileCount } > ISOImageBuilder.recoveryFileLimit
    }
    private(set) var activity: Activity = .idle
    var outcome: Outcome?
    /// The volume macOS mounted from a disc that already has data, if any.
    private(set) var discVolume: IOKitTransport.MountedVolume?
    /// True when that volume carries a `.burn` checksum folder to check in Verify.
    private(set) var discHasChecksums = false
    /// The set that volume's disc belongs to, when it's from one. With no set in progress, the
    /// set is taken to be finished unless the user carries it on.
    private(set) var discSetInfo: DiscSetInfo?
    private var transports: [UInt64: IOKitTransport] = [:]
    private(set) var lastLog = ""

    let isDemo: Bool
    private var engines: [UInt64: DiscDrive] = [:]
    private var burnTask: Task<Void, Never>?

    init(demo: Bool) {
        isDemo = demo
        SessionLog.events.note(demo ? "Started with a simulated drive" : "Started")
        // A quit says so; a log that stops without this line means the app was killed.
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil, queue: nil) { _ in
            SessionLog.events.note("Quitting, peak memory \(SessionLog.peakMemory)")
        }
        loadDiscSet()
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
        await checkSetFiles()
        if isDemo {
            if engines.isEmpty {
                let simulator = SimulatedDrive(media: .init(profile: .dvdPlusR, capacityBlocks: 2_295_104))
                simulator.offeredWriteSpeeds = [5_540, 11_080, 22_160].map { WriteSpeed(kilobytesPerSecond: $0) }
                engines[1] = DiscDrive(transport: simulator, log: SessionLog.driveLog())
                drives = [DriveInfo(id: 1, name: "Simulated DVD burner")]
            }
        } else {
            let references = IOKitDrives.list()
            let ids = Set(references.map(\.id))
            for reference in references where engines[reference.id] == nil {
                guard let transport = try? IOKitTransport(reference) else { continue }
                let engine = DiscDrive(transport: transport, log: SessionLog.driveLog())
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
            // Off the main thread: macOS may stop the read to ask for permission, and the window
            // must not freeze while it waits.
            let volume = transport.mountedVolume()
            let (hasChecksums, setInfo) = await Task.detached {
                (volume.map { ChecksumVerifier.hasChecksums(at: $0.url) } ?? false,
                 volume.flatMap { DiscRestore.setInfo(at: $0.url) })
            }.value
            discHasChecksums = hasChecksums
            discSetInfo = setInfo
            discVolume = volume
        } else {
            discVolume = nil
            discHasChecksums = false
            discSetInfo = nil
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
        cancelDiscSet()
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
            // A disc image added on its own is burned as it is, unless the user says otherwise.
            if items.count == 1 && discImage != nil { burnsImageAsIs = true }
            let id = item.id
            let isImage = !isDirectory && DiscImageFile.hasImageExtension(url)
            Task.detached(priority: .utility) {
                let measured = Self.measure(url)
                let kind: DiscImageFile.Kind? = isImage ? (try? DiscImageFile.inspect(url)) : nil
                await MainActor.run {
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[index].imageKind = kind
                        self.items[index].size = measured?.total ?? 0
                        self.items[index].imageBytes = measured?.imageBytes ?? 0
                        self.items[index].dataFileCount = measured?.dataFiles ?? 0
                        self.items[index].unreadable = measured == nil
                    }
                }
            }
        }
    }

    func remove(_ ids: Set<DiscItem.ID>) {
        cancelDiscSet()
        items.removeAll { ids.contains($0.id) }
    }

    /// Removes added items by URL. Rows inside an added folder can't be removed on their own.
    func remove(urls: Set<URL>) {
        cancelDiscSet()
        items.removeAll { urls.contains($0.url) }
    }

    // MARK: - Disc sets (D16)

    /// Discs being burned one at a time, because the files don't fit on one.
    private(set) var discSet: DiscSetPlan?
    /// The set's disc to burn next, from 1.
    private(set) var setDiscNumber = 1

    /// The set's disc to burn next.
    var nextSetDisc: DiscSetPlan.Disc? {
        discSet.map { $0.discs[setDiscNumber - 1] }
    }

    /// Files the set's next disc needs that are gone or a different size. Checked each time the
    /// drive is polled, so plugging a drive back in clears them.
    private(set) var setFileProblems: [DiscSetPlan.FileProblem] = []

    /// What's wrong with the next disc's files, naming the first, for the set's banner.
    var setFileProblemDetail: String? {
        Self.describe(setFileProblems)
    }

    /// Names the first of a set's file problems, and says how many more there are.
    static func describe(_ problems: [DiscSetPlan.FileProblem]) -> String? {
        guard let problem = problems.first else { return nil }
        let more = problems.count - 1
        if more > 0 {
            return String(localized: "“\(problem.name)” and \(more) more are missing or have changed. Check the drive they're on is connected.")
        }
        return problem.isMissing
            ? String(localized: "“\(problem.name)” is missing. Check the drive it's on is connected.")
            : String(localized: "“\(problem.name)” has changed since the set was planned.")
    }

    /// Checks the next disc's files off the main thread: they may be on a NAS.
    private func checkSetFiles() async {
        guard let set = discSet else {
            setFileProblems = []
            return
        }
        let number = setDiscNumber
        let problems = await Task.detached(priority: .utility) { set.fileProblems(onDiscs: number...number) }.value
        // The set may have moved on while the files were checked.
        guard discSet?.id == set.id, setDiscNumber == number else { return }
        setFileProblems = problems
    }

    /// True when the files are more than the blank disc holds, or more than a 25 GB Blu-ray
    /// when there isn't one, so it's worth offering to split them across discs.
    var canSplitAcrossDiscs: Bool {
        guard discSet == nil, !burningImage, activity == .idle, !items.isEmpty, sizesKnown,
              !items.contains(where: \.unreadable) else { return false }
        if let disc = writableDisc, !disc.canOverwrite { return !fits }
        return estimatedBytes > 12_219_392 * 2048
    }

    /// Disc sizes to plan with: the blank disc in the drive first, when it isn't a standard size.
    var discSizeChoices: [DiscSize] {
        var sizes = DiscSize.standard
        if let inDrive = blankDiscSize, !sizes.contains(inDrive) {
            sizes.insert(inDrive, at: 0)
        }
        return sizes
    }

    /// The blank disc in the drive's size, or a 100 GB BD-R XL when there isn't one.
    var defaultDiscSize: DiscSize {
        blankDiscSize ?? DiscSize.standard.first { $0.blocks == 48_878_592 } ?? DiscSize.standard[0]
    }

    private var blankDiscSize: DiscSize? {
        guard let disc = writableDisc, !disc.canOverwrite else { return nil }
        let blocks = Int(disc.freeBlocks)
        return DiscSize.standard.first { $0.blocks == blocks }
            ?? DiscSize(name: String(localized: "The \(disc.profile.name) in the drive"), blocks: blocks)
    }

    /// Works out which files go on which disc. Reads the files' sizes, so it runs off the main thread.
    func planDiscSet(size: DiscSize) async throws -> DiscSetPlan {
        let urls = items.map(\.url)
        let name = discName.isEmpty ? String(localized: "Untitled") : discName
        let recovery = includeRecovery ? Self.recoveryPercent : 0
        let application = "Burn \(appVersion)"
        return try await Task.detached(priority: .userInitiated) {
            try DiscSetPlan.make(urls: urls, name: name, discSize: size, recoveryPercent: recovery,
                                 applicationName: application)
        }.value
    }

    func startDiscSet(_ plan: DiscSetPlan) {
        discSet = plan
        setDiscNumber = 1
        includeChecksums = true
        SessionLog.events.note("Disc set planned: \"\(plan.name)\", \(plan.discs.count) discs of \(plan.discSize.name), "
            + "last \(plan.discs.last?.blocks ?? 0) blocks")
        saveDiscSet()
    }

    func cancelDiscSet() {
        guard discSet != nil else { return }
        discSet = nil
        setDiscNumber = 1
        saveDiscSet()
    }

    /// Where the set in progress is kept, so it carries on after the app quits or crashes.
    private static var savedSetURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Burn", isDirectory: true)
            .appendingPathComponent("Disc set.json")
    }

    /// Keeps the set in progress on disk, or removes it once there's none. Called whenever the set
    /// or its next disc changes, so a crash loses nothing. The simulated drive leaves it alone.
    private func saveDiscSet() {
        guard !isDemo, let url = Self.savedSetURL else { return }
        do {
            if let discSet {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try SavedDiscSet(plan: discSet, nextDisc: setDiscNumber).encoded().write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            SessionLog.events.note("Couldn't save the disc set: \(error)")
        }
    }

    /// Brings back the set that was in progress when the app last quit or crashed, with its files
    /// listed again. Its files are checked each time the drive is polled, as for any set.
    private func loadDiscSet() {
        guard !isDemo, let url = Self.savedSetURL, let data = try? Data(contentsOf: url) else { return }
        do {
            let saved = try SavedDiscSet(data: data)
            resume(saved.plan, at: saved.nextDisc)
            SessionLog.events.note("Disc set carried on from the last run: \"\(saved.plan.name)\", "
                + "disc \(saved.nextDisc) of \(saved.plan.discs.count) next, \(saved.plan.discs[saved.nextDisc - 1].blocks) blocks")
        } catch {
            SessionLog.events.note("Couldn't read the saved disc set at \(url.path): \(error)")
        }
    }

    /// Makes the set of the disc in the drive again, finding its files under `folder`. Reads the
    /// disc and every file's details, so it runs off the main thread.
    func remakeDiscSet(files folder: URL) async throws -> DiscSetPlan {
        guard let root = discVolume?.url else { throw DiscSetError.notASet }
        return try await Task.detached(priority: .userInitiated) {
            try DiscSetPlan.remake(fromDiscAt: root, files: folder)
        }.value
    }

    /// Carries on with a set made again from one of its discs, at the disc chosen, then ejects
    /// that disc so a blank can go in.
    func continueDiscSet(_ plan: DiscSetPlan, at number: Int) {
        resume(plan, at: number)
        SessionLog.events.note("Disc set carried on from a disc of it: \"\(plan.name)\", "
            + "disc \(number) of \(plan.discs.count) next, \(plan.discs[number - 1].blocks) blocks")
        saveDiscSet()
        eject()
    }

    /// Makes a set the one in progress at disc `number`, with its files listed again in place of
    /// whatever was in the list.
    private func resume(_ plan: DiscSetPlan, at number: Int) {
        items = []
        add(plan.sources)
        discName = plan.name
        includeChecksums = true
        includeRecovery = plan.recoveryPercent > 0
        discSet = plan
        setDiscNumber = number
        setFileProblems = []
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var rows: [FileRow] {
        items.map(FileRow.init(item:))
    }

    /// The selected drive's command log, for the log panel.
    var currentLog: CommandLog? {
        selectedEngine?.log
    }

    /// Total bytes, and the space it takes in the image, or nil if the item can't be read.
    nonisolated private static func measure(_ url: URL) -> (total: Int64, imageBytes: Int64, dataFiles: Int)? {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        func inImage(_ size: Int64) -> Int64 { (size + 2047) / 2048 * 2048 + 2048 }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        guard values.isDirectory == true else {
            guard let size = values.fileSize else { return nil }
            return (Int64(size), inImage(Int64(size)), size > 0 ? 1 : 0)
        }
        var total: Int64 = 0
        var imageBytes: Int64 = 2048
        var dataFiles = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let child = enumerator?.nextObject() as? URL {
            guard let childValues = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if childValues.isDirectory == true {
                imageBytes += 2048
            } else if childValues.isRegularFile == true {
                let size = Int64(childValues.fileSize ?? 0)
                total += size
                imageBytes += inImage(size)
                if size > 0 { dataFiles += 1 }
            }
        }
        return (total, imageBytes, dataFiles)
    }

    /// The image's size, near enough: the files and their entries, plus about 1 MB of volume
    /// structures and padding, plus the recovery data. Folder listings add a little more.
    var estimatedBytes: Int64 {
        if burningImage { return discImage?.size ?? 0 }
        let files = items.reduce(1_000_000) { $0 + $1.imageBytes }
        let data = items.reduce(0) { $0 + ($1.size ?? 0) }
        return files + (includeChecksums && includeRecovery && !recoveryOmitted ? data * Int64(Self.recoveryPercent) / 100 : 0)
    }

    var sizesKnown: Bool { items.allSatisfy { $0.size != nil } }

    /// A rewritable disc's space is known only once it's erased, so the engine checks then.
    var fits: Bool {
        guard let disc = writableDisc else { return false }
        if disc.canOverwrite { return true }
        if burningImage, case .raw(let blocks)? = discImage?.imageKind {
            // Exact, but rounded up to a DVD's 16-block ECC unit, as the engine pads it.
            return (blocks + 15) / 16 * 16 <= Int(disc.freeBlocks)
        }
        return estimatedBytes + 1_000_000 <= disc.freeBytes
    }

    var canBurn: Bool {
        activity == .idle && burnBlocker == nil
    }

    /// Why Burn is disabled, in a few words, or nil when it's ready.
    var burnBlocker: String? {
        guard hasDrive else { return String(localized: "Connect a disc burner.") }
        // Before the disc, so a missing file shows while there's no blank in the drive yet. The
        // set's banner names the file.
        if discSet != nil, let problem = setFileProblems.first {
            if setFileProblems.count > 1 {
                return String(localized: "\(setFileProblems.count) files this disc needs are missing or have changed.")
            }
            return problem.isMissing
                ? String(localized: "A file this disc needs is missing.")
                : String(localized: "A file this disc needs has changed.")
        }
        switch driveState {
        case nil, .becomingReady?:
            return String(localized: "Reading the disc…")
        case .noDisc?:
            if let set = discSet {
                return String(localized: "Insert a blank disc for disc \(setDiscNumber) of \(set.discs.count).")
            }
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
        if let disc = nextSetDisc, let set = discSet {
            if let blank = writableDisc, !blank.canOverwrite, disc.blocks > Int(blank.freeBlocks) {
                let size = ByteCountFormatter.string(fromByteCount: disc.bytes, countStyle: .file)
                return String(localized: "Disc \(disc.number) of \(set.discs.count) needs \(size). Insert a bigger disc.")
            }
            return nil
        }
        if items.isEmpty { return String(localized: "Add files to burn.") }
        if let item = items.first(where: \.unreadable) { return String(localized: "Can't read “\(item.name)”.") }
        if !sizesKnown { return String(localized: "Measuring the files…") }
        if burningImage, let image = discImage {
            switch image.imageKind {
            case nil:
                return String(localized: "Reading the disc image…")
            case .appleDiskImage?:
                return String(localized: "“\(image.name)” is a compressed disc image. Convert it to a .cdr in Disk Utility first.")
            case .notBlockAligned?:
                return String(localized: "“\(image.name)” isn't a disc image. Untick Disc Image to burn it as a file.")
            case .raw?:
                break
            }
        }
        if !fits { return String(localized: "Too much for this disc.") }
        return nil
    }

    // MARK: - Write speed

    /// The speed to write at for every disc type without a speed of its own. Kept in Settings.
    enum SpeedDefault: String, CaseIterable {
        case slowest, fastest
    }

    var speedDefault: SpeedDefault = SpeedDefault(rawValue: UserDefaults.standard.string(forKey: "speedDefault") ?? "")
        ?? .slowest {
        didSet { UserDefaults.standard.set(speedDefault.rawValue, forKey: "speedDefault") }
    }

    /// Speeds picked in the Burn sheet, in kilobytes a second, by disc type. Kept between runs.
    private(set) var chosenSpeeds: [String: Int] =
        UserDefaults.standard.dictionary(forKey: "chosenSpeeds") as? [String: Int] ?? [:] {
        didSet { UserDefaults.standard.set(chosenSpeeds, forKey: "chosenSpeeds") }
    }

    /// The speeds the drive offers for the disc in it, slowest first, once asked.
    private(set) var offeredSpeeds: [WriteSpeed] = []
    private(set) var speedsRead = false

    /// The disc type a picked speed is kept for: a Blu-ray's size, such as "BD-R XL 100 GB",
    /// since one kind of Blu-ray comes in sizes that write at different speeds, or else the
    /// kind of disc, such as "DVD+R".
    var speedDiscType: String? {
        guard let disc = writableDisc else { return nil }
        if disc.profile.mediaClass == .bluRay, !disc.canOverwrite,
           let size = DiscSize.standard.first(where: { $0.blocks == Int(disc.freeBlocks) }) {
            return size.name
        }
        return disc.profile.name
    }

    /// The speed picked for this disc type, as the nearest the drive offers at or below it, or
    /// nil when none was picked and the Settings default applies.
    var chosenSpeed: WriteSpeed? {
        get {
            guard let type = speedDiscType, let picked = chosenSpeeds[type], !offeredSpeeds.isEmpty else { return nil }
            return offeredSpeeds.last { Int($0.kilobytesPerSecond) <= picked } ?? offeredSpeeds.first
        }
        set {
            guard let type = speedDiscType else { return }
            chosenSpeeds[type] = newValue.map { Int($0.kilobytesPerSecond) }
        }
    }

    /// The speed the burn writes at: the one picked for this disc type, or the Settings default.
    /// Nil when the drive doesn't say what it offers, which leaves the speed to the drive.
    var burnSpeed: WriteSpeed? {
        if let chosenSpeed { return chosenSpeed }
        return speedDefault == .fastest ? offeredSpeeds.last : offeredSpeeds.first
    }

    func speedLabel(_ speed: WriteSpeed) -> String {
        speed.label(for: writableDisc?.profile.mediaClass ?? .other)
    }

    /// Asks the drive which speeds it offers for the disc in it, for the Burn sheet.
    func readWriteSpeeds() async {
        speedsRead = false
        let speeds = await (try? selectedEngine?.writeSpeeds()) ?? []
        offeredSpeeds = speeds
        speedsRead = true
    }

    // MARK: - Burning

    func burn() {
        guard canBurn, let engine = selectedEngine, let disc = writableDisc else { return }
        let urls = items.map(\.url)
        let name = discName.isEmpty ? String(localized: "Untitled") : discName
        let speed = burnSpeed
        let options = WriteOptions(verify: true, ejectWhenDone: ejectWhenDone, eraseFirst: disc.canOverwrite,
                                   writeSpeed: speed)
        let imageFile = burningImage ? discImage?.url : nil
        let checksums = includeChecksums && imageFile == nil
        let recovery = checksums && includeRecovery ? Self.recoveryPercent : 0
        let version = appVersion
        let set = discSet
        let setNumber = setDiscNumber
        activity = .buildingImage(fraction: 0)
        outcome = nil
        let log = engine.log
        if let imageFile {
            log.note("Burn requested: the disc image \"\(imageFile.path)\" as it is, "
                + "onto \(disc.profile.name) with \(disc.freeBlocks) free blocks")
        } else if let set {
            log.note("Burn requested: disc \(setNumber) of \(set.discs.count) of the set \"\(set.name)\", "
                + "\(set.discs[setNumber - 1].blocks) blocks, onto \(disc.profile.name) with \(disc.freeBlocks) free blocks")
        } else {
            log.note("Burn requested: \"\(name)\", \(urls.count) items, checksums \(checksums ? "on" : "off"), "
                + "recovery \(recovery)%, onto \(disc.profile.name) with \(disc.freeBlocks) free blocks")
        }

        if let speed {
            let reason = chosenSpeed != nil
                ? "picked for \(speedDiscType ?? disc.profile.name) discs"
                : "the \(speedDefault == .fastest ? "fastest" : "slowest") the drive offers, as set in Settings"
            log.note("Speed: \(speedLabel(speed)), \(reason)")
        } else {
            log.note("Speed: the drive's own, since it didn't say which speeds it offers")
        }

        burnTask = Task {
            // A burn can't be paused, so macOS mustn't end the app or let the Mac sleep during one.
            let hold = SessionLog.Hold("Burning a disc")
            defer { hold.release() }
            do {
                let image: any ImageSource
                if let imageFile {
                    // A disc image goes on as it is.
                    image = try await Task.detached(priority: .userInitiated) { try FileImageSource(url: imageFile) }.value
                    log.note("Disc image opened: \(image.blockCount) blocks")
                } else {
                    image = try await makeImage(log: log, set: set, setNumber: setNumber, name: name, urls: urls,
                                                checksums: checksums, recovery: recovery, version: version)
                }
                try Task.checkCancellation()
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
                var title = String(localized: "Written and verified")
                if let set {
                    title = String(localized: "Disc \(setNumber) of \(set.discs.count) written and verified")
                    if setNumber < set.discs.count {
                        setDiscNumber = setNumber + 1
                        detail += " " + String(localized: "Insert a blank disc for disc \(setNumber + 1).")
                    } else {
                        discSet = nil
                        setDiscNumber = 1
                        detail += " " + String(localized: "That was the last disc: the set is complete.")
                    }
                    saveDiscSet()
                }
                finish(Outcome(succeeded: true, title: title, detail: detail), log: engine.log)
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

    /// Lays out a data disc's image, and makes its recovery data, which needs every file read
    /// first, before the drive is taken. The image itself is made as the drive asks for it, so
    /// nothing is written to disk first.
    private func makeImage(log: CommandLog, set: DiscSetPlan?, setNumber: Int, name: String, urls: [URL],
                           checksums: Bool, recovery: Int, version: String) async throws -> DiscImage {
        let image = try await Task.detached(priority: .userInitiated) {
            if let set { return try set.builder(forDisc: setNumber).image() }
            var builder = ISOImageBuilder(volumeName: name)
            builder.includesChecksums = checksums
            builder.recoveryPercent = recovery
            builder.applicationName = "Burn \(version)"
            for url in urls { try builder.add(url) }
            return try builder.image()
        }.value
        log.note("Image laid out: \(image.blockCount) blocks")
        try Task.checkCancellation()
        if image.needsPreparing {
            activity = .preparingRecovery(fraction: 0)
            log.note("Making recovery data")
            let started = Date()
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try image.prepare { fraction in
                        Task { @MainActor in
                            if case .preparingRecovery(let previous) = self.activity {
                                if Int(fraction * 10) > Int(previous * 10) {
                                    log.note("Recovery data \(Int(fraction * 10) * 10)% made, "
                                        + "peak memory \(SessionLog.peakMemory)")
                                }
                                self.activity = .preparingRecovery(fraction: fraction)
                            }
                        }
                    }
                }.value
            } onCancel: {
                image.cancelPreparing()
            }
            log.note("Recovery data made in \(Int(Date().timeIntervalSince(started))) seconds")
        }
        return image
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
            case .leftClosed:
                return String(localized: "The disc was closed, so it was left in the drive. Check it in Verify: a failed verify can be the drive misreading a good disc.")
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
        log.note("\(result.title). \(result.detail)")
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

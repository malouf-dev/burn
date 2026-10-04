import Foundation
import ISOBuilder
import IOKitTransport
import MMC
import MMCSimulator

@main
struct BurnCtl {
    static let usage = """
    burnctl: test the Burn engine from the command line.

    Usage:
      burnctl list
      burnctl diagnose
      burnctl status [--drive N]
      burnctl make-iso PATH... --output FILE [--name NAME] [--no-checksums] [--no-udf] [--recovery PERCENT]
      burnctl burn PATH... [--drive N] [--name NAME] [--overwrite] [--simulate] [--no-verify] [--no-checksums] [--no-udf] [--recovery PERCENT] [--eject] [--yes] [--log FILE]
      burnctl verify-files PATH
      burnctl repair PATH --output FOLDER
      burnctl erase [--drive N] [--full] [--yes] [--log FILE]
      burnctl inspect [--drive N] [--log FILE]
      burnctl format [--drive N] [--quick] [--yes] [--log FILE]
      burnctl eject [--drive N]
      burnctl simulate-burn PATH... [--profile cd-r|cd-rw|dvd-r|dvd+r|dvd+r-dl|bd-r] [--name NAME]

    PATH is a file or folder to put on the disc, or a single .iso image to burn as it is.
    A single folder's contents go at the root of the disc, which is named after the folder.
    Drives are numbered from 1, in the order `burnctl list` shows them.
    burn --overwrite erases a rewritable disc that has data on it, then burns, keeping the drive
    throughout.
    Discs get a hidden .burn folder with a SHA-256 checksum for every file. verify-files checks a
    mounted disc, such as /Volumes/Name, against it. So does `shasum -a 256 -c .burn/SHA256SUMS`
    run from the disc's root.
    Discs also get PAR2 recovery data in .burn. repair copies a disc's files into FOLDER and
    rebuilds damaged ones from it. Any PAR2 tool can do the same with .burn/recovery.par2.
    Run erase or inspect with the drive empty to take the drive first, then insert the disc
    when asked. macOS then never reads the disc, which reaches discs it gets stuck on.
    """

    static func main() async {
        var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
        guard let command = arguments.next() else {
            print(usage)
            exit(2)
        }
        do {
            switch command {
            case "list": try await list()
            case "diagnose": diagnose()
            case "status": try await status(&arguments)
            case "make-iso": try makeISO(&arguments)
            case "burn": try await burn(&arguments)
            case "erase": try await erase(&arguments)
            case "inspect": try await inspect(&arguments)
            case "format": try await format(&arguments)
            case "eject": try await eject(&arguments)
            case "verify-files": try verifyFiles(&arguments)
            case "repair": try repair(&arguments)
            case "simulate-burn": try await simulateBurn(&arguments)
            case "help", "-h", "--help":
                print(usage)
            default:
                print("Unknown command: \(command)\n")
                print(usage)
                exit(2)
            }
        } catch {
            printError("\(error)")
            exit(1)
        }
    }

    // MARK: - Commands

    static func list() async throws {
        let drives = IOKitDrives.list()
        if drives.isEmpty {
            print("No disc burners found.")
            return
        }
        for (index, reference) in drives.enumerated() {
            do {
                let drive = DiscDrive(transport: try IOKitTransport(reference))
                let inquiry = try await drive.identify()
                print("\(index + 1). \(inquiry.vendor) \(inquiry.product) (firmware \(inquiry.revision))  id \(reference.id)")
            } catch {
                print("\(index + 1). Couldn't open drive \(reference.id): \(error)")
            }
        }
    }

    /// Prints each step of opening every drive, to find where it fails.
    static func diagnose() {
        let drives = IOKitDrives.list()
        print("Found \(drives.count) burner(s).")
        for (index, reference) in drives.enumerated() {
            print("\nDrive \(index + 1), id \(reference.id)")
            print(IOKitTransport.diagnose(reference), terminator: "")
        }
    }

    static func status(_ arguments: inout Arguments) async throws {
        let drive = try openDrive(arguments.option("--drive"))
        let inquiry = try await drive.identify()
        print("Drive: \(inquiry.vendor) \(inquiry.product) (firmware \(inquiry.revision))")
        print("Disc:  \(describe(try await drive.state()))")
    }

    static func makeISO(_ arguments: inout Arguments) throws {
        guard let output = arguments.option("--output") else { throw CLIError("make-iso needs --output FILE") }
        let nameOption = arguments.option("--name")
        let checksums = !arguments.flag("--no-checksums")
        let udf = !arguments.flag("--no-udf")
        let recovery = try recoveryPercent(&arguments)
        let paths = arguments.remaining()
        guard !paths.isEmpty else { throw CLIError("make-iso needs at least one file or folder") }
        let name = nameOption ?? defaultName(for: paths)
        let builder = try makeBuilder(paths: paths, name: name, checksums: checksums, udf: udf, recovery: recovery)
        warnIfRecoveryOmitted(builder)
        let started = Date()
        let blocks = try builder.write(to: URL(fileURLWithPath: output))
        print(String(format: "Made the image in %.1f seconds.", Date().timeIntervalSince(started)))
        print("Wrote \(output): \(blocks) blocks (\(formatBytes(Int64(blocks) * 2048)))")
    }

    static func burn(_ arguments: inout Arguments) async throws {
        let driveNumber = arguments.option("--drive")
        let name = arguments.option("--name")
        let simulate = arguments.flag("--simulate")
        let verify = !arguments.flag("--no-verify")
        let checksums = !arguments.flag("--no-checksums")
        let udf = !arguments.flag("--no-udf")
        let recovery = try recoveryPercent(&arguments)
        let overwrite = arguments.flag("--overwrite")
        let eject = arguments.flag("--eject")
        let yes = arguments.flag("--yes")
        let logPath = arguments.option("--log")
        let paths = arguments.remaining()
        guard !paths.isEmpty else { throw CLIError("burn needs at least one file or folder") }

        let drive = try openDrive(driveNumber)
        let image = try prepareImage(paths: paths, name: name ?? defaultName(for: paths), checksums: checksums, udf: udf,
                                     recovery: recovery)
        print("Image: \(image.blockCount) blocks (\(formatBytes(Int64(image.blockCount) * 2048)))")

        let state = try await drive.state()
        print("Disc:  \(describe(state))")
        guard case .disc(let disc) = state, disc.writability == .blank || (overwrite && disc.canOverwrite) else {
            if case .disc(let disc) = state, disc.canOverwrite {
                throw CLIError("This \(disc.profile.name) has data on it. Add --overwrite to erase it and burn.")
            }
            throw CLIError("The disc in the drive can't be written. Insert a blank disc.")
        }
        if !yes {
            let action = simulate ? "Simulate burning" : (disc.writability == .blank ? "Burn" : "Erase and burn")
            guard confirm("\(action) \(disc.profile.name)? This can't be undone on write-once discs. Type yes to continue: ") else {
                print("Cancelled.")
                return
            }
        }

        let started = Date()
        do {
            let options = WriteOptions(simulate: simulate, verify: verify, ejectWhenDone: eject, eraseFirst: overwrite)
            let report = try await drive.write(image, options: options) { progress in
                printProgress(progress)
            }
            print("")
            var outcome = report.verified ? "Written and verified" : (report.simulated ? "Simulated burn finished" : "Written, not verified")
            outcome += String(format: " in %.0f seconds.", Date().timeIntervalSince(started))
            print(outcome)
            try writeLog(drive.log, to: logPath)
        } catch {
            print("")
            printError("\(error)")
            if await drive.isHoldingDrive {
                await settleFailedBurn(drive, rewritable: disc.profile.isRewritable, askToErase: !yes)
            }
            let path = try writeLog(drive.log, to: logPath ?? defaultLogPath())
            if let path { printError("Diagnostic log: \(path)") }
            exit(1)
        }
    }

    /// After a burn fails part-way, burnctl still has the drive. Erase or eject the disc before
    /// giving the drive back, so macOS never gets stuck reading it.
    static func settleFailedBurn(_ drive: DiscDrive, rewritable: Bool, askToErase: Bool) async {
        print("The disc may not read back, and macOS can get stuck reading a disc like that. "
              + "burnctl has kept the drive so macOS can't see it yet.")
        let erase = rewritable && askToErase
            && confirm("Erase the disc now so it can be used again? Type yes to erase, anything else to eject it: ")
        do {
            let result = try await drive.settleAfterFailedBurn(erase: erase) { progress in
                printEraseProgress(progress, quickFirst: true)
            }
            if erase { print("") }
            switch result {
            case .erased:
                print("Erased. The disc is blank and safe to put back in.")
            case .ejected:
                print("Ejected. Don't put it back in as it is: macOS may get stuck reading it.")
                print(rewritable
                      ? "To reuse it, run `burnctl erase` with the drive empty and insert it when asked."
                      : "To check it, run `burnctl inspect` with the drive empty and insert it when asked.")
            case .leftClosed:
                print("The disc was closed, so it was left in the drive for macOS to mount.")
                print("Check it with `burnctl verify-files` on the mounted volume: "
                      + "a failed verify can be the drive misreading a good disc.")
            case .nothingNeeded:
                print("The disc was untouched or gone. The drive is back with macOS.")
            }
        } catch {
            print("")
            printError("Couldn't settle the disc: \(error)")
        }
    }

    static func erase(_ arguments: inout Arguments) async throws {
        let drive = try openDrive(arguments.option("--drive"))
        let yes = arguments.flag("--yes")
        let full = arguments.flag("--full")
        let logPath = arguments.option("--log")
        let state = try await discStateTakingDriveIfEmpty(drive, logPath: logPath)
        print("Disc: \(describe(state))")
        if !yes {
            guard confirm("Erase this disc? Everything on it will be lost. Type yes to continue: ") else {
                await drive.releaseDrive()
                print("Cancelled.")
                return
            }
        }
        do {
            printStatusLine(full ? "Erasing the whole disc…" : "Erasing…")
            try await drive.erase(full ? .full : .quickThenFull) { progress in
                printEraseProgress(progress, quickFirst: !full)
            }
            print("")
            await drive.releaseDrive()
            print("Erased.")
            try writeLog(drive.log, to: logPath)
        } catch {
            print("")
            await drive.releaseDrive()
            try fail(error, drive: drive, logPath: logPath)
        }
    }

    static func printEraseProgress(_ progress: DiscDrive.EraseProgress, quickFirst: Bool) {
        let label = progress.full ? "Erasing the whole disc" : "Erasing"
        guard let fraction = progress.fraction else {
            if progress.full && quickFirst {
                print("")
                print("The drive reported the quick erase as failed. Erasing the whole disc, which can take an hour.")
            }
            printStatusLine(label + "…")
            return
        }
        printStatusLine(label + " " + String(format: "%5.1f%%", fraction * 100))
    }

    /// Copies a disc's files into a folder, rebuilding damaged ones from its recovery data.
    static func repair(_ arguments: inout Arguments) throws {
        guard let output = arguments.option("--output") else { throw CLIError("repair needs --output FOLDER") }
        guard let path = arguments.remaining().first else { throw CLIError("repair needs the disc's path, such as /Volumes/Name") }
        guard FileManager.default.fileExists(atPath: path) else { throw CLIError("\(path) doesn't exist.") }
        let report = try RecoveryRepair.repair(root: URL(fileURLWithPath: path), into: URL(fileURLWithPath: output))
        print("\(report.damagedSlices) damaged slices, \(report.recoverySlices) recovery slices.")
        for name in report.repaired { print("Repaired:       \(name)") }
        for name in report.unrepairable { print("Not repairable: \(name)") }
        print("\(report.intact.count) files were intact, \(report.repaired.count) repaired, \(report.unrepairable.count) not repairable.")
        if !report.isComplete { throw CLIError("Some files couldn't be repaired.") }
    }

    /// Checks a mounted disc's files against its `.burn/SHA256SUMS`.
    static func verifyFiles(_ arguments: inout Arguments) throws {
        guard let path = arguments.remaining().first else { throw CLIError("verify-files needs the disc's path, such as /Volumes/Name") }
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError("\(path) doesn't exist. Use the disc's path as Finder shows it, such as /Volumes/Name.")
        }
        let root = URL(fileURLWithPath: path)
        if let info = ChecksumVerifier.info(at: root) {
            print("Disc: \(info.discName), made \(info.created) by \(info.application), \(info.fileCount) files")
        }
        let report = try ChecksumVerifier.verify(root: root) { progress in
            printStatusLine("Checking " + String(format: "%5.1f%%", progress.fraction * 100)
                            + "  \(progress.checkedFiles) of \(progress.totalFiles) files")
        }
        print("")
        for path in report.changed { print("Changed: \(path)") }
        for path in report.missing { print("Missing: \(path)") }
        for path in report.unreadable { print("Couldn't read: \(path)") }
        for path in report.unexpected { print("Not in the list: \(path)") }
        if report.isIntact {
            print("All \(report.matched.count) files match their checksums.")
        } else {
            let problems = report.changed.count + report.missing.count + report.unreadable.count
            print("\(problems) of \(report.checkedCount) files don't match.")
            exit(1)
        }
    }

    /// Fully formats a DVD-RW, a way back for one that erasing can't fix.
    static func format(_ arguments: inout Arguments) async throws {
        let drive = try openDrive(arguments.option("--drive"))
        let yes = arguments.flag("--yes")
        let quick = arguments.flag("--quick")
        let logPath = arguments.option("--log")
        let state = try await discStateTakingDriveIfEmpty(drive, logPath: logPath)
        print("Disc: \(describe(state))")
        if !yes {
            guard confirm("Format this DVD-RW? Everything on it will be lost, and it can take an hour. Type yes to continue: ") else {
                await drive.releaseDrive()
                print("Cancelled.")
                return
            }
        }
        do {
            printStatusLine("Formatting…")
            let profile = try await drive.formatDVDRW(quick: quick) { fraction in
                if let fraction {
                    printStatusLine("Formatting " + String(format: "%5.1f%%", fraction * 100))
                }
            }
            print("")
            await drive.releaseDrive()
            print("Formatted. The disc is now \(profile.name).")
            if profile == .dvdRWRestrictedOverwrite {
                print("burnctl writes DVD-RW in sequential mode. Run `burnctl erase` to switch the disc back.")
            }
            try writeLog(drive.log, to: logPath)
        } catch {
            print("")
            await drive.releaseDrive()
            try fail(error, drive: drive, logPath: logPath)
        }
    }

    /// Prints everything the drive reports about the disc and tries to read a few key blocks.
    static func inspect(_ arguments: inout Arguments) async throws {
        let drive = try openDrive(arguments.option("--drive"))
        let logPath = arguments.option("--log")
        let state = try await discStateTakingDriveIfEmpty(drive, logPath: logPath)
        print("Disc: \(describe(state))")
        do {
            let report = try await drive.inspect()
            await drive.releaseDrive()
            let info = report.information
            print("Disc information: status \(info.status), last session \(info.lastSessionState), "
                  + "erasable \(info.isErasable), sessions \(info.sessions), "
                  + "tracks \(info.firstTrackInLastSession)-\(info.lastTrackInLastSession)")
            for track in report.tracks {
                print("Track \(track.track): start \(track.start), size \(track.size), free \(track.freeBlocks), "
                      + "blank \(track.isBlank), reserved \(track.isReserved), "
                      + "next writable \(track.nextWritableValid ? String(track.nextWritable) : "none")")
            }
            if let capacity = report.capacity {
                print("Capacity: last block \(capacity.lastBlock), block size \(capacity.blockLength)")
            }
            for read in report.reads {
                let time = String(format: "%.1fs", read.duration)
                print("Read block \(read.block): \(read.error.map { "failed after \(time): \($0)" } ?? "OK in \(time)")")
            }
            try writeLog(drive.log, to: logPath)
        } catch {
            await drive.releaseDrive()
            try fail(error, drive: drive, logPath: logPath)
        }
    }

    /// With a disc in, returns its state. With the drive empty, takes the drive first and waits
    /// for a disc, so macOS never reads it. The caller releases the drive.
    static func discStateTakingDriveIfEmpty(_ drive: DiscDrive, logPath: String?) async throws -> DriveState {
        do {
            let state = try await drive.state()
            guard state == .noDisc else { return state }
            try await drive.holdDrive()
            print("The drive is ours, so macOS won't read the next disc. Insert the disc now.")
            return try await drive.waitForDisc()
        } catch {
            await drive.releaseDrive()
            try fail(error, drive: drive, logPath: logPath)
        }
    }

    static func fail(_ error: Error, drive: DiscDrive, logPath: String?) throws -> Never {
        let path = try writeLog(drive.log, to: logPath ?? defaultLogPath())
        printError("\(error)")
        if case DriveError.transport(.exclusiveAccessDenied) = error {
            printError("""
                macOS is holding the drive, perhaps stuck reading this disc. Eject the disc (unplug the \
                drive if the button doesn't respond). Then run this command again with the drive empty \
                and insert the disc when asked.
                """)
        }
        if let path { printError("Diagnostic log: \(path)") }
        exit(1)
    }

    static func eject(_ arguments: inout Arguments) async throws {
        let drive = try openDrive(arguments.option("--drive"))
        try await drive.eject()
    }

    /// Runs the whole pipeline against the simulated drive: build, write, verify.
    static func simulateBurn(_ arguments: inout Arguments) async throws {
        let profileName = arguments.option("--profile") ?? "dvd+r"
        let name = arguments.option("--name")
        let paths = arguments.remaining()
        guard !paths.isEmpty else { throw CLIError("simulate-burn needs at least one file or folder") }
        let profiles: [String: MediaProfile] = [
            "cd-r": .cdR, "cd-rw": .cdRW, "dvd-r": .dvdRSequential, "dvd+r": .dvdPlusR,
            "dvd+r-dl": .dvdPlusRDualLayer, "bd-r": .bdRSequential,
        ]
        guard let profile = profiles[profileName] else { throw CLIError("Unknown profile \(profileName)") }
        let image = try prepareImage(paths: paths, name: name ?? defaultName(for: paths))
        let simulator = SimulatedDrive(media: .init(profile: profile, capacityBlocks: 12_219_392))
        let drive = DiscDrive(transport: simulator)
        let report = try await drive.write(image) { progress in printProgress(progress) }
        print("")
        print("Simulated \(profile.name): \(report.writtenBlocks) blocks written, verified: \(report.verified)")
    }

    // MARK: - Helpers

    static func openDrive(_ number: String?) throws -> DiscDrive {
        let drives = IOKitDrives.list()
        guard !drives.isEmpty else { throw CLIError("No disc burners found.") }
        let index = (number.flatMap(Int.init) ?? 1) - 1
        guard drives.indices.contains(index) else { throw CLIError("There's no drive \(index + 1). Run `burnctl list`.") }
        return DiscDrive(transport: try IOKitTransport(drives[index]))
    }

    static func prepareImage(paths: [String], name: String, checksums: Bool = true,
                             udf: Bool = true, recovery: Int = 10) throws -> any ImageSource {
        if paths.count == 1, paths[0].lowercased().hasSuffix(".iso") {
            return try FileImageSource(url: URL(fileURLWithPath: paths[0]))
        }
        // Made as the drive asks for it, with no file in between. Recovery data needs every
        // file read first, so that's done now, before the drive is taken.
        let builder = try makeBuilder(paths: paths, name: name, checksums: checksums, udf: udf, recovery: recovery)
        warnIfRecoveryOmitted(builder)
        let image = try builder.image()
        if image.needsPreparing {
            print("Making recovery data…")
            var shown = -1
            try image.prepare { fraction in
                let percent = Int(fraction * 100)
                if percent != shown, percent % 10 == 0 {
                    shown = percent
                    print("  \(percent)%")
                }
            }
        }
        return image
    }

    static func warnIfRecoveryOmitted(_ builder: ISOImageBuilder) {
        guard builder.recoveryOmitted else { return }
        print("Warning: more than \(ISOImageBuilder.recoveryFileLimit) files, so this disc gets no recovery data."
              + " Checksums still cover every file.")
    }

    /// `--recovery PERCENT`: PAR2 recovery data as a share of the file data, 0 for none.
    static func recoveryPercent(_ arguments: inout Arguments) throws -> Int {
        guard let text = arguments.option("--recovery") else { return 10 }
        guard let percent = Int(text), (0...100).contains(percent) else {
            throw CLIError("--recovery needs a percentage from 0 to 100")
        }
        return percent
    }

    /// A single folder's contents go at the root of the disc, as other disc tools do.
    /// Several paths are added as they are.
    static func makeBuilder(paths: [String], name: String, checksums: Bool = true,
                            udf: Bool = true, recovery: Int = 10) throws -> ISOImageBuilder {
        var builder = ISOImageBuilder(volumeName: name)
        builder.includesChecksums = checksums
        builder.includesUDF = udf
        builder.recoveryPercent = recovery
        builder.applicationName = "burnctl"
        var isDirectory: ObjCBool = false
        if paths.count == 1, FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDirectory),
           isDirectory.boolValue {
            try builder.addContents(of: URL(fileURLWithPath: paths[0]))
        } else {
            for path in paths {
                try builder.add(URL(fileURLWithPath: path))
            }
        }
        return builder
    }

    static func defaultName(for paths: [String]) -> String {
        guard let first = paths.first else { return "Untitled" }
        return URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent
    }

    static func describe(_ state: DriveState) -> String {
        switch state {
        case .noDisc:
            return "no disc"
        case .becomingReady:
            return "reading the disc…"
        case .disc(let disc):
            let free = formatBytes(disc.freeBytes)
            if disc.isUnfinished {
                return disc.writability == .needsErase
                    ? "\(disc.profile.name) with an unfinished burn (erase it to reuse it)"
                    : "\(disc.profile.name) with an unfinished burn (this version can't finish it)"
            }
            switch disc.writability {
            case .blank: return "blank \(disc.profile.name), \(free) free"
            case .needsErase: return "\(disc.profile.name) with \(formatBytes(disc.usedBytes)) of data on it (erase it, or burn with --overwrite)"
            case .appendable: return "\(disc.profile.name) with data on it and \(free) free (adding sessions comes later)"
            case .unsupported: return "blank \(disc.profile.name), which this version can't write yet"
            case .notWritable: return "\(disc.profile.name), already burned, \(formatBytes(disc.usedBytes)) used"
            }
        }
    }

    private static let phaseClock = PhaseClock()

    static func printProgress(_ progress: WriteProgress) {
        let elapsed = phaseClock.elapsed(in: progress.phase)
        let label: String
        switch progress.phase {
        case .preparing: label = "Preparing"
        case .erasing: label = "Erasing"
        case .writing: label = "Writing"
        case .closing: label = "Closing the disc"
        case .verifying: label = "Verifying"
        }
        var text = progress.isIndeterminate ? "\(label)…" : "\(label) " + String(format: "%5.1f%%", progress.fraction * 100)
        if progress.phase == .closing {
            // Hardware run 17: a DVD-RW's progress reached 100% after 4 minutes, then the drive
            // took 3 more to finish with no further progress.
            if !progress.isIndeterminate && progress.fraction >= 1 { text = "Closing the disc: finishing up" }
            text += String(format: "  %d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
        }
        printStatusLine(text)
    }

    /// Rewrites the current terminal line, padding so nothing from a longer earlier line is left behind.
    static func printStatusLine(_ text: String) {
        let padded = text.padding(toLength: max(text.count, 40), withPad: " ", startingAt: 0)
        FileHandle.standardOutput.write(Data(("\r" + padded).utf8))
    }

    static func confirm(_ prompt: String) -> Bool {
        FileHandle.standardOutput.write(Data(prompt.utf8))
        return readLine()?.lowercased() == "yes"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func defaultLogPath() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory.appendingPathComponent("burnctl-\(stamp).log").path
    }

    @discardableResult
    static func writeLog(_ log: CommandLog, to path: String?) throws -> String? {
        guard let path else { return nil }
        try log.render().write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Minimal argument parsing: options take a value, flags don't, the rest are paths.
struct Arguments {
    private var items: [String]

    init(_ items: [String]) {
        self.items = items
    }

    mutating func next() -> String? {
        items.isEmpty ? nil : items.removeFirst()
    }

    mutating func option(_ name: String) -> String? {
        guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
        let value = items[index + 1]
        items.removeSubrange(index...(index + 1))
        return value
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = items.firstIndex(of: name) else { return false }
        items.remove(at: index)
        return true
    }

    func remaining() -> [String] {
        items
    }
}

/// How long the current write phase has been running, for the status line.
final class PhaseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var phase: WritePhase?
    private var started = Date()

    func elapsed(in current: WritePhase) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if phase != current {
            phase = current
            started = Date()
        }
        return Date().timeIntervalSince(started)
    }
}

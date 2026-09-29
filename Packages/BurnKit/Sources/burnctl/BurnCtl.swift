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
      burnctl make-iso PATH... --output FILE [--name NAME]
      burnctl burn PATH... [--drive N] [--name NAME] [--simulate] [--no-verify] [--eject] [--yes] [--log FILE]
      burnctl erase [--drive N] [--yes] [--log FILE]
      burnctl eject [--drive N]
      burnctl simulate-burn PATH... [--profile cd-r|cd-rw|dvd-r|dvd+r|dvd+r-dl|bd-r] [--name NAME]

    PATH is a file or folder to put on the disc, or a single .iso image to burn as it is.
    A single folder's contents go at the root of the disc, which is named after the folder.
    Drives are numbered from 1, in the order `burnctl list` shows them.
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
            case "eject": try await eject(&arguments)
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
        let paths = arguments.remaining()
        guard !paths.isEmpty else { throw CLIError("make-iso needs at least one file or folder") }
        let name = nameOption ?? defaultName(for: paths)
        let blocks = try buildImage(paths: paths, name: name, output: URL(fileURLWithPath: output))
        print("Wrote \(output): \(blocks) blocks (\(formatBytes(Int64(blocks) * 2048)))")
    }

    static func burn(_ arguments: inout Arguments) async throws {
        let driveNumber = arguments.option("--drive")
        let name = arguments.option("--name")
        let simulate = arguments.flag("--simulate")
        let verify = !arguments.flag("--no-verify")
        let eject = arguments.flag("--eject")
        let yes = arguments.flag("--yes")
        let logPath = arguments.option("--log")
        let paths = arguments.remaining()
        guard !paths.isEmpty else { throw CLIError("burn needs at least one file or folder") }

        let drive = try openDrive(driveNumber)
        let image = try prepareImage(paths: paths, name: name ?? defaultName(for: paths))
        print("Image: \(image.blockCount) blocks (\(formatBytes(Int64(image.blockCount) * 2048)))")

        let state = try await drive.state()
        print("Disc:  \(describe(state))")
        guard case .disc(let disc) = state, disc.writability == .blank else {
            throw CLIError("The disc in the drive can't be written. Insert a blank disc.")
        }
        if !yes {
            let action = simulate ? "Simulate burning" : "Burn"
            guard confirm("\(action) \(disc.profile.name)? This can't be undone on write-once discs. Type yes to continue: ") else {
                print("Cancelled.")
                return
            }
        }

        let started = Date()
        do {
            let report = try await drive.write(image, options: WriteOptions(simulate: simulate, verify: verify,
                                                                          ejectWhenDone: eject)) { progress in
                printProgress(progress)
            }
            print("")
            var outcome = report.verified ? "Written and verified" : (report.simulated ? "Simulated burn finished" : "Written, not verified")
            outcome += String(format: " in %.0f seconds.", Date().timeIntervalSince(started))
            print(outcome)
            try writeLog(drive.log, to: logPath)
        } catch {
            print("")
            let path = try writeLog(drive.log, to: logPath ?? defaultLogPath())
            printError("\(error)")
            if let path { printError("Diagnostic log: \(path)") }
            exit(1)
        }
    }

    static func erase(_ arguments: inout Arguments) async throws {
        let drive = try openDrive(arguments.option("--drive"))
        let yes = arguments.flag("--yes")
        let logPath = arguments.option("--log")
        let state = try await drive.state()
        print("Disc: \(describe(state))")
        if !yes {
            guard confirm("Erase this disc? Everything on it will be lost. Type yes to continue: ") else {
                print("Cancelled.")
                return
            }
        }
        do {
            printStatusLine("Erasing…")
            try await drive.quickErase { fraction in
                if let fraction {
                    printStatusLine("Erasing " + String(format: "%5.1f%%", fraction * 100))
                }
            }
            print("")
            print("Erased.")
            try writeLog(drive.log, to: logPath)
        } catch {
            let path = try writeLog(drive.log, to: logPath ?? defaultLogPath())
            printError("\(error)")
            if let path { printError("Diagnostic log: \(path)") }
            exit(1)
        }
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

    static func prepareImage(paths: [String], name: String) throws -> any ImageSource {
        if paths.count == 1, paths[0].lowercased().hasSuffix(".iso") {
            return try FileImageSource(url: URL(fileURLWithPath: paths[0]))
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("burnctl-\(UUID().uuidString).iso")
        print("Building the disc image…")
        _ = try buildImage(paths: paths, name: name, output: output)
        return try FileImageSource(url: output)
    }

    /// A single folder's contents go at the root of the disc, as other disc tools do.
    /// Several paths are added as they are.
    static func buildImage(paths: [String], name: String, output: URL) throws -> Int {
        var builder = ISOImageBuilder(volumeName: name)
        var isDirectory: ObjCBool = false
        if paths.count == 1, FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDirectory),
           isDirectory.boolValue {
            try builder.addContents(of: URL(fileURLWithPath: paths[0]))
        } else {
            for path in paths {
                try builder.add(URL(fileURLWithPath: path))
            }
        }
        return try builder.write(to: output)
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
            switch disc.writability {
            case .blank: return "blank \(disc.profile.name), \(free) free"
            case .needsErase: return "\(disc.profile.name) with data on it (erase it to reuse it)"
            case .appendable: return "\(disc.profile.name) with data on it and \(free) free (adding sessions comes later)"
            case .unsupported: return "blank \(disc.profile.name), which this version can't write yet"
            case .notWritable: return "\(disc.profile.name), closed"
            }
        }
    }

    static func printProgress(_ progress: WriteProgress) {
        let label: String
        switch progress.phase {
        case .preparing: label = "Preparing"
        case .writing: label = "Writing"
        case .closing: label = "Closing the disc"
        case .verifying: label = "Verifying"
        }
        if progress.isIndeterminate {
            printStatusLine("\(label)…")
        } else {
            printStatusLine("\(label) " + String(format: "%5.1f%%", progress.fraction * 100))
        }
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

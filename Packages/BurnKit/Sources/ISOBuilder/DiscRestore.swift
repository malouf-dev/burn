import Foundation

/// What restoring a disc did.
public struct RestoreReport: Sendable, Equatable {
    /// Whole files now in the destination.
    public var restored: [String] = []
    /// Files rebuilt from recovery data on the way.
    public var repaired: [String] = []
    /// Parts written into their files, such as "Season 2/E5.mkv, part 1 of 2".
    public var partsPlaced: [String] = []
    /// Cut files whose last missing part this disc held: they're whole now.
    public var completed: [String] = []
    /// Cut files still waiting for parts on other discs.
    public var waiting: [String] = []
    /// Files that still failed their checksum after repair. They're left in `kept`, not restored.
    public var damaged: [String] = []
    public var kept: URL?
    /// For a disc of a set: its name, this disc's number, how many there are, and which of them
    /// have been restored into this destination so far.
    public var setName: String?
    public var disc: Int?
    public var discCount: Int?
    public var discsRestored: [Int] = []

    public var isComplete: Bool { damaged.isEmpty }
}

/// Which disc of a set a disc is, from its `.burn/set.json`.
public struct DiscSetInfo: Sendable, Hashable {
    public let name: String
    public let disc: Int
    public let discCount: Int
}

/// Copies a disc's files back into a folder, checked and repaired (decision D16).
///
/// The disc is repaired into a hidden folder inside the destination (or copied, if it has no
/// recovery data), each copy is checked against `SHA256SUMS`, and then whole files are moved
/// into place and parts of cut files are written into their files at their offsets. Discs of
/// a set can be restored in any order; `.burn-restore.json` in the destination remembers which
/// discs and parts are in.
public enum DiscRestore {
    static let stateName = ".burn-restore.json"

    /// The set a disc belongs to, or nil for a disc on its own.
    public static func setInfo(at root: URL) -> DiscSetInfo? {
        manifest(at: root).map { DiscSetInfo(name: $0.name, disc: $0.thisDisc, discCount: $0.discCount) }
    }

    static func manifest(at root: URL) -> DiscSetManifest? {
        let url = root.appendingPathComponent(DiscChecksums.folderName).appendingPathComponent("set.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DiscSetManifest.self, from: $0) }
    }

    /// Blocks until done, so call it off the main thread. Throws `CancellationError` if the
    /// calling task is cancelled.
    public static func restore(root: URL, into destination: URL,
                               progress: @Sendable (Double) -> Void = { _ in }) throws -> RestoreReport {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".burn-restore-\(UUID().uuidString)", isDirectory: true)
        var report = RestoreReport()

        // 1. Copy the disc, repairing what the recovery data can.
        if RecoveryRepair.hasRecovery(at: root) {
            let repair = try RecoveryRepair.repair(root: root, into: staging) { progress($0 * 0.8) }
            report.repaired = repair.repaired
        } else {
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            for (path, entry) in ChecksumVerifier.filesOnDisc(root) {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: entry.url, to: target)
            }
            let burn = root.appendingPathComponent(DiscChecksums.folderName)
            try manager.copyItem(at: burn, to: staging.appendingPathComponent(DiscChecksums.folderName))
            progress(0.8)
        }

        // 2. Check every copy.
        let check = try ChecksumVerifier.verify(root: staging) { state in
            guard state.totalBytes > 0 else { return }
            progress(0.8 + 0.15 * Double(state.checkedBytes) / Double(state.totalBytes))
        }
        report.damaged = (check.changed + check.missing + check.unreadable).sorted()

        // 3. Put each good file, or part, in its place.
        let manifest = Self.manifest(at: root)
        let thisDisc = manifest?.discs.first { $0.number == manifest?.thisDisc }
        var parts: [String: DiscSetManifest.FileEntry] = [:]
        for entry in thisDisc?.files ?? [] {
            if let partPath = entry.partPath { parts[partPath.precomposedStringWithCanonicalMapping] = entry }
            if entry.folder == true {
                try manager.createDirectory(at: try place(entry.path, in: destination), withIntermediateDirectories: true)
            }
        }
        var state = RestoreState.load(destination)
        var setState = manifest.map { state.sets[$0.id] ?? RestoreState.SetState(name: $0.name, discCount: $0.discCount) }
        for path in check.matched {
            try Task.checkCancellation()
            let staged = staging.appendingPathComponent(path)
            if let entry = parts[path.precomposedStringWithCanonicalMapping], let part = entry.part,
               let offset = entry.offset {
                let target = try place(entry.path, in: destination)
                try write(staged, into: target, at: offset)
                let count = entry.parts ?? part
                report.partsPlaced.append("\(entry.path), part \(part) of \(count)")
                var placed = Set(setState?.parts[entry.path] ?? [])
                placed.insert(part)
                setState?.parts[entry.path] = placed.sorted()
                if placed.count == count {
                    report.completed.append(entry.path)
                } else {
                    report.waiting.append(entry.path)
                }
            } else {
                let target = try place(path, in: destination)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.moveItem(at: staged, to: target)
                report.restored.append(path)
            }
        }

        if let manifest, var setState {
            setState.discs = Array(Set(setState.discs + [manifest.thisDisc])).sorted()
            state.sets[manifest.id] = setState
            try state.save(destination)
            report.setName = manifest.name
            report.disc = manifest.thisDisc
            report.discCount = manifest.discCount
            report.discsRestored = setState.discs
        }

        // 4. Keep only what didn't restore, so it can be looked at.
        if report.damaged.isEmpty {
            try? manager.removeItem(at: staging)
        } else {
            report.kept = staging
        }
        progress(1)
        return report
    }

    /// Where a path from the disc goes in the destination. Refuses paths that would leave it.
    private static func place(_ path: String, in destination: URL) throws -> URL {
        let components = path.split(separator: "/")
        guard !path.hasPrefix("/"), !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw RecoveryRepairError.unsafeName(path)
        }
        return destination.appendingPathComponent(path)
    }

    /// Writes a part into its file at its offset, making the file if it isn't there yet.
    private static func write(_ part: URL, into target: URL, at offset: UInt64) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: target.path) {
            guard manager.createFile(atPath: target.path, contents: nil) else { throw ISOBuilderError.unreadable(target.path) }
        }
        let reader = try FileHandle(forReadingFrom: part)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: target)
        defer { try? writer.close() }
        try writer.seek(toOffset: offset)
        while true {
            try Task.checkCancellation()
            let chunk = try reader.readBytes(1 << 20)
            if chunk.isEmpty { break }
            try writer.writeBytes(chunk)
        }
        try manager.removeItem(at: part)
    }
}

/// `.burn-restore.json` in a restore's destination: which discs and parts of each set are in.
struct RestoreState: Codable, Sendable, Equatable {
    struct SetState: Codable, Sendable, Equatable {
        var name: String
        var discCount: Int
        var discs: [Int] = []
        /// The part numbers placed so far, by the cut file's path.
        var parts: [String: [Int]] = [:]
    }

    var sets: [String: SetState] = [:]

    static func load(_ destination: URL) -> RestoreState {
        let url = destination.appendingPathComponent(DiscRestore.stateName)
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(RestoreState.self, from: $0) }
            ?? RestoreState()
    }

    func save(_ destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: destination.appendingPathComponent(DiscRestore.stateName), options: .atomic)
    }
}

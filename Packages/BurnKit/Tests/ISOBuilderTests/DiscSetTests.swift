import CryptoKit
import Foundation
import Testing
@testable import ISOBuilder

@Suite("Disc sets")
struct DiscSetTests {
    /// Bytes that differ everywhere, so a part out of place would show.
    static func bytes(_ count: Int, seed: UInt32) -> [UInt8] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
    }

    /// A small "show": two seasons of files of a few MiB, an empty folder and a note.
    func makeShow() throws -> (URL, [String: [UInt8]]) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("set-\(UUID().uuidString)")
        let show = base.appendingPathComponent("Show")
        var expected: [String: [UInt8]] = [:]
        let files: [(String, Int)] = [
            ("Season 1/E1.bin", 3 * 1_048_576 + 100),
            ("Season 1/E2.bin", 5 * 1_048_576 + 7),
            ("Season 2/E1.bin", 4 * 1_048_576),
            ("Season 2/notes.txt", 300),
        ]
        for (index, (path, size)) in files.enumerated() {
            let url = show.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let content = Self.bytes(size, seed: UInt32(index + 1))
            try Data(content).write(to: url)
            expected["Show/" + path] = content
        }
        try FileManager.default.createDirectory(at: show.appendingPathComponent("Extras"), withIntermediateDirectories: true)
        return (show, expected)
    }

    func plan(_ show: URL, blocks: Int = 3_000) throws -> DiscSetPlan {
        try DiscSetPlan.make(urls: [show], name: "Show", discSize: DiscSize(name: "Test", blocks: blocks),
                             minimumCut: DiscSetPlan.cutUnit, date: Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// Each disc's files, read back from its image.
    func burn(_ plan: DiscSetPlan, into folder: URL) throws -> [[String: [UInt8]]] {
        try plan.discs.map { disc in
            let url = folder.appendingPathComponent("disc\(disc.number).iso")
            let blocks = try plan.builder(forDisc: disc.number).write(to: url)
            #expect(blocks == disc.blocks)
            return try UDFReader(url: url).files()
        }
    }

    /// Writes a disc's files into a folder, as if it were mounted there.
    func materialize(_ files: [String: [UInt8]], at root: URL) throws -> URL {
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
        }
        return root
    }

    @Test func restoringEachDiscPutsTheSetBackTogether() throws {
        let (show, expected) = try makeShow()
        let plan = try plan(show)
        let base = show.deletingLastPathComponent()
        let discs = try burn(plan, into: base)
        let destination = base.appendingPathComponent("Restored by Burn")
        var completed: [String] = []
        var last: RestoreReport?
        // Out of order on purpose.
        for number in discs.indices.reversed() {
            let root = try materialize(discs[number], at: base.appendingPathComponent("mounted\(number + 1)"))
            let report = try DiscRestore.restore(root: root, into: destination)
            #expect(report.isComplete)
            #expect(report.disc == number + 1)
            #expect(report.discCount == discs.count)
            // The Restore view's row of discs for the set.
            let sets = DiscRestore.progress(in: destination)
            #expect(sets.count == 1)
            let progress = try #require(sets.first)
            #expect(progress.id == DiscRestore.setInfo(at: root)?.id)
            #expect(progress.discCount == discs.count)
            #expect(progress.missing == Array(1..<(number + 1)))
            #expect(progress.isComplete == (number == 0))
            completed += report.completed
            last = report
        }
        for (path, bytes) in expected {
            #expect([UInt8](try Data(contentsOf: destination.appendingPathComponent(path))) == bytes, "\(path)")
        }
        let cut = Set(plan.discs.flatMap(\.pieces).filter { $0.part != nil }.map(\.path))
        #expect(Set(completed) == cut)
        #expect(last?.discsRestored == Array(1...discs.count))
        // Nothing left over but the record of what's been restored.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(Set(leftovers) == ["Show", DiscRestore.stateName])
        #expect(try FolderComparison.compare(original: show, copy: destination.appendingPathComponent("Show")).isIdentical)
    }

    @Test func aSavedSetCarriesOnAsTheSameSet() throws {
        let (show, expected) = try makeShow()
        let plan = try plan(show)
        #expect(plan.discs.count >= 3)
        let base = show.deletingLastPathComponent()
        // Disc 1 is burned, then the app quits and reads back the set it saved.
        let saved = try SavedDiscSet(data: SavedDiscSet(plan: plan, nextDisc: 2).encoded())
        #expect(saved.nextDisc == 2)
        #expect(saved.plan.id == plan.id)
        #expect(saved.plan.created == plan.created)
        // Every piece, with its source, offset and file dates, exactly as planned.
        #expect(saved.plan.discs.map(\.pieces) == plan.discs.map(\.pieces))
        #expect(saved.plan.sources == [show])

        // Every disc made from the saved plan holds the same files as the original, given the same
        // burn date: same parts, same checksums and recovery data, and set.json with the same set id.
        // The images themselves differ only in the root folder's time, taken when each is made.
        let burnDate = Date(timeIntervalSince1970: 1_790_100_000)
        var discs: [[String: [UInt8]]] = []
        for disc in plan.discs {
            let before = base.appendingPathComponent("before\(disc.number).iso")
            let after = base.appendingPathComponent("after\(disc.number).iso")
            _ = try plan.builder(forDisc: disc.number).write(to: before, date: burnDate)
            _ = try saved.plan.builder(forDisc: disc.number).write(to: after, date: burnDate)
            let files = (before: try UDFReader(url: before).files(), after: try UDFReader(url: after).files())
            #expect(files.before == files.after, "disc \(disc.number)")
            // Disc 1 from before the quit, the rest from after.
            discs.append(disc.number < saved.nextDisc ? files.before : files.after)
        }

        let destination = base.appendingPathComponent("Restored by Burn")
        for (index, files) in discs.enumerated() {
            let root = try materialize(files, at: base.appendingPathComponent("mounted\(index + 1)"))
            #expect(try DiscRestore.restore(root: root, into: destination).isComplete)
        }
        #expect(DiscRestore.progress(in: destination).first?.isComplete == true)
        for (path, bytes) in expected {
            #expect([UInt8](try Data(contentsOf: destination.appendingPathComponent(path))) == bytes, "\(path)")
        }
        #expect(try FolderComparison.compare(original: show, copy: destination.appendingPathComponent("Show")).isIdentical)
    }

    @Test func aSetFindsFilesThatAreGoneOrChanged() throws {
        let (show, _) = try makeShow()
        let plan = try plan(show)
        let all = 1...plan.discs.count
        #expect(plan.fileProblems(onDiscs: all).isEmpty)

        let gone = "Show/Season 2/notes.txt"
        let changed = "Show/Season 1/E1.bin"
        let folder = "Show/Extras"
        let base = show.deletingLastPathComponent()
        try FileManager.default.removeItem(at: base.appendingPathComponent(gone))
        try FileManager.default.removeItem(at: base.appendingPathComponent(folder))
        let handle = try FileHandle(forWritingTo: base.appendingPathComponent(changed))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let problems = plan.fileProblems(onDiscs: all)
        #expect(Set(problems) == [DiscSetPlan.FileProblem(path: gone, isMissing: true),
                                  DiscSetPlan.FileProblem(path: folder, isMissing: true),
                                  DiscSetPlan.FileProblem(path: changed, isMissing: false)])
        // Each file counts once, even when it is cut across two discs, and only the discs asked
        // about are checked.
        #expect(problems.count == 3)
        for disc in plan.discs {
            let expected = Set(disc.pieces.map(\.path)).intersection([gone, folder, changed])
            #expect(Set(plan.fileProblems(onDiscs: disc.number...disc.number).map(\.path)) == expected)
        }
    }

    @Test func aSavedSetMustNameOneOfItsDiscs() throws {
        let (show, _) = try makeShow()
        let plan = try plan(show)
        let data = try SavedDiscSet(plan: plan, nextDisc: plan.discs.count + 1).encoded()
        #expect(throws: DecodingError.self) { try SavedDiscSet(data: data) }
    }

    @Test func restoreRepairsDamageOnTheWay() throws {
        let (show, expected) = try makeShow()
        let plan = try plan(show)
        let base = show.deletingLastPathComponent()
        var files = try burn(plan, into: base)[0]
        let candidates = files.keys.filter { !$0.hasPrefix(".burn/") && files[$0, default: []].count > 5_000 }.sorted()
        let damaged = try #require(candidates.first)
        files[damaged]?[4_000] ^= 0xFF
        let root = try materialize(files, at: base.appendingPathComponent("damaged"))
        let destination = base.appendingPathComponent("Repaired")
        let report = try DiscRestore.restore(root: root, into: destination)
        #expect(report.isComplete)
        #expect(report.repaired == [damaged])
        let piece = try #require(plan.discs[0].pieces.first { $0.discPath == damaged })
        let restored = [UInt8](try Data(contentsOf: destination.appendingPathComponent(piece.path)))
        let original = try #require(expected[piece.path])
        #expect(Array(restored.prefix(Int(piece.length))) == Array(original[Int(piece.offset)..<Int(piece.offset + piece.length)]))
    }

    @Test func discsAreFullAndPartsRejoin() throws {
        let (show, expected) = try makeShow()
        let plan = try plan(show)
        #expect(plan.discs.count >= 2)
        for disc in plan.discs {
            #expect(disc.blocks <= 3_000)
        }
        // A disc that ends with a cut is full to within a MiB and its recovery data.
        for disc in plan.discs.dropLast() where disc.pieces.last?.part != nil {
            #expect(3_000 - disc.blocks < 600, "disc \(disc.number) has \(3_000 - disc.blocks) blocks free")
        }

        let discs = try burn(plan, into: show.deletingLastPathComponent())
        var rejoined: [String: [UInt8]] = [:]
        for (disc, files) in zip(plan.discs, discs) {
            for piece in disc.pieces where !piece.isDirectory {
                let bytes = try #require(files[piece.discPath], "\(piece.discPath) on disc \(disc.number)")
                #expect(UInt64(bytes.count) == piece.length)
                var whole = rejoined[piece.path] ?? []
                #expect(UInt64(whole.count) == piece.offset, "\(piece.path) part \(piece.part ?? 0) out of order")
                whole += bytes
                rejoined[piece.path] = whole
            }
            // Every file on the disc, parts included, matches its checksum.
            let sums = try DiscChecksums.parse(String(decoding: try #require(files[".burn/SHA256SUMS"]), as: UTF8.self))
            #expect(sums.count == disc.pieces.filter { !$0.isDirectory }.count)
            for entry in sums {
                let bytes = try #require(files[entry.path])
                #expect(entry.digest == SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined())
            }
        }
        #expect(rejoined == expected)
        #expect(plan.discs.flatMap(\.pieces).contains { $0.part == 2 })
    }

    @Test func everyDiscListsTheWholeSet() throws {
        let (show, _) = try makeShow()
        let plan = try plan(show)
        let discs = try burn(plan, into: show.deletingLastPathComponent())
        for (number, files) in discs.enumerated() {
            let manifest = try JSONDecoder().decode(DiscSetManifest.self, from: Data(try #require(files[".burn/set.json"])))
            #expect(manifest.thisDisc == number + 1)
            #expect(manifest.discCount == plan.discs.count)
            #expect(manifest.discs.map(\.volumeName) == plan.discs.map { plan.volumeName(forDisc: $0.number) })
            #expect(manifest.discs.flatMap(\.files).contains { $0.path == "Show/Extras" && $0.folder == true })
            #expect(files[".burn/restore.sh"] != nil)
            #expect(files[".burn/README.txt"] != nil)
        }
        #expect(plan.volumeName(forDisc: 2) == "Show 2 of \(plan.discs.count)")
    }

    @Test func restoreScriptsPutTheSetBackTogether() throws {
        let (show, expected) = try makeShow()
        let plan = try plan(show)
        let base = show.deletingLastPathComponent()
        let discs = try burn(plan, into: base)
        let destination = base.appendingPathComponent("Restored")
        // Out of order on purpose: parts go into place wherever they fall.
        for number in discs.indices.reversed() {
            let root = base.appendingPathComponent("disc\(number + 1)")
            for (path, bytes) in discs[number] {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(bytes).write(to: url)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [root.appendingPathComponent(".burn/restore.sh").path, destination.path]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "restore.sh for disc \(number + 1)")
        }
        for (path, bytes) in expected {
            #expect([UInt8](try Data(contentsOf: destination.appendingPathComponent(path))) == bytes, "\(path)")
        }
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Show/Extras").path,
                                               isDirectory: &isFolder) && isFolder.boolValue)
    }

    @Test func aRestoreScriptStopsOnADamagedDisc() throws {
        let (show, _) = try makeShow()
        let plan = try plan(show)
        let base = show.deletingLastPathComponent()
        let files = try burn(plan, into: base)[0]
        let root = base.appendingPathComponent("damaged")
        for (path, var bytes) in files {
            if !path.hasPrefix(".burn/"), bytes.count > 10 { bytes[10] ^= 0xFF }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent(".burn/restore.sh").path, base.appendingPathComponent("Out").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
    }

    @Test func seasonsOn100GBDiscs() throws {
        // Eight 65 GB seasons as sparse files: they read as zeros but take no space.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("seasons-\(UUID().uuidString)")
        let show = base.appendingPathComponent("Series")
        var urls: [URL] = []
        for season in 1...8 {
            let folder = show.appendingPathComponent("Season \(season)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for episode in 1...10 {
                let url = folder.appendingPathComponent("S\(season)E\(episode).mkv")
                #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 6_500_000_000 + UInt64(episode) * 1_000_003)
                try handle.close()
            }
            urls.append(folder)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let size = try #require(DiscSize.standard.first { $0.name == "BD-R XL 100 GB" })
        let plan = try DiscSetPlan.make(urls: urls, name: "Series", discSize: size)
        // 520 GB of files with 10% recovery data: about 91 GB of files per disc.
        #expect(plan.discs.count == 6)
        for disc in plan.discs.dropLast() {
            #expect(disc.blocks <= size.blocks)
            // Within a MiB of file data, its recovery data and checksums.
            #expect(size.blocks - disc.blocks < 2_048)
        }
        let last = try #require(plan.discs.last)
        #expect(last.blocks < size.blocks)
        #expect(plan.lastDiscSize == DiscSize.smallest(holding: last.blocks))
        // Every byte is planned once, in order.
        let planned: UInt64 = plan.discs.flatMap(\.pieces).reduce(0) { $0 + $1.length }
        var total: UInt64 = 0
        for episode in 1...10 {
            total += 8 * (6_500_000_000 + UInt64(episode) * 1_000_003)
        }
        #expect(planned == total)
    }
}

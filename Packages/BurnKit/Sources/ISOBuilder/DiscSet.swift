import Foundation

/// A disc size to plan a disc set with (decision D16).
public struct DiscSize: Sendable, Hashable, Identifiable, Codable {
    public let name: String
    public let blocks: Int

    public var id: Int { blocks }
    public var bytes: Int64 { Int64(blocks) * 2048 }

    public init(name: String, blocks: Int) {
        self.name = name
        self.blocks = blocks
    }

    /// Common blank discs, smallest first, with the sizes drives report for them. When a blank
    /// disc is in the drive, its own size is the one to plan with.
    public static let standard: [DiscSize] = [
        DiscSize(name: "CD-R 700 MB", blocks: 359_844),
        DiscSize(name: "DVD±R 4.7 GB", blocks: 2_295_104),
        DiscSize(name: "DVD±R DL 8.5 GB", blocks: 4_171_712),
        DiscSize(name: "BD-R 25 GB", blocks: 12_219_392),
        DiscSize(name: "BD-R DL 50 GB", blocks: 24_438_784),
        DiscSize(name: "BD-R XL 100 GB", blocks: 48_878_592),
        DiscSize(name: "BD-R XL 128 GB", blocks: 62_500_864),
    ]

    /// The smallest standard disc that holds this many blocks.
    public static func smallest(holding blocks: Int) -> DiscSize? {
        standard.first { $0.blocks >= blocks }
    }
}

public enum DiscSetError: Error, Sendable, Equatable, CustomStringConvertible {
    case nothingToBurn
    /// Not even the disc's own structures and one part of a file fit.
    case discTooSmall

    public var description: String {
        switch self {
        case .nothingToBurn: return "There's nothing to burn."
        case .discTooSmall: return "That disc is too small to hold any of these files."
        }
    }
}

/// Files too big for one disc, spread over several (decision D16).
///
/// Files keep their order. Every disc but the last is filled to its last block: the file at the
/// edge is cut, to the nearest MiB, and the rest of it starts the next disc. The parts are named
/// `name.part1`, `name.part2` and so on, and rejoin with `cat`. Each disc is readable on its own,
/// with its own checksums and recovery data, and its `.burn` folder also holds `set.json`, which
/// lists the whole set, and `restore.sh` and `README.txt` for restoring without Burn.
public struct DiscSetPlan: Sendable, Codable {
    /// A file, an empty folder, or part of a file, on one disc.
    public struct Piece: Sendable, Hashable, Codable {
        struct Entry: Sendable, Hashable, Codable {
            let name: String
            let source: URL?
            let date: Date
            let isDirectory: Bool
            let size: UInt64
        }

        /// The folders above it, then itself, from the top of the disc down.
        let chain: [Entry]
        /// Where this piece starts in its file, and how long it is.
        public let offset: UInt64
        public let length: UInt64
        /// 1 for a cut file's first part, 2 for the next, and so on. Nil for anything whole.
        public let part: Int?

        public var name: String { chain[chain.count - 1].name }
        public var isDirectory: Bool { chain[chain.count - 1].isDirectory }
        /// The whole file's size.
        public var fileSize: UInt64 { chain[chain.count - 1].size }
        public var source: URL? { chain[chain.count - 1].source }

        /// The whole file's path on the disc, as UDF names it.
        public var path: String {
            chain.map { Names.udf($0.name, isDirectory: $0.isDirectory) }.joined(separator: "/")
        }

        /// This piece's own path on the disc: the file's, or its part's.
        public var discPath: String {
            guard let part else { return path }
            let folders = chain.dropLast().map { Names.udf($0.name, isDirectory: true) }
            return (folders + [Names.udf("\(name).part\(part)", isDirectory: false)]).joined(separator: "/")
        }

        var nameOnDisc: String { part.map { "\(name).part\($0)" } ?? name }
    }

    public struct Disc: Sendable, Codable {
        public let number: Int
        public let pieces: [Piece]
        /// The image's size in blocks.
        public let blocks: Int

        public var bytes: Int64 { Int64(blocks) * 2048 }
        /// Bytes of file data, parts included.
        public var fileBytes: UInt64 { pieces.reduce(0) { $0 + $1.length } }
    }

    public let name: String
    public let discSize: DiscSize
    public let discs: [Disc]
    public let id: UUID
    public let created: Date
    public let includesUDF: Bool
    public let recoveryPercent: Int
    public let applicationName: String

    /// Cuts fall on whole MiBs, so `dd` in `restore.sh` can place parts in large blocks.
    public static let cutUnit: UInt64 = 1 << 20
    /// A smaller file moves to the next disc whole rather than being cut.
    public static let defaultMinimumCut: UInt64 = 64 << 20

    /// The smallest standard disc the last disc fits on.
    public var lastDiscSize: DiscSize? {
        DiscSize.smallest(holding: discs.last?.blocks ?? 0)
    }

    /// The files and folders the set was planned from, in order.
    public var sources: [URL] {
        var seen = Set<URL>()
        return discs.flatMap(\.pieces).compactMap { $0.chain.first?.source }.filter { seen.insert($0).inserted }
    }

    /// Plans a set: `urls` are the files and folders to burn, in order, each at the top level.
    public static func make(urls: [URL], name: String, discSize: DiscSize, includesUDF: Bool = true,
                            recoveryPercent: Int = 10, applicationName: String = "Burn",
                            skipping: Set<String> = [".DS_Store"], minimumCut: UInt64 = defaultMinimumCut,
                            date: Date = Date()) throws -> DiscSetPlan {
        var leaves: [[Piece.Entry]] = []
        func walk(_ node: Node, above: [Piece.Entry]) {
            let entry = Piece.Entry(name: node.name, source: node.source, date: node.date,
                                    isDirectory: node.isDirectory, size: node.size)
            if node.isDirectory {
                if node.children.isEmpty { leaves.append(above + [entry]) }
                for child in node.children { walk(child, above: above + [entry]) }
            } else {
                leaves.append(above + [entry])
            }
        }
        for url in urls {
            let node = try ISOImageBuilder.scan(url, skipping: skipping)
            if node.name == DiscChecksums.folderName { continue }
            walk(node, above: [])
        }
        guard !leaves.isEmpty else { throw DiscSetError.nothingToBurn }

        let id = UUID()
        // set.json, restore.sh and README.txt depend on the plan, so the plan saves room for them
        // and is made again with more if they don't fit.
        var reserve = 64 * 1024
        while true {
            let groups = try assign(leaves, capacity: discSize.blocks, reserve: reserve, includesUDF: includesUDF,
                                    recoveryPercent: recoveryPercent, minimumCut: minimumCut)
            let draft = DiscSetPlan(name: name, discSize: discSize,
                                    discs: groups.enumerated().map { Disc(number: $0 + 1, pieces: $1, blocks: 0) },
                                    id: id, created: date, includesUDF: includesUDF,
                                    recoveryPercent: recoveryPercent, applicationName: applicationName)
            let discs = draft.discs.map { disc in
                Disc(number: disc.number, pieces: disc.pieces, blocks: draft.builder(forDisc: disc.number).blockCount())
            }
            if discs.allSatisfy({ $0.blocks <= discSize.blocks }) {
                return DiscSetPlan(name: name, discSize: discSize, discs: discs, id: id, created: date,
                                   includesUDF: includesUDF, recoveryPercent: recoveryPercent,
                                   applicationName: applicationName)
            }
            reserve *= 4
        }
    }

    /// Puts the files on discs. Each disc takes as many whole files as fit, then as much of the
    /// next as fits, unless that file is smaller than `minimumCut`.
    private static func assign(_ leaves: [[Piece.Entry]], capacity: Int, reserve: Int, includesUDF: Bool,
                               recoveryPercent: Int, minimumCut: UInt64) throws -> [[Piece]] {
        let placeholder = [(name: "set.json", content: [UInt8](repeating: 0x20, count: reserve))]
        func fits(_ pieces: [Piece]) -> Bool {
            var builder = ISOImageBuilder(volumeName: "Planning")
            builder.includesUDF = includesUDF
            builder.recoveryPercent = recoveryPercent
            builder.setTopLevel(topLevel(pieces))
            builder.burnExtras = placeholder
            return builder.blockCount() <= capacity
        }

        var discs: [[Piece]] = []
        var index = 0
        // Where the next disc starts within leaves[index], and that piece's part number.
        var offset: UInt64 = 0
        var part = 0
        while index < leaves.count {
            func whole(_ count: Int) -> [Piece] {
                (0..<count).map { step in
                    let chain = leaves[index + step]
                    if step == 0 && offset > 0 {
                        return Piece(chain: chain, offset: offset, length: chain[chain.count - 1].size - offset, part: part)
                    }
                    return Piece(chain: chain, offset: 0, length: chain[chain.count - 1].size, part: nil)
                }
            }
            // The most whole pieces that fit, by halving.
            var low = 0
            var high = leaves.count - index
            if fits(whole(high)) {
                discs.append(whole(high))
                break
            }
            guard fits([]) else { throw DiscSetError.discTooSmall }
            while high - low > 1 {
                let middle = (low + high) / 2
                if fits(whole(middle)) { low = middle } else { high = middle }
            }
            var disc = whole(low)

            // Then as much of the next file as fits, in whole MiBs short of its end.
            let next = index + low
            let chain = leaves[next]
            let entry = chain[chain.count - 1]
            let start = low == 0 ? offset : 0
            let partNumber = low == 0 && offset > 0 ? part : 1
            let remaining = entry.size - start
            var cut: UInt64 = 0
            if !entry.isDirectory, remaining > Self.cutUnit, remaining >= minimumCut || disc.isEmpty {
                var units: (low: UInt64, high: UInt64) = (0, (remaining - 1) / Self.cutUnit + 1)
                while units.high - units.low > 1 {
                    let middle = (units.low + units.high) / 2
                    let piece = Piece(chain: chain, offset: start, length: middle * Self.cutUnit, part: partNumber)
                    if fits(disc + [piece]) { units.low = middle } else { units.high = middle }
                }
                cut = units.low * Self.cutUnit
            }
            if cut > 0 {
                disc.append(Piece(chain: chain, offset: start, length: cut, part: partNumber))
                offset = start + cut
                part = partNumber + 1
            } else {
                guard !disc.isEmpty else { throw DiscSetError.discTooSmall }
                offset = start
                part = start > 0 ? partNumber : 0
            }
            index = next
            discs.append(disc)
        }
        return discs
    }

    /// The tree for a disc: each piece under copies of its folders.
    static func topLevel(_ pieces: [Piece]) -> [Node] {
        let root = Node(name: "", source: nil, isDirectory: true, size: 0, date: Date())
        for piece in pieces {
            var parent = root
            for entry in piece.chain.dropLast() {
                parent = folder(entry, in: parent)
            }
            let leaf = piece.chain[piece.chain.count - 1]
            if leaf.isDirectory {
                _ = folder(leaf, in: parent)
                continue
            }
            let node = Node(name: piece.nameOnDisc, source: leaf.source, isDirectory: false, size: piece.length,
                            date: leaf.date)
            node.sourceOffset = piece.offset
            if piece.part != nil { node.partOf = leaf.size }
            parent.children.append(node)
        }
        return root.children
    }

    private static func folder(_ entry: Piece.Entry, in parent: Node) -> Node {
        if let existing = parent.children.first(where: { $0.isDirectory && $0.name == entry.name }) {
            return existing
        }
        let node = Node(name: entry.name, source: entry.source, isDirectory: true, size: 0, date: entry.date)
        parent.children.append(node)
        return node
    }

    // MARK: - Each disc

    /// "Name 2 of 6", within the 63 characters a disc name may have.
    public func volumeName(forDisc number: Int) -> String {
        let suffix = " \(number) of \(discs.count)"
        var base = ""
        for character in name {
            if base.utf16.count + String(character).utf16.count + suffix.utf16.count > 63 { break }
            base.append(character)
        }
        return base + suffix
    }

    /// The builder for one disc, numbered from 1, with its part of the set and its `.burn` extras.
    public func builder(forDisc number: Int) -> ISOImageBuilder {
        var builder = ISOImageBuilder(volumeName: volumeName(forDisc: number))
        builder.includesUDF = includesUDF
        builder.recoveryPercent = recoveryPercent
        builder.applicationName = applicationName
        builder.setTopLevel(Self.topLevel(discs[number - 1].pieces))
        builder.burnExtras = [
            (name: "set.json", content: manifest(forDisc: number).encoded()),
            (name: "restore.sh", content: Array(restoreScript(forDisc: number).utf8)),
            (name: "README.txt", content: Array(readme(forDisc: number).utf8)),
        ]
        return builder
    }

    /// How many parts each cut file has, by its path.
    private var partCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for disc in discs {
            for piece in disc.pieces where piece.part != nil { counts[piece.path, default: 0] += 1 }
        }
        return counts
    }

    func manifest(forDisc number: Int) -> DiscSetManifest {
        let counts = partCounts
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return DiscSetManifest(
            name: name, id: id.uuidString, created: formatter.string(from: created), application: applicationName,
            discSize: discSize.name, discCount: discs.count, thisDisc: number,
            discs: discs.map { disc in
                DiscSetManifest.DiscEntry(number: disc.number, volumeName: volumeName(forDisc: disc.number),
                                          files: disc.pieces.map { piece in
                    if piece.isDirectory { return DiscSetManifest.FileEntry(path: piece.path, folder: true) }
                    guard let part = piece.part else { return DiscSetManifest.FileEntry(path: piece.path, size: piece.fileSize) }
                    return DiscSetManifest.FileEntry(path: piece.path, size: piece.fileSize, part: part,
                                                     parts: counts[piece.path], offset: piece.offset,
                                                     length: piece.length, partPath: piece.discPath)
                })
            })
    }

    /// A POSIX shell script that restores this disc into a folder, without Burn.
    func restoreScript(forDisc number: Int) -> String {
        let disc = discs[number - 1]
        let counts = partCounts
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let label = "disc \(number) of \(discs.count)"
        var lines = [
            "#!/bin/sh",
            "# Restores \(label) of the disc set \(quoted(name)), made by \(applicationName).",
            "# Usage: sh restore.sh DESTINATION_FOLDER",
            "# Restore every disc of the set into the same folder, in any order. A file cut",
            "# across discs is whole once each disc that holds a part of it is restored.",
            "set -eu",
            "if [ \"$#\" -ne 1 ]; then",
            "  echo \"Usage: sh restore.sh DESTINATION_FOLDER\" >&2",
            "  exit 2",
            "fi",
            "disc=$(cd \"$(dirname \"$0\")/..\" && pwd)",
            "mkdir -p \"$1\"",
            "dest=$(cd \"$1\" && pwd)",
            "echo \"Checking every file on \(label) against its checksum. This reads the whole disc.\"",
            "if command -v shasum >/dev/null 2>&1; then check=\"shasum -a 256 -c\"; else check=\"sha256sum -c\"; fi",
            "if ! (cd \"$disc\" && $check .burn/SHA256SUMS); then",
            "  echo \"Some files don't match their checksums. See .burn/README.txt to repair them first.\" >&2",
            "  exit 1",
            "fi",
            "copy() {",
            "  mkdir -p \"$dest/$(dirname \"$1\")\"",
            "  cp -p \"$disc/$1\" \"$dest/$1\"",
            "}",
            "# A part goes into its file at its place: the part on the disc, the file, its offset in MiB.",
            "place() {",
            "  mkdir -p \"$dest/$(dirname \"$2\")\"",
            "  dd if=\"$disc/$1\" of=\"$dest/$2\" bs=1048576 seek=\"$3\" conv=notrunc 2>/dev/null",
            "}",
            "echo \"Copying \(label) to $dest\"",
        ]
        var notes: [String] = []
        for piece in disc.pieces {
            if piece.isDirectory {
                lines.append("mkdir -p \"$dest\"/\(quoted(piece.path))")
            } else if let part = piece.part {
                lines.append("place \(quoted(piece.discPath)) \(quoted(piece.path)) \(piece.offset / Self.cutUnit)")
                notes.append("\(piece.path): part \(part) of \(counts[piece.path] ?? part) is in place.")
            } else {
                lines.append("copy \(quoted(piece.path))")
            }
        }
        lines.append("echo \"Disc \(number) of \(discs.count) is restored.\"")
        for note in notes {
            lines.append("echo \(quoted(note))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the set is and how to restore it, in plain words.
    func readme(forDisc number: Int) -> String {
        let volume = volumeName(forDisc: number)
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "en_AU")
        var text = """
        \(name), disc \(number) of \(discs.count)
        Made by \(applicationName) on \(formatter.string(from: created)).

        This disc is one of a set of \(discs.count). The files go across the discs in order, and
        each disc is readable on its own. A file too big for the space left on a disc is cut into
        parts named like "name.part1" and "name.part2", on discs that follow each other.
        set.json, in this folder, lists what's on every disc of the set.

        Restoring without Burn, on macOS or Linux: run this for each disc of the set, in any
        order, into the same folder. It checks the disc, copies its files and puts each part in
        its place in its file.

            sh "/Volumes/\(volume)/.burn/restore.sh" ~/Restored

        By hand: copy the files, then join each cut file's parts in order.

            macOS and Linux:  cat "name.part1" "name.part2" > "name"
            Windows:          copy /b "name.part1" + "name.part2" "name"

        Checking: SHA256SUMS, in this folder, has a checksum for every file on this disc, parts
        included. On macOS:

            cd "/Volumes/\(volume)" && shasum -a 256 -c .burn/SHA256SUMS

        """
        if recoveryPercent > 0 {
            text += """

            Repairing: the PAR2 files in this folder can rebuild damaged files on this disc, with
            Burn's Repair or any PAR2 tool. With par2cmdline, copy the disc's files to a folder,
            then in that folder run:

                par2 repair .burn/recovery.par2

            """
        }
        return text
    }
}

/// A set part way through, kept on the Mac so it carries on after the app quits or crashes. The
/// plan comes back exactly as it was, with its id and dates, so the discs still to burn belong to
/// the same set as those already burned.
public struct SavedDiscSet: Codable, Sendable {
    public let plan: DiscSetPlan
    /// The disc to burn next, from 1.
    public let nextDisc: Int

    public init(plan: DiscSetPlan, nextDisc: Int) {
        self.plan = plan
        self.nextDisc = nextDisc
    }

    /// Reads a saved set, refusing one whose next disc isn't in its plan.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard plan.discs.indices.contains(nextDisc - 1) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Disc \(nextDisc) isn't in the set"))
        }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// `.burn/set.json` on each disc of a set (D16).
struct DiscSetManifest: Codable, Sendable, Equatable {
    struct DiscEntry: Codable, Sendable, Equatable {
        var number: Int
        var volumeName: String
        var files: [FileEntry]
    }

    /// A whole file, a folder, or a part of a file, on one disc. Paths are from the disc's top.
    struct FileEntry: Codable, Sendable, Equatable {
        var path: String
        var folder: Bool?
        /// The whole file's size.
        var size: UInt64?
        var part: Int?
        var parts: Int?
        var offset: UInt64?
        var length: UInt64?
        /// Where the part is on its disc.
        var partPath: String?
    }

    var format = "burn-disc-set"
    var formatVersion = 1
    var name: String
    var id: String
    var created: String
    var application: String
    var discSize: String
    var discCount: Int
    var thisDisc: Int
    var discs: [DiscEntry]

    func encoded() -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return [UInt8]((try? encoder.encode(self)) ?? Data()) + [0x0A]
    }
}

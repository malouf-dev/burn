import CryptoKit
import Foundation
import MMC

/// A disc image made on demand, block by block, from its layout and the files it lists. Nothing
/// is written to disk first, so a 100 GB Blu-ray needs no 100 GB of free space (decision D14).
///
/// Any block can be read at any time, in any order, and reads the same each time, so a burn can
/// write the image and then read it again to verify the disc. Files are hashed as the image is
/// read in order, and `.burn/SHA256SUMS` comes last, once every file has been read. A file that
/// was skipped is hashed on its own when the list is made.
///
/// Reads are serialised with a lock, so it can be shared between threads.
public final class DiscImage: @unchecked Sendable {
    public let blockCount: Int

    private enum Content {
        case zeros
        /// Structures made in one piece, such as a folder's records.
        case bytes(() -> [UInt8])
        /// One UDF File Entry per block, for `udfNodes` from `first`.
        case fileEntries(first: Int)
        case file(Node)
        case generated(Node)
    }

    private struct Region {
        let start: Int
        let blocks: Int
        let content: Content
    }

    private let layout: Layout
    private var regions: [Region] = []
    private let lock = NSLock()

    // Guarded by `lock`.
    private var cached: (index: Int, bytes: [UInt8])?
    private var openFile: (node: Node, handle: FileHandle)?
    private var hashing: (node: Node, hasher: SHA256, position: UInt64)?
    private var digests: [String: String] = [:]
    private var checksums: [UInt8]?

    init(layout: Layout, volumeName: String, date: Date) {
        self.layout = layout
        blockCount = layout.totalBlocks
        let stamp = Timestamp(date)

        var next = 0
        func add(_ start: Int, _ blocks: Int, _ content: Content) {
            precondition(start >= next, "Image regions overlap at block \(start)")
            if start > next { regions.append(Region(start: next, blocks: start - next, content: .zeros)) }
            if blocks > 0 { regions.append(Region(start: start, blocks: blocks, content: content)) }
            next = start + blocks
        }
        func blocks(_ bytes: Int) -> Int { (bytes + sectorSize - 1) / sectorSize }

        add(16, 3, .bytes { layout.isoDescriptors(volumeName: volumeName, stamp: stamp) })
        if layout.includesUDF {
            add(Int(UDF.volumeRecognition), 3, .bytes { UDF.recognitionSequence() })
            add(Int(UDF.mainSequence), Int(UDF.sequenceBlocks), .bytes {
                layout.udfVolumeSequence(start: UDF.mainSequence, volumeName: volumeName, stamp: stamp)
            })
            add(Int(UDF.reserveSequence), Int(UDF.sequenceBlocks), .bytes {
                layout.udfVolumeSequence(start: UDF.reserveSequence, volumeName: volumeName, stamp: stamp)
            })
            add(Int(UDF.integritySequence), 2, .bytes { layout.udfIntegritySequence(stamp: stamp) })
            add(Int(UDF.anchor), 1, .bytes { layout.udfAnchor(location: UDF.anchor) })
            add(Int(UDF.partitionStart), 2, .bytes { layout.udfFileSet(volumeName: volumeName, stamp: stamp) })
            // File Entries in runs of 512, so a disc of many files isn't one huge region.
            var first = 0
            while first < layout.udfNodes.count {
                let count = min(512, layout.udfNodes.count - first)
                add(Int(UDF.partitionStart + layout.udfNodes[first].udfEntry), count, .fileEntries(first: first))
                first += count
            }
            for directory in layout.udfNodes where directory.isDirectory {
                add(Int(UDF.partitionStart + directory.udfDirectoryBlock), blocks(directory.udfDirectorySize), .bytes {
                    layout.udfDirectoryContents(directory)
                })
            }
        }
        let tableBlocks = (iso: blocks(layout.isoPathTableSize), joliet: blocks(layout.jolietPathTableSize))
        add(Int(layout.isoPathTableL), tableBlocks.iso, .bytes { layout.pathTable(joliet: false, bigEndian: false) })
        add(Int(layout.isoPathTableM), tableBlocks.iso, .bytes { layout.pathTable(joliet: false, bigEndian: true) })
        add(Int(layout.jolietPathTableL), tableBlocks.joliet, .bytes { layout.pathTable(joliet: true, bigEndian: false) })
        add(Int(layout.jolietPathTableM), tableBlocks.joliet, .bytes { layout.pathTable(joliet: true, bigEndian: true) })
        for directory in layout.isoDirectories {
            add(Int(directory.isoExtent), blocks(directory.isoSize), .bytes {
                layout.directoryContents(directory, joliet: false)
            })
        }
        for directory in layout.jolietDirectories {
            add(Int(directory.jolietExtent), blocks(directory.jolietSize), .bytes {
                layout.directoryContents(directory, joliet: true)
            })
        }
        for file in layout.files {
            add(Int(file.fileExtent), blocks(Int(file.size)), file.generated == nil ? .file(file) : .generated(file))
        }
        precondition(next == Int(layout.dataEnd), "Image layout out of step at block \(next)")
        if layout.includesUDF {
            add(blockCount - 1, 1, .bytes { layout.udfAnchor(location: UInt32(layout.totalBlocks - 1)) })
        } else {
            add(blockCount, 0, .zeros)
        }
    }

    deinit {
        try? openFile?.handle.close()
    }

    /// Reads `count` blocks from `block`: exactly `count * 2048` bytes.
    public func read(block: Int, count: Int) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        precondition(block >= 0 && count >= 0 && block + count <= blockCount, "Read past the end of the image")
        var result: [UInt8] = []
        result.reserveCapacity(count * sectorSize)
        var current = block
        var index = regionIndex(containing: block)
        while current < block + count {
            let region = regions[index]
            let from = current - region.start
            let upTo = min(block + count, region.start + region.blocks) - region.start
            result += try bytes(of: region, index: index, blocks: from..<upTo)
            current = region.start + upTo
            index += 1
        }
        return result
    }

    /// Writes the whole image to a file, reporting the fraction done.
    func write(to url: URL, progress: ((Double) -> Void)?) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ISOBuilderError.unreadable(url.path)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = 0
        while block < blockCount {
            let count = min(512, blockCount - block)
            try handle.write(contentsOf: Data(read(block: block, count: count)))
            block += count
            progress?(Double(block) / Double(max(1, blockCount)))
        }
    }

    // MARK: - Regions

    private func regionIndex(containing block: Int) -> Int {
        var low = 0
        var high = regions.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if regions[middle].start <= block { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func bytes(of region: Region, index: Int, blocks: Range<Int>) throws -> [UInt8] {
        let length = blocks.count * sectorSize
        switch region.content {
        case .zeros:
            return [UInt8](repeating: 0, count: length)
        case .bytes(let make):
            if cached?.index != index { cached = (index, padded(make(), blocks: region.blocks)) }
            return slice(cached?.bytes ?? [], blocks)
        case .fileEntries(let first):
            return blocks.flatMap { layout.udfFileEntry(layout.udfNodes[first + $0]) }
        case .generated(let node):
            return try slice(padded(generatedContent(node), blocks: region.blocks), blocks)
        case .file(let node):
            let offset = UInt64(blocks.lowerBound * sectorSize)
            let wanted = Int(min(UInt64(length), node.size - offset))
            var data = try readFile(node, offset: offset, length: wanted)
            data += [UInt8](repeating: 0, count: length - data.count)
            return data
        }
    }

    private func padded(_ bytes: [UInt8], blocks: Int) -> [UInt8] {
        precondition(bytes.count <= blocks * sectorSize, "A structure outgrew its place in the image")
        return bytes + [UInt8](repeating: 0, count: blocks * sectorSize - bytes.count)
    }

    private func slice(_ bytes: [UInt8], _ blocks: Range<Int>) -> [UInt8] {
        Array(bytes[(blocks.lowerBound * sectorSize)..<(blocks.upperBound * sectorSize)])
    }

    // MARK: - Files

    private func readFile(_ node: Node, offset: UInt64, length: Int) throws -> [UInt8] {
        guard let source = node.source else { throw ISOBuilderError.notFound(node.name) }
        let handle = try self.handle(for: node)
        try handle.seek(toOffset: offset)
        let data = [UInt8](try handle.read(upToCount: length) ?? Data())
        guard data.count == length else { throw ISOBuilderError.changedWhileWriting(source.path) }

        // Hash the file when it's read in order from the start, as a burn does.
        guard layout.checksumsNode != nil else { return data }
        if offset == 0 { hashing = (node, SHA256(), 0) }
        if var state = hashing, state.node === node, state.position == offset {
            state.hasher.update(data: data)
            state.position += UInt64(length)
            hashing = state
            if state.position == node.size {
                if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
                    throw ISOBuilderError.changedWhileWriting(source.path)
                }
                digests[layout.discPath(node)] = DiscChecksums.hex(state.hasher.finalize())
                hashing = nil
            }
        }
        return data
    }

    private func handle(for node: Node) throws -> FileHandle {
        if let openFile, openFile.node === node { return openFile.handle }
        try? openFile?.handle.close()
        openFile = nil
        guard let source = node.source, let handle = try? FileHandle(forReadingFrom: source) else {
            throw ISOBuilderError.unreadable(node.source?.path ?? node.name)
        }
        openFile = (node, handle)
        return handle
    }

    private func generatedContent(_ node: Node) throws -> [UInt8] {
        let content: [UInt8]
        switch node.generated {
        case .checksums?:
            if let checksums { return checksums }
            for file in layout.files where file.generated == nil && digests[layout.discPath(file)] == nil {
                digests[layout.discPath(file)] = try hashWhole(file)
            }
            content = Array(DiscChecksums.render(digests).utf8)
            checksums = content
        case .content(let bytes)?:
            content = bytes
        case nil:
            content = []
        }
        precondition(content.count == Int(node.size), "Generated file \(node.name) changed size")
        return content
    }

    /// Hashes a file the image hasn't read in order, such as when a burn starts partway through.
    private func hashWhole(_ node: Node) throws -> String {
        guard let source = node.source else { throw ISOBuilderError.notFound(node.name) }
        let handle = try self.handle(for: node)
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var remaining = node.size
        while remaining > 0 {
            let chunk = try handle.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
            if chunk.isEmpty { throw ISOBuilderError.changedWhileWriting(source.path) }
            hasher.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
            throw ISOBuilderError.changedWhileWriting(source.path)
        }
        return DiscChecksums.hex(hasher.finalize())
    }
}

/// The drive engine burns a `DiscImage` directly.
extension DiscImage: ImageSource {}

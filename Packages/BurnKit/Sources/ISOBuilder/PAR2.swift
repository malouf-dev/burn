import CGF16
import CryptoKit
import Foundation

/// PAR2 2.0 recovery data (decision D15), written from the Parity Volume Set 2.0 specification.
///
/// Files are cut into slices of equal size. Recovery slices are sums of every input slice, each
/// multiplied by a different constant in GF(2^16), so any `n` damaged slices can be rebuilt from
/// any `n` recovery slices. Any PAR2 tool can do the rebuilding, such as `par2 repair`.
enum PAR2 {
    static let magic = Array("PAR2\0PKT".utf8)
    static let mainType = Array("PAR 2.0\0Main\0\0\0\0".utf8)
    static let fileDescriptionType = Array("PAR 2.0\0FileDesc".utf8)
    static let sliceChecksumType = Array("PAR 2.0\0IFSC\0\0\0\0".utf8)
    static let recoverySliceType = Array("PAR 2.0\0RecvSlic".utf8)
    static let creatorType = Array("PAR 2.0\0Creator\0".utf8)
    static let creator = "Burn"
    /// The specification allows at most this many input slices.
    static let maxInputSlices = 32768
    static let headerSize = 64
    static let minimumSliceSize = 4096

    // MARK: - Packets

    /// A packet: the header, with its MD5 over everything from the recovery set ID on, then the body.
    static func packet(type: [UInt8], setID: [UInt8], body: [UInt8]) -> [UInt8] {
        precondition(body.count % 4 == 0, "PAR2 packet bodies are whole 4-byte words")
        var packet = magic
        packet += le64(UInt64(headerSize + body.count))
        packet += [UInt8](repeating: 0, count: 16)
        packet += setID + type + body
        packet.replaceSubrange(16..<32, with: md5(packet[32...]))
        return packet
    }

    static func mainBody(sliceSize: Int, fileIDs: [[UInt8]]) -> [UInt8] {
        le64(UInt64(sliceSize)) + le32(UInt32(fileIDs.count)) + fileIDs.joined()
    }

    static func fileDescriptionBody(fileID: [UInt8], md5: [UInt8], md5First16K: [UInt8], length: UInt64,
                                    name: [UInt8]) -> [UInt8] {
        fileID + md5 + md5First16K + le64(length) + padded(name)
    }

    static func fileID(md5First16K: [UInt8], length: UInt64, name: [UInt8]) -> [UInt8] {
        md5((md5First16K + le64(length) + name)[...])
    }

    static func creatorBody() -> [UInt8] {
        padded(Array(creator.utf8))
    }

    /// File IDs in the order the specification sorts them: as 16-byte little-endian numbers.
    static func idOrder(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        for index in stride(from: 15, through: 0, by: -1) where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index]
        }
        return false
    }

    // MARK: - Sizes

    static func padded(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
    }

    static func mainPacketSize(files: Int) -> Int { headerSize + 12 + 16 * files }
    static func fileDescriptionSize(nameBytes: Int) -> Int { headerSize + 56 + (nameBytes + 3) / 4 * 4 }
    static func sliceChecksumSize(slices: Int) -> Int { headerSize + 16 + 20 * slices }
    static var creatorSize: Int { headerSize + creatorBody().count }
    static func recoverySliceSize(sliceSize: Int) -> Int { headerSize + 4 + sliceSize }

    static func sliceCount(_ size: UInt64, sliceSize: Int) -> Int {
        Int((size + UInt64(sliceSize) - 1) / UInt64(sliceSize))
    }

    // MARK: - Choosing slices

    struct Plan: Equatable {
        let sliceSize: Int
        let recoveryCount: Int
    }

    /// Slices for files of these sizes, with recovery data about `percent` of the data.
    ///
    /// The work of making recovery data grows with the data times the number of recovery slices,
    /// so larger discs get fewer, larger slices: about 2,000 recovery slices for a CD, 400 for a
    /// DVD, 80 for a 25 GB Blu-ray. Nil when there's nothing to protect, or more files than
    /// PAR2 allows input slices.
    static func plan(sizes: [UInt64], percent: Int) -> Plan? {
        let sizes = sizes.filter { $0 > 0 }
        let total = sizes.reduce(0, +)
        guard percent > 0, total > 0, sizes.count <= maxInputSlices else { return nil }
        let recoveryBytes = Double(total) * Double(percent) / 100
        let target = min(2000, max(20, Int(2e12 / Double(total))))
        // At least 4 KB, so the tables each slice needs cost little next to the slice itself.
        var sliceSize = max(minimumSliceSize, Int((recoveryBytes / Double(target)).rounded(.up)))
        sliceSize = (sliceSize + 3) / 4 * 4
        func slices(_ size: Int) -> Int {
            sizes.reduce(0) { $0 + sliceCount($1, sliceSize: size) }
        }
        while slices(sliceSize) > maxInputSlices { sliceSize *= 2 }
        let recoveryCount = max(1, Int((recoveryBytes / Double(sliceSize)).rounded(.up)))
        return Plan(sliceSize: sliceSize, recoveryCount: min(recoveryCount, maxInputSlices))
    }

    // MARK: - Checksums

    static func md5(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        Array(bytes.withUnsafeBytes { Insecure.MD5.hash(data: $0) })
    }

    /// CRC-32 as zip and PNG use it: reflected polynomial 0xEDB88320.
    static func crc32(_ bytes: UnsafeRawBufferPointer, from crc: UInt32 = 0) -> UInt32 {
        var value = ~crc
        for byte in bytes {
            value = (value >> 8) ^ crc32Table[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return ~value
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    static func le64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }
}

/// Arithmetic in GF(2^16) with the generator PAR2 uses, x^16 + x^12 + x^3 + x + 1 (0x1100B).
enum GF16 {
    static let generator: UInt32 = 0x1100B

    /// log[x] and exp[n], with exp doubled in length so sums of two logs need no reduction.
    static let tables: (log: [UInt16], exp: [UInt16]) = {
        var log = [UInt16](repeating: 0, count: 65536)
        var exp = [UInt16](repeating: 0, count: 2 * 65535)
        var value: UInt32 = 1
        for power in 0..<65535 {
            exp[power] = UInt16(value)
            exp[power + 65535] = UInt16(value)
            log[Int(value)] = UInt16(power)
            value <<= 1
            if value & 0x10000 != 0 { value ^= generator }
        }
        return (log, exp)
    }()

    static func multiply(_ a: UInt16, _ b: UInt16) -> UInt16 {
        guard a != 0, b != 0 else { return 0 }
        return tables.exp[Int(tables.log[Int(a)]) + Int(tables.log[Int(b)])]
    }

    static func divide(_ a: UInt16, _ b: UInt16) -> UInt16 {
        precondition(b != 0, "Division by zero in GF(2^16)")
        guard a != 0 else { return 0 }
        return tables.exp[Int(tables.log[Int(a)]) + 65535 - Int(tables.log[Int(b)])]
    }

    /// 2 raised to `power`.
    static func exp(_ power: Int) -> UInt16 {
        tables.exp[power % 65535]
    }

    /// The logs of the constants for input slices 0, 1, 2…: the numbers that share no factor with
    /// 65535, that is, not divisible by 3, 5, 17 or 257. Input slice i's constant is 2 to that power.
    static func inputLogs(count: Int) -> [Int] {
        var logs: [Int] = []
        logs.reserveCapacity(count)
        var candidate = 0
        while logs.count < count {
            if candidate % 3 != 0, candidate % 5 != 0, candidate % 17 != 0, candidate % 257 != 0 {
                logs.append(candidate)
            }
            candidate += 1
        }
        return logs
    }

    /// The coefficient of input slice `inputLog` in recovery slice `exponent`: its constant to that power.
    static func coefficient(inputLog: Int, exponent: Int) -> UInt16 {
        exp(inputLog * exponent % 65535)
    }

    /// The tables `bk_gf16_muladd` uses for one factor: for each 4-bit piece of a word, the
    /// product's low and high bytes for all 16 values. Products of single bits are powers of 2
    /// times the factor, and the rest follow by XOR, so no multiplication is needed.
    static func fillTables(factor: UInt16, into buffer: inout [UInt8], at offset: Int) {
        guard factor != 0 else {
            for index in offset..<(offset + Int(BK_GF16_TABLE_BYTES)) { buffer[index] = 0 }
            return
        }
        let log = Int(tables.log[Int(factor)])
        for piece in 0..<4 {
            let low = offset + piece * 32
            let high = low + 16
            buffer[low] = 0
            buffer[high] = 0
            for value in 1..<16 {
                let bit = value.trailingZeroBitCount
                let rest = value & (value - 1)
                let product = (UInt16(buffer[low + rest]) | UInt16(buffer[high + rest]) << 8) ^ tables.exp[log + 4 * piece + bit]
                buffer[low + value] = UInt8(product & 0xFF)
                buffer[high + value] = UInt8(product >> 8)
            }
        }
    }

    /// `destination ^= factor × source`, word by word, words little-endian. `source` may be shorter
    /// than `destination`; the rest counts as zeros, as a padded last slice does.
    static func multiplyAdd(_ factor: UInt16, _ source: UnsafeRawBufferPointer,
                            into destination: UnsafeMutableBufferPointer<UInt16>) {
        guard factor != 0 else { return }
        // Two 256-entry tables: the product with each low byte, and with each high byte.
        var low = [UInt16](repeating: 0, count: 256)
        var high = [UInt16](repeating: 0, count: 256)
        for byte in 0..<256 {
            low[byte] = multiply(factor, UInt16(byte))
            high[byte] = multiply(factor, UInt16(byte) << 8)
        }
        let words = source.count / 2
        low.withUnsafeBufferPointer { low in
            high.withUnsafeBufferPointer { high in
                for index in 0..<words {
                    destination[index] ^= low[Int(source[2 * index])] ^ high[Int(source[2 * index + 1])]
                }
            }
        }
        if source.count % 2 == 1 {
            destination[words] ^= low[Int(source[source.count - 1])]
        }
    }
}

/// Recovery slices for a set of exponents, made by adding input slices one at a time in any order.
///
/// Input slices are gathered eight at a time, then added to every recovery slice in 64 KB pieces,
/// so the inputs stay in the processor's cache while each recovery slice is read and written once.
/// The work is shared across the processor's cores by exponent.
final class PAR2Encoder: @unchecked Sendable {
    static let batch = 8
    static let chunk = 64 * 1024

    let sliceSize: Int
    let exponents: [Int]
    private let position: [Int: Int]
    private var recovery: [[UInt8]]
    /// Up to `batch` input slices, each padded to `sliceSize`, end to end.
    private var pending: [UInt8]
    private var pendingLogs: [Int] = []

    init(sliceSize: Int, exponents: [Int]) {
        precondition(sliceSize % 4 == 0, "PAR2 slices are whole 4-byte words")
        self.sliceSize = sliceSize
        self.exponents = exponents
        position = Dictionary(uniqueKeysWithValues: exponents.enumerated().map { ($1, $0) })
        // Each buffer is its own allocation. Array(repeating:) would share one buffer until first
        // written, and the workers would then race to copy it, starting some slices with garbage.
        recovery = (0..<exponents.count).map { _ in [UInt8](repeating: 0, count: sliceSize) }
        pending = [UInt8](repeating: 0, count: Self.batch * sliceSize)
    }

    /// Adds input slice data, which may be short for a file's last slice; the rest counts as zeros.
    func add(_ data: UnsafeRawBufferPointer, inputLog: Int) {
        precondition(data.count <= sliceSize, "Input slice larger than the slice size")
        let offset = pendingLogs.count * sliceSize
        let sliceSize = sliceSize
        pending.withUnsafeMutableBytes { buffer in
            let slot = UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<(offset + sliceSize)])
            slot.copyMemory(from: data)
            for index in data.count..<sliceSize { slot[index] = 0 }
        }
        pendingLogs.append(inputLog)
        if pendingLogs.count == Self.batch { flush() }
    }

    /// Recovery slice data for one of this encoder's exponents, words little-endian.
    func slice(exponent: Int) -> [UInt8] {
        flush()
        return recovery[position[exponent]!]
    }

    private func flush() {
        let count = pendingLogs.count
        guard count > 0 else { return }
        let logs = pendingLogs
        let exponents = exponents
        let sliceSize = sliceSize
        let total = exponents.count
        let workers = max(1, min(total, ProcessInfo.processInfo.activeProcessorCount))
        let tableBytes = Int(BK_GF16_TABLE_BYTES)
        pending.withUnsafeBytes { sourceBuffer in
            recovery.withUnsafeMutableBufferPointer { buffers in
                // Each worker takes its own exponents, so no two touch the same recovery slice.
                nonisolated(unsafe) let base = buffers.baseAddress!
                nonisolated(unsafe) let sources = sourceBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let mine = Array(stride(from: worker, to: total, by: workers))
                    var tables = [UInt8](repeating: 0, count: mine.count * count * tableBytes)
                    for (slot, index) in mine.enumerated() {
                        for source in 0..<count {
                            let factor = GF16.coefficient(inputLog: logs[source], exponent: exponents[index])
                            GF16.fillTables(factor: factor, into: &tables, at: (slot * count + source) * tableBytes)
                        }
                    }
                    var pointers = [UnsafePointer<UInt8>?](repeating: nil, count: count)
                    tables.withUnsafeBufferPointer { tables in
                        var start = 0
                        while start < sliceSize {
                            let length = min(Self.chunk, sliceSize - start)
                            for source in 0..<count { pointers[source] = UnsafePointer(sources + source * sliceSize + start) }
                            pointers.withUnsafeBufferPointer { pointers in
                                for (slot, index) in mine.enumerated() {
                                    base[index].withUnsafeMutableBufferPointer { destination in
                                        bk_gf16_muladd(destination.baseAddress! + start, pointers.baseAddress!,
                                                       tables.baseAddress! + slot * count * tableBytes, count, length)
                                    }
                                }
                            }
                            start += length
                        }
                    }
                }
            }
        }
        pendingLogs.removeAll(keepingCapacity: true)
    }
}

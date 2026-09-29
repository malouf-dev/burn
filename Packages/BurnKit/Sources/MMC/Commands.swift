import Foundation

/// Builders for the MMC commands the engine uses. Layouts follow the SCSI MMC standard.
public enum MMC {
    public static let blockSize = 2048

    public static func testUnitReady() -> SCSICommand {
        SCSICommand(cdb: [0x00, 0, 0, 0, 0, 0], timeout: 10)
    }

    public static func inquiry(length: UInt8 = 96) -> SCSICommand {
        SCSICommand(cdb: [0x12, 0, 0, 0, length, 0], direction: .fromDevice(length: Int(length)), timeout: 10)
    }

    /// GET CONFIGURATION. `requestType` 0 returns every feature, 1 only current ones, 2 one feature.
    public static func getConfiguration(requestType: UInt8 = 0, startingFeature: UInt16 = 0, length: UInt16 = 1024) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x46
        cdb[1] = requestType & 0x03
        cdb.put(startingFeature, at: 2)
        cdb.put(length, at: 7)
        return SCSICommand(cdb: cdb, direction: .fromDevice(length: Int(length)), timeout: 10)
    }

    public static func readDiscInformation(length: UInt16 = 34) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x51
        cdb.put(length, at: 7)
        return SCSICommand(cdb: cdb, direction: .fromDevice(length: Int(length)), timeout: 10)
    }

    /// READ TRACK INFORMATION for a track number (address type 01b).
    public static func readTrackInformation(track: UInt32, length: UInt16 = 48) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x52
        cdb[1] = 0x01
        cdb.put(track, at: 2)
        cdb.put(length, at: 7)
        return SCSICommand(cdb: cdb, direction: .fromDevice(length: Int(length)), timeout: 10)
    }

    public static func readCapacity() -> SCSICommand {
        SCSICommand(cdb: [0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0], direction: .fromDevice(length: 8), timeout: 10)
    }

    /// MODE SENSE (10) for current values, with block descriptors disabled.
    public static func modeSense(page: UInt8, length: UInt16 = 64) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x5A
        cdb[1] = 0x08
        cdb[2] = page & 0x3F
        cdb.put(length, at: 7)
        return SCSICommand(cdb: cdb, direction: .fromDevice(length: Int(length)), timeout: 10)
    }

    /// MODE SELECT (10) with page format set.
    public static func modeSelect(parameters: [UInt8]) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x55
        cdb[1] = 0x10
        cdb.put(UInt16(parameters.count), at: 7)
        return SCSICommand(cdb: cdb, direction: .toDevice(parameters), timeout: 30)
    }

    /// RESERVE TRACK for a size in blocks.
    public static func reserveTrack(blocks: UInt32) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x53
        cdb.put(blocks, at: 5)
        return SCSICommand(cdb: cdb, timeout: 120)
    }

    public static func write10(lba: UInt32, data: [UInt8]) -> SCSICommand {
        let blocks = UInt16(data.count / blockSize)
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x2A
        cdb.put(lba, at: 2)
        cdb.put(blocks, at: 7)
        return SCSICommand(cdb: cdb, direction: .toDevice(data), timeout: 120)
    }

    public static func read10(lba: UInt32, blocks: UInt16) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x28
        cdb.put(lba, at: 2)
        cdb.put(blocks, at: 7)
        return SCSICommand(cdb: cdb, direction: .fromDevice(length: Int(blocks) * blockSize), timeout: 120)
    }

    public static func synchronizeCache() -> SCSICommand {
        SCSICommand(cdb: [0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0], timeout: 1800)
    }

    /// CLOSE TRACK/SESSION functions.
    public enum CloseFunction: UInt8, Sendable {
        case track = 0x01
        case session = 0x02
        /// DVD+R: finalise the disc with minimal radius.
        case finaliseDVDPlusR = 0x05
        /// DVD+R DL and BD-R: finalise the disc.
        case finaliseDisc = 0x06
    }

    public static func closeTrackSession(_ function: CloseFunction, track: UInt16 = 0) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x5B
        cdb[2] = function.rawValue
        cdb.put(track, at: 4)
        return SCSICommand(cdb: cdb, timeout: 1800)
    }

    /// BLANK. Type 1 is a minimal (quick) blank, type 0 blanks the whole disc.
    public static func blank(quick: Bool = true) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 12)
        cdb[0] = 0xA1
        cdb[1] = quick ? 0x01 : 0x00
        return SCSICommand(cdb: cdb, timeout: 3600)
    }

    /// START STOP UNIT with the load/eject bit: `load` false ejects, true loads.
    public static func startStopUnit(load: Bool) -> SCSICommand {
        SCSICommand(cdb: [0x1B, 0, 0, 0, load ? 0x03 : 0x02, 0], timeout: 60)
    }

    public static func preventAllowMediumRemoval(prevent: Bool) -> SCSICommand {
        SCSICommand(cdb: [0x1E, 0, 0, 0, prevent ? 0x01 : 0x00, 0], timeout: 10)
    }
}

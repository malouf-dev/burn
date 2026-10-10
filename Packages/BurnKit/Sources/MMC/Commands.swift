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

    /// READ FORMAT CAPACITIES: the formats the drive can apply to the disc.
    public static func readFormatCapacities(length: UInt16 = 252) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x23
        cdb.put(length, at: 7)
        return SCSICommand(cdb: cdb, direction: .fromDevice(length: Int(length)), timeout: 30)
    }

    /// FORMAT UNIT with one descriptor, as READ FORMAT CAPACITIES listed it. With `immediate`,
    /// the drive answers at once and reports progress to TEST UNIT READY.
    public static func formatUnit(_ descriptor: FormatDescriptor, immediate: Bool = false) -> SCSICommand {
        let header: [UInt8] = [0x00, immediate ? 0x02 : 0x00, 0x00, 0x08]
        return SCSICommand(cdb: [0x04, 0x11, 0, 0, 0, 0], direction: .toDevice(header + descriptor.bytes),
                           timeout: immediate ? 60 : 3600)
    }

    /// GET PERFORMANCE for write speed descriptors (type 03h): the speeds the drive can write the
    /// disc in it at.
    public static func getWriteSpeeds(maxDescriptors: UInt16 = 32) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 12)
        cdb[0] = 0xAC
        cdb.put(maxDescriptors, at: 8)
        cdb[10] = 0x03
        return SCSICommand(cdb: cdb, direction: .fromDevice(length: 8 + Int(maxDescriptors) * 16), timeout: 10)
    }

    /// SET STREAMING with one performance descriptor: write at `speed` kilobytes (1,000 bytes) a
    /// second from block 0 to `endBlock`. DVD and Blu-ray drives take their write speed this way.
    /// Reading is held to the same speed until `restoreDefaultSpeeds`.
    public static func setStreaming(writeKilobytesPerSecond speed: UInt32, endBlock: UInt32) -> SCSICommand {
        var parameters = [UInt8](repeating: 0, count: 28)
        parameters.put(endBlock, at: 8)
        parameters.put(speed, at: 12)
        parameters.put(UInt32(1000), at: 16)
        parameters.put(speed, at: 20)
        parameters.put(UInt32(1000), at: 24)
        return setStreaming(parameters)
    }

    /// SET STREAMING with Restore Drive Defaults set: the drive goes back to its own speeds.
    public static func restoreDefaultSpeeds() -> SCSICommand {
        var parameters = [UInt8](repeating: 0, count: 28)
        parameters[0] = 0x04
        return setStreaming(parameters)
    }

    private static func setStreaming(_ parameters: [UInt8]) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 12)
        cdb[0] = 0xB6
        cdb.put(UInt16(parameters.count), at: 9)
        return SCSICommand(cdb: cdb, direction: .toDevice(parameters), timeout: 30)
    }

    /// SET CD SPEED: CD drives take their write speed this way. Reading stays at its fastest.
    public static func setCDSpeed(writeKilobytesPerSecond speed: UInt16) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 12)
        cdb[0] = 0xBB
        cdb.put(UInt16(0xFFFF), at: 2)
        cdb.put(speed, at: 4)
        return SCSICommand(cdb: cdb, timeout: 30)
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

    /// Long operations can outlast the USB transport's own timeout (about four minutes on
    /// a Pioneer BDR-UD04), so the engine sends them with the immediate bit set and polls
    /// TEST UNIT READY until the drive is done.
    public static func synchronizeCache(immediate: Bool = false) -> SCSICommand {
        SCSICommand(cdb: [0x35, immediate ? 0x02 : 0x00, 0, 0, 0, 0, 0, 0, 0, 0], timeout: immediate ? 60 : 1800)
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

    public static func closeTrackSession(_ function: CloseFunction, track: UInt16 = 0, immediate: Bool = false) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 10)
        cdb[0] = 0x5B
        cdb[1] = immediate ? 0x01 : 0x00
        cdb[2] = function.rawValue
        cdb.put(track, at: 4)
        return SCSICommand(cdb: cdb, timeout: immediate ? 60 : 1800)
    }

    /// BLANK. Type 1 is a minimal (quick) blank, type 0 blanks the whole disc.
    public static func blank(quick: Bool = true, immediate: Bool = false) -> SCSICommand {
        var cdb = [UInt8](repeating: 0, count: 12)
        cdb[0] = 0xA1
        cdb[1] = (quick ? 0x01 : 0x00) | (immediate ? 0x10 : 0x00)
        return SCSICommand(cdb: cdb, timeout: immediate ? 60 : 3600)
    }

    /// START STOP UNIT with the load/eject bit: `load` false ejects, true loads.
    public static func startStopUnit(load: Bool) -> SCSICommand {
        SCSICommand(cdb: [0x1B, 0, 0, 0, load ? 0x03 : 0x02, 0], timeout: 60)
    }

    public static func preventAllowMediumRemoval(prevent: Bool) -> SCSICommand {
        SCSICommand(cdb: [0x1E, 0, 0, 0, prevent ? 0x01 : 0x00, 0], timeout: 10)
    }
}

import Testing
@testable import MMC

@Suite("Command layouts")
struct CommandTests {
    @Test func write10() {
        let command = MMC.write10(lba: 0x0102_0304, data: [UInt8](repeating: 0, count: 2 * 2048))
        #expect(command.cdb == [0x2A, 0, 0x01, 0x02, 0x03, 0x04, 0, 0x00, 0x02, 0])
        #expect(command.direction == .toDevice([UInt8](repeating: 0, count: 4096)))
    }

    @Test func read10() {
        let command = MMC.read10(lba: 300, blocks: 16)
        #expect(command.cdb == [0x28, 0, 0, 0, 0x01, 0x2C, 0, 0, 16, 0])
        #expect(command.direction == .fromDevice(length: 16 * 2048))
    }

    @Test func readTrackInformation() {
        let command = MMC.readTrackInformation(track: 1)
        #expect(command.cdb == [0x52, 0x01, 0, 0, 0, 1, 0, 0, 48, 0])
    }

    @Test func getConfiguration() {
        let command = MMC.getConfiguration(requestType: 1, startingFeature: 0x0102, length: 0x0400)
        #expect(command.cdb == [0x46, 0x01, 0x01, 0x02, 0, 0, 0, 0x04, 0x00, 0])
    }

    @Test func reserveTrack() {
        let command = MMC.reserveTrack(blocks: 0x0001_0000)
        #expect(command.cdb == [0x53, 0, 0, 0, 0, 0x00, 0x01, 0x00, 0x00, 0])
    }

    @Test func closeFunctions() {
        #expect(MMC.closeTrackSession(.track, track: 1).cdb == [0x5B, 0, 0x01, 0, 0, 1, 0, 0, 0, 0])
        #expect(MMC.closeTrackSession(.session).cdb[2] == 0x02)
        #expect(MMC.closeTrackSession(.finaliseDVDPlusR).cdb[2] == 0x05)
        #expect(MMC.closeTrackSession(.finaliseDisc).cdb[2] == 0x06)
    }

    @Test func blankIsTwelveBytes() {
        let command = MMC.blank(quick: true)
        #expect(command.cdb.count == 12)
        #expect(command.cdb[0] == 0xA1)
        #expect(command.cdb[1] == 0x01)
    }

    @Test func ejectAndLoad() {
        #expect(MMC.startStopUnit(load: false).cdb == [0x1B, 0, 0, 0, 0x02, 0])
        #expect(MMC.startStopUnit(load: true).cdb == [0x1B, 0, 0, 0, 0x03, 0])
    }

    @Test func modeSelectCarriesPageWithoutPSBit() {
        var page = [UInt8](repeating: 0, count: 52)
        page[0] = 0x85
        page[1] = 0x32
        let parameters = ModePage.selectParameters(page: page)
        #expect(parameters.count == 60)
        #expect(parameters[8] == 0x05)
        let command = MMC.modeSelect(parameters: parameters)
        #expect(command.cdb[0] == 0x55)
        #expect(command.cdb[1] == 0x10)
        #expect(command.cdb[8] == 60)
    }
}

@Suite("Response parsing")
struct ParserTests {
    @Test func fixedFormatSense() {
        var bytes = [UInt8](repeating: 0, count: 18)
        bytes[0] = 0x70
        bytes[2] = 0x02
        bytes[12] = 0x3A
        bytes[13] = 0x01
        let sense = SenseData(bytes: bytes)
        #expect(sense == SenseData(key: 0x02, asc: 0x3A, ascq: 0x01))
        #expect(sense?.isNoMedium == true)
    }

    @Test func senseProgress() {
        let sense = SenseData(bytes: SenseData(key: 0x02, asc: 0x04, ascq: 0x07, progress: 0.5).bytes)
        #expect(sense?.isTransientNotReady == true)
        #expect(sense?.progress == 0.5)
    }

    @Test func emptySenseIsNil() {
        #expect(SenseData(bytes: [UInt8](repeating: 0, count: 18)) == nil)
    }

    @Test func configurationRoundTrip() {
        let original = ConfigurationData(currentProfile: .dvdPlusR, supportedProfiles: [.bdRSequential, .dvdPlusR, .cdR])
        let parsed = ConfigurationData(bytes: original.bytes)
        #expect(parsed == original)
    }

    @Test func discInformation() {
        var bytes = [UInt8](repeating: 0, count: 34)
        bytes[2] = 0x1E // erasable, last session complete, disc complete
        bytes[4] = 2
        bytes[5] = 3
        bytes[6] = 3
        let info = DiscInformation(bytes: bytes)
        #expect(info?.status == .complete)
        #expect(info?.isErasable == true)
        #expect(info?.sessions == 2)
        #expect(info?.lastTrackInLastSession == 3)
        #expect(info?.lastSessionState == .complete)
    }

    // Hardware run 17: reads of a blank DVD-RW came back as "KEY 08h: Drive error".
    @Test func blankCheckIsExplained() {
        let sense = SenseData(key: 0x08, asc: 0x00, ascq: 0x00)
        #expect(sense.keyName == "BLANK CHECK")
        #expect(sense.explanation == "That part of the disc hasn't been written.")
        #expect(SenseData(key: 0x03, asc: 0x51, ascq: 0x01).explanation == "An earlier erase of this disc didn't finish.")
    }

    @Test func formatCapacities() {
        let original = FormatCapacities(currentBlocks: 2_297_888, currentDescriptorType: 1, formats: [
            FormatDescriptor(blocks: 2_297_888, formatType: 0x10, parameter: 16),
            FormatDescriptor(blocks: 2_297_888, formatType: 0x15, parameter: 0),
        ])
        let parsed = FormatCapacities(bytes: original.bytes)
        #expect(parsed == original)
        #expect(original.bytes.count == 28)
        #expect(original.bytes[12 + 4] == 0x40)

        let command = MMC.formatUnit(original.formats[0], immediate: true)
        #expect(command.cdb == [0x04, 0x11, 0, 0, 0, 0])
        guard case .toDevice(let data) = command.direction else {
            Issue.record("FORMAT UNIT should send data")
            return
        }
        #expect(data == [0x00, 0x02, 0x00, 0x08] + original.formats[0].bytes)
    }

    @Test func unfinishedDiscInformation() {
        var bytes = [UInt8](repeating: 0, count: 34)
        bytes[2] = 0x15 // erasable, last session incomplete, disc appendable
        let info = DiscInformation(bytes: bytes)
        #expect(info?.status == .appendable)
        #expect(info?.lastSessionState == .incomplete)
        #expect(info.map { DiscInformation(bytes: $0.bytes) } == info)
    }

    @Test func trackInformation() {
        let track = TrackInformation(track: 1, session: 1, isBlank: true, start: 0, nextWritable: 0,
                                     nextWritableValid: true, freeBlocks: 2_295_104, size: 2_295_104)
        #expect(TrackInformation(bytes: track.bytes) == track)
    }

    @Test func inquiry() {
        let data = InquiryData(vendor: "PIONEER", product: "BD-RW BDR-XD08", revision: "1.02")
        #expect(InquiryData(bytes: data.bytes) == data)
    }

    @Test func writeParametersKeepOtherFields() {
        var page = [UInt8](repeating: 0, count: 52)
        page[0] = 0x05
        page[1] = 0x32
        page[14] = 0x00
        page[15] = 0x96 // audio pause length, must survive
        let applied = WriteParameters(writeType: .trackAtOnce, testWrite: true).applied(to: page)
        let parsed = WriteParameters(page: applied)
        #expect(parsed?.writeType == .trackAtOnce)
        #expect(parsed?.testWrite == true)
        #expect(parsed?.bufferUnderrunProtection == true)
        #expect(parsed?.trackMode == 4)
        #expect(parsed?.dataBlockType == 8)
        #expect(applied[15] == 0x96)
        #expect(applied.count == 52)
    }

    @Test func modeSenseFirstPage() {
        var page = [UInt8](repeating: 0, count: 52)
        page[0] = 0x05
        page[1] = 0x32
        let response = ModePage.senseResponse(page: page)
        #expect(ModePage.firstPage(inModeSense: response) == page)
    }

    @Test func profileMethods() {
        #expect(MediaProfile.cdR.writeMethod == .cdTrackAtOnce)
        #expect(MediaProfile.dvdRSequential.writeMethod == .dvdMinusDiscAtOnce)
        #expect(MediaProfile.dvdPlusR.writeMethod == .dvdPlusR)
        #expect(MediaProfile.bdRSequential.writeMethod == .bluRayR)
        #expect(MediaProfile.dvdPlusRW.writeMethod == nil)
        #expect(MediaProfile.bdRE.name == "BD-RE")
        #expect(MediaProfile(rawValue: 0x0041).mediaClass == .bluRay)
    }
}

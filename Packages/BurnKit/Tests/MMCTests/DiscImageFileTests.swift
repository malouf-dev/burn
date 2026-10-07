import Foundation
import Testing
@testable import MMC
import MMCSimulator

@Suite("Disc image files")
struct DiscImageFileTests {
    func file(_ bytes: [UInt8], named name: String = "disc.iso") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func aRawImageIsReadyToBurn() throws {
        let url = try file(patternImage(blocks: 40).bytes, named: "OSX.cdr")
        #expect(DiscImageFile.hasImageExtension(url))
        #expect(try DiscImageFile.inspect(url) == .raw(blocks: 40))
    }

    @Test func aUDIFImageNeedsConverting() throws {
        // UDIF ends in a 512-byte trailer starting "koly", whatever its size.
        var bytes = [UInt8](repeating: 0, count: 8 * MMC.blockSize)
        bytes.replaceSubrange((bytes.count - 512)..<(bytes.count - 508), with: Array("koly".utf8))
        let url = try file(bytes, named: "Install.dmg")
        #expect(try DiscImageFile.inspect(url) == .appleDiskImage)
    }

    @Test func aFileOfPartBlocksIsNotADiscImage() throws {
        let url = try file([UInt8](repeating: 1, count: 3_000))
        #expect(try DiscImageFile.inspect(url) == .notBlockAligned(bytes: 3_000))
        #expect(try DiscImageFile.inspect(try file([])) == .notBlockAligned(bytes: 0))
    }

    @Test func otherNamesAreNotImages() {
        #expect(!DiscImageFile.hasImageExtension(URL(fileURLWithPath: "/tmp/notes.txt")))
        #expect(DiscImageFile.hasImageExtension(URL(fileURLWithPath: "/tmp/OSX_10.6.7.ISO")))
    }

    /// A Mac install DVD is nearly a full dual-layer disc: 4,167,760 of 4,173,824 blocks on a
    /// DVD+R DL. A smaller image stands in for it here, burned from a file as the app does.
    @Test(arguments: [MediaProfile.dvdPlusRDualLayer, .dvdRDualLayerSequential])
    func anImageFileFillsADualLayerDisc(profile: MediaProfile) async throws {
        let image = patternImage(blocks: 4_000)
        let url = try file(image.bytes)
        let simulator = SimulatedDrive(media: .init(profile: profile, capacityBlocks: 4_016))
        let report = try await DiscDrive(transport: simulator).write(try FileImageSource(url: url))
        #expect(report.verified)
        #expect(simulator.recordedBytes(from: 0, count: 4_000) == image.bytes)
        #expect(simulator.currentMedia?.closed == true)
    }
}

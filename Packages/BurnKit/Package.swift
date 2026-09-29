// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BurnKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MMC", targets: ["MMC"]),
        .library(name: "MMCSimulator", targets: ["MMCSimulator"]),
        .library(name: "ISOBuilder", targets: ["ISOBuilder"]),
        .library(name: "IOKitTransport", targets: ["IOKitTransport"]),
        .executable(name: "burnctl", targets: ["burnctl"]),
    ],
    targets: [
        // Plain Swift: MMC commands, response parsers and the drive engine.
        .target(name: "MMC"),
        // Plain Swift: an in-memory drive for tests and CI.
        .target(name: "MMCSimulator", dependencies: ["MMC"]),
        // Plain Swift: ISO 9660 + Joliet image builder.
        .target(name: "ISOBuilder"),
        // C wrapper over IOKit's MMC and SCSI task interfaces. Compiles to nothing off macOS.
        .target(
            name: "CIOKitMMC",
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .linkedFramework("DiskArbitration", .when(platforms: [.macOS])),
            ]
        ),
        // The only Swift module that talks to real drives.
        .target(name: "IOKitTransport", dependencies: ["MMC", "CIOKitMMC"]),
        .executableTarget(
            name: "burnctl",
            dependencies: ["MMC", "MMCSimulator", "ISOBuilder", "IOKitTransport"]
        ),
        .testTarget(name: "MMCTests", dependencies: ["MMC", "MMCSimulator"]),
        .testTarget(name: "ISOBuilderTests", dependencies: ["ISOBuilder"]),
    ]
)

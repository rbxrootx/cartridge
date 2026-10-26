// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cartridge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cartridge", targets: ["Cartridge"])],
    targets: [
        .target(name: "CartridgeCore", swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
        .executableTarget(name: "Cartridge", dependencies: ["CartridgeCore"],
                          swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]),
        .testTarget(name: "CartridgeCoreTests", dependencies: ["CartridgeCore"]),
    ]
)

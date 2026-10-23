// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LuminaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LuminaCore", targets: ["LuminaCore"]),
    ],
    targets: [
        .target(
            name: "LuminaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "LuminaCoreTests",
            dependencies: ["LuminaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

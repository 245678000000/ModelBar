// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ModelBar", targets: ["ModelBar"])],
    targets: [
        .target(name: "ModelBarCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ModelBar",
            dependencies: ["ModelBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ModelBarCoreTests",
            dependencies: ["ModelBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

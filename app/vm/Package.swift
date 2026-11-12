// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kido-vm",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "kido-vm",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

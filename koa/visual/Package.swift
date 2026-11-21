// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "KoaVisual", platforms: [.macOS(.v15)], targets: [.executableTarget(name: "KoaVisual", path: ".", exclude: ["__Snapshots__"], swiftSettings: [.swiftLanguageMode(.v5)])])

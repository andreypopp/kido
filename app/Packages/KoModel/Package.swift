// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KoModel",
    platforms: [.macOS(.v14)],
    products: [.library(name: "KoModel", targets: ["KoModel"])],
    targets: [.target(name: "KoModel"), .testTarget(name: "KoModelTests", dependencies: ["KoModel"])]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KoClientKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "KoClientKit", targets: ["KoClientKit"])],
    dependencies: [.package(path: "../KoModel")],
    targets: [
        .binaryTarget(name: "KoClientCore", path: "build/ko_client.xcframework"),
        .target(name: "KoClient", dependencies: ["KoClientCore"]),
        .target(name: "KoClientKit", dependencies: ["KoClient", "KoModel"], linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "KoClientKitTests", dependencies: ["KoClientKit"]),
    ]
)

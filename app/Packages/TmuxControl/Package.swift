// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TmuxControl",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TmuxControl", targets: ["TmuxControl"])],
    targets: [
        .target(name: "TmuxControl"),
        .testTarget(
            name: "TmuxControlTests",
            dependencies: ["TmuxControl"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

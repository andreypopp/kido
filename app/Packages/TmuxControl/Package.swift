// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TmuxControl",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TmuxControl", targets: ["TmuxControl"])],
    dependencies: [.package(path: "../KoModel")],
    targets: [
        .target(name: "TmuxControl", dependencies: ["KoModel"]),
        .testTarget(
            name: "TmuxControlTests",
            dependencies: ["TmuxControl", "KoModel"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

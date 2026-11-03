// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaneGeometry",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PaneGeometry", targets: ["PaneGeometry"])],
    dependencies: [.package(path: "../KoModel")],
    targets: [
        .target(name: "PaneGeometry", dependencies: ["KoModel"]),
        .testTarget(
            name: "PaneGeometryTests",
            dependencies: ["PaneGeometry", "KoModel"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

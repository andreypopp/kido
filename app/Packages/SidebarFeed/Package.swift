// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidebarFeed",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SidebarFeed", targets: ["SidebarFeed"])],
    dependencies: [.package(path: "../KoModel")],
    targets: [
        .target(name: "SidebarFeed", dependencies: ["KoModel"]),
        .testTarget(name: "SidebarFeedTests", dependencies: ["SidebarFeed", "KoModel"], exclude: ["Fixtures"]),
    ]
)

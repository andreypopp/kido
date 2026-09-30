// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidebarFeed",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SidebarFeed", targets: ["SidebarFeed"])],
    dependencies: [.package(path: "../TmuxControl")],
    targets: [
        .target(name: "SidebarFeed", dependencies: ["TmuxControl"]),
        .testTarget(name: "SidebarFeedTests", dependencies: ["SidebarFeed"]),
    ]
)

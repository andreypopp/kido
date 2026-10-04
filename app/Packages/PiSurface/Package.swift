// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PiSurface", platforms: [.macOS("26.0")], products: [.library(name: "PiSurface", targets: ["PiSurface"])], dependencies: [.package(url: "https://github.com/apple/swift-markdown.git", from: "0.7.0")], targets: [.target(name: "PiSurface", dependencies: [.product(name: "Markdown", package: "swift-markdown")]), .testTarget(name: "PiSurfaceTests", dependencies: ["PiSurface"])])

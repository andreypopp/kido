// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PiSurface", platforms: [.macOS("26.0")], products: [.library(name: "PiSurface", targets: ["PiSurface"])], targets: [.target(name: "PiSurface"), .testTarget(name: "PiSurfaceTests", dependencies: ["PiSurface"])])

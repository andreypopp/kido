// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KidoTheme",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "KidoTheme", targets: ["KidoTheme"])],
    targets: [.target(name: "KidoTheme")]
)

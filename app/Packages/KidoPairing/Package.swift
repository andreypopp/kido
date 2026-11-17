// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KidoPairing",
    platforms: [.macOS("27.0"), .iOS("26.0")],
    products: [.library(name: "KidoPairing", targets: ["KidoPairing"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates", exact: "1.21.1"),
        .package(url: "https://github.com/apple/swift-crypto", exact: "3.12.3"),
        .package(path: "../KoClientKit"),
    ],
    targets: [
        .target(name: "KidoPairing", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            "KoClientKit",
        ]),
        .testTarget(name: "KidoPairingTests", dependencies: ["KidoPairing"], resources: [.copy("testdata")]),
    ]
)

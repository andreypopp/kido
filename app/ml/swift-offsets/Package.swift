// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "offsets",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5")
    ],
    targets: [
        .executableTarget(
            name: "offsets",
            dependencies: [.product(name: "Tokenizers", package: "swift-transformers")]
        )
    ]
)

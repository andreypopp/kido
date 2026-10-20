// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParagraphTagger",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ParagraphTagger", targets: ["ParagraphTagger"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5")
    ],
    targets: [
        .target(
            name: "ParagraphTagger",
            dependencies: [.product(name: "Tokenizers", package: "swift-transformers")]
        ),
        .testTarget(name: "ParagraphTaggerTests", dependencies: ["ParagraphTagger"],
                    resources: [.copy("Golden")]),
    ]
)

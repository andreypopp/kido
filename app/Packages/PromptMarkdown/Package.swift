// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PromptMarkdown",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PromptMarkdown", targets: ["PromptMarkdown"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
    targets: [
        .target(name: "PromptMarkdown", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .testTarget(name: "PromptMarkdownTests", dependencies: ["PromptMarkdown"]),
    ]
)

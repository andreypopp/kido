import SwiftUI
import Markdown

struct MarkdownBody: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Document(parsing: text).children.enumerated()), id: \.offset) { _, block in
                MarkdownBlock(block: block)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                ["http", "https", "mailto"].contains(url.scheme ?? "") ? .systemAction : .discarded
            })
    }
}

private struct MarkdownBlock: View {
    let block: any Markup
    var body: some View {
        Group {
            if let code = block as? CodeBlock {
                VStack(alignment: .leading, spacing: 6) {
                    SwiftUI.Text(code.language ?? "Code").font(.caption).foregroundStyle(.secondary)
                    OutputView(text: code.code)
                }
            } else if let heading = block as? Heading {
                inline(heading.children.map { $0.format() }.joined()).font(heading.level <= 2 ? .title3.weight(.semibold) : .headline)
            } else if block is UnorderedList || block is OrderedList {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(block.children.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SwiftUI.Text(block is OrderedList ? "\(UInt(index) + (block as! OrderedList).startIndex)." : "•")
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in MarkdownBlock(block: child) }
                            }
                        }
                    }
                }
            } else if block is BlockQuote {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(block.children.enumerated()), id: \.offset) { _, child in MarkdownBlock(block: child) }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            } else if block is ThematicBreak { Divider() }
            else if block is Paragraph { inline(block.children.map { $0.format() }.joined()) }
            else { SwiftUI.Text(block.format()) }
        }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ source: String) -> some View {
        SwiftUI.Text((try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct OutputView: View {
    let text: String
    var running = false
    var diff = false
    @State private var all = false
    private var lines: [String] {
        text.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .components(separatedBy: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if diff { SwiftUI.Text("Changes").font(.caption) }
                else if running { SwiftUI.Text("Latest output").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    .labelStyle(.iconOnly).help("Copy all output")
            }
            ScrollView(all ? [.horizontal, .vertical] : [.horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((all ? lines : running ? Array(lines.suffix(12)) : Array(lines.prefix(12))).enumerated()), id: \.offset) { _, line in
                        let addition = diff && line.hasPrefix("+") && !line.hasPrefix("+++")
                        let deletion = diff && line.hasPrefix("-") && !line.hasPrefix("---")
                        SwiftUI.Text(line.isEmpty ? " " : line).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(addition ? Color(nsColor: .systemGreen) : deletion ? Color(nsColor: .systemRed) : Color.primary)
                            .background(addition ? Color(nsColor: .systemGreen).opacity(0.08) : deletion ? Color(nsColor: .systemRed).opacity(0.08) : .clear)
                            .textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(all ? 480 : 240, CGFloat(all ? lines.count : min(12, lines.count)) * ceil(NSFont.preferredFont(forTextStyle: .callout).ascender - NSFont.preferredFont(forTextStyle: .callout).descender + NSFont.preferredFont(forTextStyle: .callout).leading)))
            if lines.count > 12 { Button(all ? "Show less" : "Show all \(lines.count) lines") { all.toggle() }.font(.caption) }
        }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

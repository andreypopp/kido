import SwiftUI
import Markdown

final class ParsedMarkdown {
    final class Block {
        let markup: any Markup
        let inline: AttributedString
        let children: [Block]
        init(_ markup: any Markup) {
            self.markup = markup
            inline = markup is Paragraph || markup is Heading ? attributed(markup) : AttributedString()
            children = markup is UnorderedList || markup is OrderedList || markup is ListItem || markup is BlockQuote ? markup.children.map(Block.init) : []
        }
    }
    private var text = ""
    private var offset = 0
    private var completed: [Block] = [], tail: [Block] = []
    func blocks(_ value: String) -> [Block] {
        guard text != value else { return completed + tail }
        if !value.hasPrefix(text) { offset = 0; completed = [] }
        text = value
        let suffix = String(decoding: value.utf8.dropFirst(offset), as: UTF8.self), document = Document(parsing: suffix)
        let blocks = Array(document.children)
        if blocks.count > 1, let line = blocks.last?.range?.lowerBound.line {
            let lines = suffix.split(separator: "\n", omittingEmptySubsequences: false)
            offset += lines.prefix(line - 1).reduce(0) { $0 + $1.utf8.count + 1 }; completed += blocks.dropLast().map(Block.init)
            tail = blocks.suffix(1).map(Block.init)
        } else { tail = blocks.map(Block.init) }
        return completed + tail
    }
}

func attributed(_ markup: any Markup) -> AttributedString {
    if let text = markup as? Markdown.Text { return AttributedString(text.string) }
    if markup is SoftBreak { return AttributedString(" ") }
    if markup is LineBreak { return AttributedString("\n") }
    if let code = markup as? InlineCode { var value = AttributedString(code.code); value.font = .system(.body, design: .monospaced); return value }
    var value = markup.children.reduce(into: AttributedString()) { $0 += attributed($1) }
    if markup is Strong || markup is Emphasis {
        for run in value.runs { value[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(markup is Strong ? .stronglyEmphasized : .emphasized) }
    }
    if markup is Strikethrough { value.strikethroughStyle = .single }
    if let link = markup as? Markdown.Link, let destination = link.destination { value.link = URL(string: destination) }
    return value
}

struct MarkdownBody: View {
    let text: String
    @State private var parsed = ParsedMarkdown()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(parsed.blocks(text).enumerated()), id: \.offset) { _, block in MarkdownBlock(block: block).equatable() }
        }.font(.body).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in ["http", "https", "mailto"].contains(url.scheme ?? "") ? .systemAction : .discarded })
    }
}

private struct MarkdownBlock: View, @MainActor Equatable {
    let block: ParsedMarkdown.Block
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.block === rhs.block }
    var body: some View {
        Group {
            if let code = block.markup as? CodeBlock {
                VStack(alignment: .leading, spacing: 4) {
                    SwiftUI.Text(code.language ?? "Code").font(.caption).foregroundStyle(.secondary)
                    OutputView(text: code.code)
                }
            } else if let heading = block.markup as? Heading { SwiftUI.Text(block.inline).font(heading.level <= 2 ? .title3.weight(.semibold) : .headline) }
            else if block.markup is UnorderedList || block.markup is OrderedList {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(block.children.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SwiftUI.Text((block.markup as? OrderedList).map { "\(UInt(index) + $0.startIndex)." } ?? "•")
                            VStack(alignment: .leading, spacing: 6) { ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in MarkdownBlock(block: child) } }
                        }
                    }
                }
            } else if block.markup is BlockQuote {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 8) { ForEach(Array(block.children.enumerated()), id: \.offset) { _, child in MarkdownBlock(block: child) } }
                }.fixedSize(horizontal: false, vertical: true)
            } else if block.markup is ThematicBreak { Divider() }
            else if block.markup is Paragraph { SwiftUI.Text(block.inline).fixedSize(horizontal: false, vertical: true) }
            else { SwiftUI.Text(block.markup.format()) }
        }.multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OutputView: View {
    let text: String
    var running = false
    var diff = false
    @State private var all = false
    @State private var cache = (text: "", lines: [String]())
    var body: some View {
        let lines = cache.text == text ? cache.lines : text.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression).components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 6) {
            if diff || running { SwiftUI.Text(diff ? "Changes" : "Latest output").font(.caption).foregroundStyle(.secondary) }
            ScrollView(all ? [.horizontal, .vertical] : [.horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array((all ? lines : running ? Array(lines.suffix(12)) : Array(lines.prefix(12))).enumerated()), id: \.offset) { _, line in
                        let addition = diff && line.hasPrefix("+") && !line.hasPrefix("+++"), deletion = diff && line.hasPrefix("-") && !line.hasPrefix("---")
                        SwiftUI.Text(line.isEmpty ? " " : line).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(addition ? Color(nsColor: .systemGreen) : deletion ? Color(nsColor: .systemRed) : Color.primary)
                            .background(addition ? Color(nsColor: .systemGreen).opacity(0.08) : deletion ? Color(nsColor: .systemRed).opacity(0.08) : .clear).textSelection(.enabled)
                    }
                }.padding(.trailing, 24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(all ? 480 : 240, CGFloat(all ? lines.count : min(12, lines.count)) * ceil(NSFont.preferredFont(forTextStyle: .callout).ascender - NSFont.preferredFont(forTextStyle: .callout).descender + NSFont.preferredFont(forTextStyle: .callout).leading)))
            if lines.count > 12 { Button(all ? "Show less" : "Show all \(lines.count) lines") { all.toggle() }.font(.caption) }
        }.padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small).help("Copy all output").padding(6)
            }.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: text, initial: true) { _, _ in cache = (text, lines) }
    }
}

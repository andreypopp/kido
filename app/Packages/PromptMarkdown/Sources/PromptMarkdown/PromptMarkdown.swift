import AppKit
import Markdown

public let lineHeight: CGFloat = 18
@MainActor public let baseAttributes: [NSAttributedString.Key: Any] = {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    return [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph.copy(), .baselineOffset: -1]
}()

public struct Rendering {
    public let text: NSAttributedString
    public let quoteLines: [NSRange]
    public let codeRanges: [NSRange]
}

private func utf16Range(_ range: SourceRange, text: String, lines: [(utf8: Int, utf16: Int)]) -> NSRange? {
    func offset(_ location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= lines.count, location.column > 0 else { return nil }
        let line = lines[location.line - 1]
        let bytes = text.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: line.utf8)
        let limit = location.line < lines.count ? bytes.index(bytes.startIndex, offsetBy: lines[location.line].utf8 - 1) : bytes.endIndex
        guard let index = bytes.index(start, offsetBy: location.column - 1, limitedBy: limit),
              let position = index.samePosition(in: text.utf16),
              let first = start.samePosition(in: text.utf16) else { return nil }
        return line.utf16 + text.utf16.distance(from: first, to: position)
    }
    guard let start = offset(range.lowerBound), let end = offset(range.upperBound), end >= start else { return nil }
    return NSRange(location: start, length: end - start)
}

@MainActor public func render(_ text: String) -> Rendering {
    let base = baseAttributes[.font] as! NSFont
    let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
    let source = text as NSString
    var lines = [(utf8: 0, utf16: 0)]
    var utf8 = 0, utf16 = 0, carriageReturn = false
    for scalar in text.unicodeScalars {
        utf8 += scalar.utf8.count
        utf16 += scalar.utf16.count
        if scalar == "\r" { lines.append((utf8, utf16)) }
        else if scalar == "\n" {
            if carriageReturn { lines[lines.count - 1] = (utf8, utf16) }
            else { lines.append((utf8, utf16)) }
        }
        carriageReturn = scalar == "\r"
    }
    var quotes = IndexSet()
    var codes: [NSRange] = []
    func visit(_ node: any Markup) {
        if let sourceRange = node.range, let range = utf16Range(sourceRange, text: text, lines: lines) {
            if node is BlockQuote {
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                var start = source.lineRange(for: NSRange(location: range.location, length: 0)).location
                while start < NSMaxRange(range) {
                    let line = source.lineRange(for: NSRange(location: start, length: 0))
                    if source.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, range: line).location != NSNotFound {
                        quotes.insert(start)
                    }
                    var cursor = start
                    while cursor < NSMaxRange(line), source.character(at: cursor) == 32 { cursor += 1 }
                    while cursor < NSMaxRange(line), source.character(at: cursor) == 62 {
                        var end = cursor + 1
                        if end < source.length, source.character(at: end) == 32 { end += 1 }
                        let marker = NSRange(location: cursor, length: end - cursor)
                        result.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
                        cursor = end
                    }
                    start = NSMaxRange(line)
                }
            } else if node is Heading || node is Strong {
                result.enumerateAttribute(.font, in: range) { value, span, _ in
                    let current = value as? NSFont ?? base
                    var font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                    if NSFontManager.shared.traits(of: current).contains(.italicFontMask) {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    result.addAttribute(.font, value: font, range: span)
                }
            } else if node is Emphasis {
                result.enumerateAttribute(.font, in: range) { value, span, _ in
                    let font = value as? NSFont ?? base
                    result.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: span)
                }
            } else if node is InlineCode {
                result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: range)
                codes.append(range)
            }
        }
        for child in node.children { visit(child) }
    }
    visit(Document(parsing: text))
    return Rendering(text: result, quoteLines: quotes.map { source.lineRange(for: NSRange(location: $0, length: 0)) },
                     codeRanges: codes)
}

public func appendQuote(to text: String, selection: String) -> (text: String, caret: Int) {
    var result = text
    if !result.isEmpty && !result.hasSuffix("\n\n") {
        result += result.hasSuffix("\n") ? "\n" : "\n\n"
    }
    let caret = result.utf16.count
    result += "\n" + selection.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    return (result, caret)
}

@MainActor public func quoteBarRects(lines: [NSRange], layoutManager: NSLayoutManager,
                                     glyphRange: NSRange, origin: NSPoint) -> [NSRect] {
    var rects: [NSRect] = []
    let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    for line in lines where NSIntersectionRange(line, characters).length > 0 {
        let glyphs = NSIntersectionRange(layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil), glyphRange)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, fragment, _ in
            guard NSIntersectionRange(fragment, glyphs).length > 0 else { return }
            let characters = layoutManager.characterRange(forGlyphRange: fragment, actualGlyphRange: nil)
            guard NSIntersectionRange(characters, line).length > 0 else { return }
            let bar = NSRect(x: origin.x - 8, y: origin.y + rect.minY, width: 2, height: lineHeight)
            if rects.last != bar { rects.append(bar) }
        }
    }
    return rects
}

@MainActor public func codeFillRects(ranges: [NSRange], layoutManager: NSLayoutManager,
                                     textContainer: NSTextContainer, glyphRange: NSRange, origin: NSPoint) -> [NSRect] {
    var rects: [NSRect] = []
    let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    for range in ranges where NSIntersectionRange(range, characters).length > 0 {
        let glyphs = NSIntersectionRange(layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphRange)
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                             in: textContainer) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0))
        }
    }
    return rects
}

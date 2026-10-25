import AppKit
import XCTest
@testable import PromptMarkdown

final class PromptMarkdownTests: XCTestCase {
    @MainActor func testStylesAndOffsets() {
        let text = "# Heading\n\né😀 **bold** *italic* `code`\n\n> quoted\nlazy\n\nplain"
        let result = render(text)
        XCTAssertEqual(lineHeight, 18)
        XCTAssertEqual(result.text.attributes(at: 10, effectiveRange: nil) as NSDictionary, baseAttributes as NSDictionary)
        XCTAssertEqual(result.text.string, text)
        let source = text as NSString
        for token in ["# Heading", "**bold**"] {
            let font = result.text.attribute(.font, at: source.range(of: token).location, effectiveRange: nil) as! NSFont
            XCTAssertEqual(font, NSFont.systemFont(ofSize: 13, weight: .semibold))
        }
        let italic = result.text.attribute(.font, at: source.range(of: "*italic*").location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        XCTAssertEqual(result.codeRanges.map { source.substring(with: $0) }, ["`code`"])
        XCTAssertEqual(result.quoteLines.map { source.substring(with: $0) }, ["> quoted\n", "lazy\n"])
        XCTAssertEqual(result.text.attribute(.foregroundColor, at: source.range(of: "> ").location, effectiveRange: nil) as? NSColor, .tertiaryLabelColor)
        for index in 0..<source.length {
            let paragraph = result.text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as! NSParagraphStyle
            XCTAssertEqual(paragraph.minimumLineHeight, 18)
            XCTAssertEqual(paragraph.maximumLineHeight, 18)
            XCTAssertEqual(result.text.attribute(.baselineOffset, at: index, effectiveRange: nil) as? Int, -1)
        }
        XCTAssertEqual(result.text.attribute(.foregroundColor, at: source.range(of: "lazy").location, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
    }

    @MainActor func testNestedEmphasisKeepsSemibold() {
        for text in ["***x***", "**_x_**", "# *x*"] {
            let rendered = render(text).text
            let font = rendered.attribute(.font, at: (text as NSString).range(of: "x").location, effectiveRange: nil) as! NSFont
            let expected = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13, weight: .semibold), toHaveTrait: .italicFontMask)
            XCTAssertEqual(font, expected, text)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask), text)
        }
    }

    @MainActor func testSeparateQuotes() {
        let result = render("> one\n> two\n\n> three")
        XCTAssertEqual(result.quoteLines.count, 3)
        let separated = render("> one\n\n> two")
        XCTAssertEqual(separated.quoteLines.count, 2)
        let unicode = render("é😀\n\n> 🐈 **été** `λ`")
        XCTAssertEqual(unicode.text.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .tertiaryLabelColor)
        XCTAssertEqual(unicode.codeRanges.map { (unicode.text.string as NSString).substring(with: $0) }, ["`λ`"])
    }

    @MainActor func testLineEndingsKeepTheirRanges() {
        let text = "plain\r\n**bold**\r`code`\n> q"
        let rendered = render(text)
        XCTAssertEqual(rendered.text.string, text)
        XCTAssertEqual(rendered.text.attribute(.font, at: 7, effectiveRange: nil) as? NSFont, NSFont.systemFont(ofSize: 13, weight: .semibold))
        XCTAssertEqual(rendered.codeRanges, [NSRange(location: 16, length: 6)])
        XCTAssertEqual(rendered.quoteLines, [NSRange(location: 23, length: 3)])
        XCTAssertEqual(rendered.text.attribute(.foregroundColor, at: 23, effectiveRange: nil) as? NSColor, .tertiaryLabelColor)
    }

    func testAppend() {
        XCTAssertEqual(appendQuote(to: "", selection: "a\n\nb").text, "\n> a\n>\n> b")
        for text in ["plain", "plain\n", "plain\n\n"] {
            let result = appendQuote(to: text, selection: "a")
            XCTAssertEqual(result.text, "plain\n\n\n> a")
            XCTAssertEqual(result.caret, 7)
        }
        let first = appendQuote(to: "> old", selection: "a")
        XCTAssertEqual(first.text, "> old\n\n\n> a")
        let second = appendQuote(to: first.text, selection: "a")
        XCTAssertEqual(second.text, "> old\n\n\n> a\n\n\n> a")
        XCTAssertEqual((second.text as NSString).substring(from: second.caret), "\n> a")
    }

    @MainActor func testRealTextKit() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 400))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let result = render("plain\n\n> quote\n> next\n\n`code`")
        storage.setAttributedString(result.text)
        manager.ensureLayout(for: container)
        let marker = (result.text.string as NSString).range(of: "> quote").location
        let glyph = manager.glyphIndexForCharacter(at: marker)
        XCTAssertFalse(manager.propertyForGlyph(at: glyph).contains(.null))
        XCTAssertGreaterThan(manager.location(forGlyphAt: glyph + 2).x, manager.location(forGlyphAt: glyph).x)
        XCTAssertEqual(quoteBarRects(lines: result.quoteLines, layoutManager: manager, glyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), origin: NSPoint(x: 16, y: 10)).map(\.minX), [8, 8])
        XCTAssertFalse(codeFillRects(ranges: result.codeRanges, layoutManager: manager, textContainer: container, glyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), origin: .zero).isEmpty)
        let code = manager.glyphRange(forCharacterRange: result.codeRanges[0], actualCharacterRange: nil)
        XCTAssertTrue(quoteBarRects(lines: result.quoteLines, layoutManager: manager, glyphRange: code, origin: .zero).isEmpty)
        let quote = manager.glyphRange(forCharacterRange: result.quoteLines[0], actualCharacterRange: nil)
        XCTAssertTrue(codeFillRects(ranges: result.codeRanges, layoutManager: manager, textContainer: container, glyphRange: quote, origin: .zero).isEmpty)
        XCTAssertEqual(quoteBarRects(lines: result.quoteLines, layoutManager: manager, glyphRange: quote, origin: .zero).count, 1)
        XCTAssertEqual(view.string, result.text.string)
    }
}

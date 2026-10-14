import AppKit
import GhosttyKit
import ImageIO
import TmuxControl
import UniformTypeIdentifiers
import XCTest
@testable import Kido

@MainActor final class SyntheticDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 0 } set {} }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

func pngData(width: Int, height: Int, type: UTType = .png, compression: Int? = nil) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    let properties = compression.map { [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: $0]] as CFDictionary }
    CGImageDestinationAddImage(destination, context.makeImage()!, properties)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@MainActor func drop(_ pane: PaneView, _ board: NSPasteboard, _ paths: [String]) {
    board.clearContents()
    board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
    XCTAssertTrue(pane.performDragOperation(SyntheticDrag(board)))
}

@MainActor final class UploadTests: VisualTestCase {
    private final class Input { var data = Data() }

    private func localPane() throws -> (owner: WindowOwner, pane: PaneView, board: NSPasteboard, input: Input, root: String) {
        let root = "/tmp/ku-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: root + "/files", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let board = NSPasteboard(name: .init("kido-upload-test-\(UUID().uuidString)"))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testUploadBase = root + "/state"
        let input = Input()
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { input.data.append($0) })
        owner.window.contentView = pane
        owner.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.window.orderFront(nil)
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        addTeardownBlock { @MainActor in
            pane.dispose()
            owner.close()
            board.releaseGlobally()
            try? FileManager.default.removeItem(atPath: root)
        }
        return (owner, pane, board, input, root)
    }

    private func notice(_ owner: WindowOwner) -> String? {
        defer { if owner.preparedAlert != nil { owner.respondToAlert(.alertFirstButtonReturn) } }
        return owner.preparedAlert.map { $0.alert.messageText + "\n" + $0.alert.informativeText }
    }

    func testLocalDropPastesOriginalPathsThroughThePastePath() async throws {
        let (owner, pane, board, input, root) = try localPane()
        let runtime = pane.runtime
        let fm = FileManager.default
        let plain = root + "/files/a.txt", quoted = root + "/files/it's b.txt"
        for path in [plain, quoted] { XCTAssertTrue(fm.createFile(atPath: path, contents: Data("x".utf8))) }
        XCTAssertTrue(pane.feed(Data("\u{1b}[?2004h".utf8)))
        try await drain(runtime)
        drop(pane, board, [plain, quoted])
        try await drain(runtime)
        XCTAssertEqual(String(decoding: input.data, as: UTF8.self), "\u{1b}[200~\(plain) '\(root)/files/it'\"'\"'s b.txt'\u{1b}[201~")
        XCTAssertNil(notice(owner))
        XCTAssertTrue(pane.feed(Data("\u{1b}[?2004l".utf8)))
        try await drain(runtime)
        input.data = Data()
        drop(pane, board, [plain])
        try await drain(runtime)
        XCTAssertEqual(String(decoding: input.data, as: UTF8.self), plain, "unbracketed: the path alone, no Enter")
        input.data = Data()

        let newline = root + "/files/bad\nname"
        XCTAssertTrue(fm.createFile(atPath: newline, contents: Data()))
        drop(pane, board, [plain, newline])
        try await drain(runtime)
        XCTAssertEqual(notice(owner)?.hasPrefix("Kido did not paste the path"), true, "refused by the path validation, not elsewhere")
        XCTAssertEqual(input.data, Data())

        try fm.createSymbolicLink(atPath: root + "/files/link", withDestinationPath: plain)
        try fm.createDirectory(atPath: root + "/files/Thing.app", withIntermediateDirectories: false)
        let alias = try URL(fileURLWithPath: plain).bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(alias, to: URL(fileURLWithPath: root + "/files/alias"))
        for path in [root + "/files/link", root + "/files", root + "/files/Thing.app", root + "/files/alias"] {
            drop(pane, board, [plain, path])
            try await drain(runtime)
            XCTAssertEqual(notice(owner)?.contains("is not a regular file"), true, path)
        }
        board.clearContents()
        board.setData(Data(), forType: NSPasteboard.PasteboardType(NSFilePromiseReceiver.readableDraggedTypes[0]))
        XCTAssertTrue(pane.performDragOperation(SyntheticDrag(board)))
        try await drain(runtime)
        XCTAssertEqual(notice(owner), "Kido did not upload\nKido only uploads files that already exist on disk.")
        drop(pane, board, Array(repeating: plain, count: 17))
        try await drain(runtime)
        XCTAssertEqual(notice(owner), "Kido did not upload\nKido uploads at most 16 files at once.")
        XCTAssertEqual(input.data, Data(), "no refusal pastes anything")
        drop(pane, board, Array(repeating: plain, count: 16))
        try await drain(runtime)
        XCTAssertEqual(String(decoding: input.data, as: UTF8.self), Array(repeating: plain, count: 16).joined(separator: " "))
    }

    func testEscapeDuringImagePreparationPastesNothing() async throws {
        let (owner, pane, board, input, root) = try localPane()
        func published() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root + "/state/drops")) ?? [] }
        board.clearContents()
        board.setData(pngData(width: 2, height: 2, type: .tiff), forType: .tiff)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        pane.keyDown(with: escape)
        try await Task.sleep(for: .seconds(1))
        try await drain(pane.runtime)
        XCTAssertEqual(input.data, Data(), "a cancelled image preparation pastes nothing")
        XCTAssertEqual(published(), [])
        XCTAssertNil(owner.preparedAlert)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
        try await wait("the same paste without Escape inserts a path") { input.data.count > 12 }
        XCTAssertEqual(published().count, 1)
    }

    func testImagePasteUploadsOnePrivatePNGAndPastesItsPath() async throws {
        let (owner, pane, board, input, root) = try localPane()
        let runtime = pane.runtime
        let fm = FileManager.default
        func published() -> [String] { ((try? fm.contentsOfDirectory(atPath: root + "/state/drops")) ?? []).sorted() }
        try fm.createDirectory(atPath: root + "/state", withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertTrue(pane.feed(Data("\u{1b}[?2004h".utf8)))
        let png = pngData(width: 3, height: 2)
        board.clearContents()
        board.setData(png, forType: .png)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
        try await wait("image path pasted") { input.data.count > 12 }
        let text = String(decoding: input.data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("\u{1b}[200~\(root)/state/drops/") && text.hasSuffix(".png\u{1b}[201~"), text)
        let path = String(text.dropFirst(6).dropLast(6))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
        XCTAssertEqual(try fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try fm.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(published().count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent), [(path as NSString).lastPathComponent])

        input.data = Data()
        board.clearContents()
        board.setData(pngData(width: 2, height: 2, type: .tiff), forType: .tiff)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
        try await wait("TIFF converted and pasted") { input.data.count > 12 }
        let converted = try Data(contentsOf: URL(fileURLWithPath: String(String(decoding: input.data, as: UTF8.self).dropFirst(6).dropLast(6))))
        XCTAssertEqual(converted.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(published().count, 2)

        input.data = Data()
        board.clearContents()
        let huge = pngData(width: 6400, height: 6400, type: .tiff, compression: 5)
        XCTAssertLessThan(huge.count, 64 << 20)
        board.setData(huge, forType: .tiff)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
        try await wait("oversized TIFF refused") { owner.preparedAlert != nil }
        XCTAssertEqual(notice(owner)?.contains("40 million pixels"), true)
        XCTAssertEqual(input.data, Data())
        XCTAssertEqual(published().count, 2)

        board.clearContents()
        board.setString("plain text wins", forType: .string)
        board.setData(png, forType: .png)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
        try await drain(runtime)
        XCTAssertEqual(String(decoding: input.data, as: UTF8.self), "\u{1b}[200~plain text wins\u{1b}[201~")
        XCTAssertEqual(published().count, 2)

        input.data = Data()
        owner.upload(.success(try await Upload(image: png)), to: pane)
        pane.dispose()
        try await wait("the transfer published although its pane closed") { published().count == 3 && owner.preparedAlert != nil }
        XCTAssertEqual(notice(owner)?.hasPrefix("The pane closed before the upload finished"), true)
        XCTAssertEqual(input.data, Data())
    }
}

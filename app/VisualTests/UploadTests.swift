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

private final class PromisedFile: NSFilePromiseReceiver, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (URL, OperationQueue, (URL, Error?) -> Void)?
    private var replied = false
    var destination: URL? { lock.withLock { pending?.0 } }
    var didReply: Bool { lock.withLock { replied } }
    var stalled = false
    var size = 8
    var name = "promised.txt"
    override var fileTypes: [String] { [UTType.plainText.identifier] }
    override var fileNames: [String] { [name] }
    override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:], operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        lock.withLock { pending = (destinationDir.appendingPathComponent(name), operationQueue, reader) }
        if !stalled { reply() }
    }
    func reply(recreate: Bool = false) {
        guard let queue = lock.withLock({ pending?.1 }) else { return }
        queue.addOperation { [self] in
            guard let (destination, _, reader) = lock.withLock({ pending }) else { return }
            do {
                if recreate { try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                try Data("promised".utf8).write(to: destination)
                let file = try FileHandle(forWritingTo: destination)
                try file.truncate(atOffset: UInt64(size))
                try file.close()
                reader(destination, nil)
            } catch { reader(destination, error) }
            lock.withLock { replied = true }
        }
    }
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
            Upload.sweepPromises()
            rmdir(Upload.promiseRoot.path)
            board.releaseGlobally()
            try? FileManager.default.removeItem(atPath: root)
        }
        return (owner, pane, board, input, root)
    }

    private func removed(_ promise: PromisedFile) -> Bool {
        promise.destination.map { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) } ?? false
    }

    private func notice(_ owner: WindowOwner) -> String? {
        defer { if owner.preparedAlert != nil { owner.respondToAlert(.alertFirstButtonReturn) } }
        return owner.preparedAlert.map { $0.alert.messageText + "\n" + $0.alert.informativeText }
    }

    func testPromisedDropCopiesFile() async throws {
        let (owner, pane, _, input, root) = try localPane()
        let writer = PromisedFile()
        owner.uploadPromises([writer], to: pane)
        try await wait("promise transfer", within: 5) { !owner.uploading(pane) }
        try await drain(pane.runtime)
        XCTAssertNil(notice(owner))
        let path = String(decoding: input.data, as: UTF8.self)
        XCTAssertTrue(path.hasPrefix(root + "/state/drops/"), path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "promised")
        let temporary = try XCTUnwrap(writer.destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
    }

    func testPromisedDropCancelRemovesDirectoryAndIgnoresLateReader() async throws {
        let (owner, pane, _, input, _) = try localPane()
        let promise = PromisedFile()
        promise.stalled = true
        owner.uploadPromises([promise], to: pane)
        try await wait("promise requested", within: 2) { promise.destination != nil }
        let destination = try XCTUnwrap(promise.destination)
        let directory = destination.deletingLastPathComponent()
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        pane.keyDown(with: escape)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Escape must clean synchronously")
        XCTAssertFalse(owner.uploading(pane))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        promise.reply(recreate: true)
        try await wait("late write removed", within: 2) { promise.didReply && !FileManager.default.fileExists(atPath: directory.path) }
        try await drain(pane.runtime)
        XCTAssertTrue(input.data.isEmpty)
        XCTAssertNil(notice(owner))
    }

    func testTooLargePromiseIsRefusedAndRemoved() async throws {
        let (owner, pane, _, input, _) = try localPane()
        let promise = PromisedFile()
        promise.size = Upload.fileLimit + 1
        owner.uploadPromises([promise], to: pane)
        try await wait("oversized promise refused", within: 2) { !owner.uploading(pane) }
        XCTAssertTrue(try XCTUnwrap(notice(owner)).contains("larger than 64 MiB"))
        XCTAssertTrue(input.data.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(promise.destination).deletingLastPathComponent().path))
    }

    func testSeveralPromisedFilesReplyOnTheOperationQueue() async throws {
        let (owner, pane, _, input, root) = try localPane()
        let promises = (0..<3).map { index in
            let promise = PromisedFile()
            promise.name = "promised-\(index).txt"
            return promise
        }
        owner.uploadPromises(promises, to: pane)
        try await wait("three promise transfers", within: 5) { !owner.uploading(pane) }
        XCTAssertTrue(promises.allSatisfy(\.didReply))
        XCTAssertNil(notice(owner))
        let paths = String(decoding: input.data, as: UTF8.self).split(separator: " ")
        XCTAssertEqual(paths.count, 3)
        for path in paths {
            XCTAssertTrue(path.hasPrefix(root + "/state/drops/"))
            XCTAssertEqual(try String(contentsOfFile: String(path), encoding: .utf8), "promised")
        }
        XCTAssertTrue(promises.allSatisfy(removed))
    }

    func testPromiseReplyAfterDeadlineCannotPasteOrLeaveFiles() async throws {
        let (owner, pane, _, input, _) = try localPane()
        let old = Upload.promiseTimeout
        Upload.promiseTimeout = 0.02
        defer { Upload.promiseTimeout = old }
        let promise = PromisedFile()
        promise.stalled = true
        owner.uploadPromises([promise], to: pane)
        try await wait("promise requested", within: 2) { promise.destination != nil }
        try await wait("promise expired", within: 2) { !owner.uploading(pane) && owner.preparedAlert != nil }
        promise.reply(recreate: true)
        try await wait("late reply cleaned", within: 2) { promise.didReply && !owner.uploading(pane) && self.removed(promise) }
        Upload.promiseTimeout = old
        XCTAssertTrue(try XCTUnwrap(notice(owner)).contains("did not provide the files within 30 seconds"))
        XCTAssertTrue(input.data.isEmpty)
    }

    func testDisposedPaneCancelsPromiseSynchronously() async throws {
        let (owner, pane, _, input, _) = try localPane()
        let promise = PromisedFile()
        promise.stalled = true
        owner.uploadPromises([promise], to: pane)
        try await wait("promise requested", within: 2) { promise.destination != nil }
        pane.dispose()
        XCTAssertFalse(owner.uploading(pane))
        XCTAssertTrue(removed(promise))
        promise.reply(recreate: true)
        try await wait("disposed pane late reply cleaned", within: 2) { promise.didReply && self.removed(promise) }
        XCTAssertTrue(input.data.isEmpty)
        XCTAssertNil(notice(owner))
    }

    func testPaneThatRefusesInputDoesNotTransferPromise() async throws {
        let (owner, pane, _, input, root) = try localPane()
        let promise = PromisedFile()
        promise.stalled = true
        owner.uploadPromises([promise], to: pane)
        try await wait("promise requested", within: 2) { promise.destination != nil }
        pane.visualRefuseInput()
        promise.reply()
        try await wait("promise refused", within: 2) { !owner.uploading(pane) }
        XCTAssertTrue(input.data.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/state/drops"))
        XCTAssertTrue(removed(promise))
        XCTAssertNil(notice(owner))
    }

    func testTooManyPromisesAreRefusedBeforeCallingReceivers() async throws {
        let (owner, pane, _, input, _) = try localPane()
        let promises = (0...Upload.countLimit).map { _ in PromisedFile() }
        owner.uploadPromises(promises, to: pane)
        try await wait("promise count refused", within: 2) { !owner.uploading(pane) }
        XCTAssertTrue(promises.allSatisfy { $0.destination == nil })
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: Upload.promiseDirectory.path).isEmpty) ?? true)
        XCTAssertTrue(try XCTUnwrap(notice(owner)).contains("at most 16 files"))
        XCTAssertTrue(input.data.isEmpty)
    }

    func testOwnerInvalidationRemovesPromisesSynchronously() async throws {
        let (owner, pane, _, input, _) = try localPane()
        let promise = PromisedFile()
        promise.stalled = true
        owner.uploadPromises([promise], to: pane)
        try await wait("promise requested", within: 2) { promise.destination != nil }
        owner.close()
        XCTAssertTrue(removed(promise))
        XCTAssertFalse(owner.uploading(pane))
        promise.reply(recreate: true)
        try await wait("closed owner late reply cleaned", within: 2) { promise.didReply && self.removed(promise) }
        XCTAssertTrue(input.data.isEmpty)
    }

    func testPromiseSweepsPreserveAnotherProcessLock() async throws {
        let (owner, pane, _, input, root) = try localPane()
        let promise = PromisedFile()
        promise.stalled = true
        owner.uploadPromises([promise], to: pane)
        try await wait("own promise requested", within: 2) { promise.destination != nil }
        let fm = FileManager.default, parent = Upload.promiseRoot
        let held = parent.appendingPathComponent("other-process"), stale = parent.appendingPathComponent("stale-process")
        defer { try? fm.removeItem(at: held); try? fm.removeItem(at: stale) }
        for directory in [held, stale] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("keep".utf8).write(to: directory.appendingPathComponent("file"))
        }
        let ready = root + "/locked"
        let child = try Child("/usr/bin/python3", ["-I", "-c", "import fcntl,os,sys,time; fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW); fcntl.flock(fd,fcntl.LOCK_EX); open(sys.argv[2],'w').close(); time.sleep(10)", held.path, ready], stdout: Pipe())
        var failure: Error?
        do {
            try await wait("other process locked its directory", within: 3) { fm.fileExists(atPath: ready) }
            Upload.sweepPromises(launch: true)
            XCTAssertTrue(fm.fileExists(atPath: held.appendingPathComponent("file").path), "launch sweep removed another process's locked drop")
            XCTAssertFalse(fm.fileExists(atPath: stale.path))
            XCTAssertFalse(removed(promise), "launch sweep must preserve this process's active drop")
            Upload.sweepPromises()
            XCTAssertTrue(fm.fileExists(atPath: held.appendingPathComponent("file").path), "quit sweep removed another process's locked drop")
            XCTAssertFalse(fm.fileExists(atPath: Upload.promiseDirectory.path))
            try await wait("quit cancelled own promise", within: 2) { !owner.uploading(pane) }
            XCTAssertTrue(input.data.isEmpty)
        } catch { failure = error }
        child.stop()
        let reaped = await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning: child.ended.wait(timeout: .now() + 3) == .success) }
        }
        XCTAssertTrue(reaped, "the lock helper must be killed and reaped within 3 seconds")
        if let failure { throw failure }
        Upload.sweepPromises(launch: true)
        XCTAssertFalse(fm.fileExists(atPath: held.path), "a crashed or exited process no longer holds its lock")
    }

    func testPromiseSweepDoesNotFollowParentOrChildSymlinks() throws {
        let fm = FileManager.default, parent = Upload.promiseRoot
        let outside = parent.appendingPathExtension("outside")
        defer { try? fm.removeItem(at: parent); try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sentinel = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        try fm.createSymbolicLink(at: parent, withDestinationURL: outside)
        Upload.sweepPromises(launch: true)
        Upload.sweepPromises()
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: parent.path), outside.path)
        try fm.removeItem(at: parent)
        try fm.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = parent.appendingPathComponent("symlink")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        Upload.sweepPromises(launch: true)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), outside.path)
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

    func testRecordedSSHCommandComputesItsBaseOnTheFarSideUnderAnyLoginShell() async throws {
        let root = "/tmp/ku-far-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: root + "/home", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        let png = pngData(width: 2, height: 2), plan = try await Upload(image: png)
        let shells = ["/bin/sh", "/bin/tcsh", "/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"].filter(FileManager.default.isExecutableFile)
        XCTAssertTrue(shells.contains("/bin/tcsh"))
        for shell in shells {
            for (environment, base) in [(["HOME": root + "/home"], root + "/home/.local/state/kido-app"),
                                        (["HOME": root + "/home", "XDG_STATE_HOME": root + "/xdg"], root + "/xdg/kido-app")] {
                let id = UUID().uuidString.lowercased()
                let command = try XCTUnwrap(SSH.recorded(["localhost"], plan.arguments(base: "", id: id)).arguments.last)
                XCTAssertFalse(command.contains("\n"))
                let run = try await Child.run(shell, ["-c", command], env: environment.merging(["PATH": "/usr/bin:/bin"]) { $1 }, input: plan.send)
                XCTAssertEqual(run.status, 0, shell + ": " + run.err)
                XCTAssertEqual(run.out, base + "/drops/" + id, shell)
                XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: run.out + "/" + plan.sources[0].name)), png, shell)
            }
        }
        let multiline = "exec " + (["/bin/sh", "-c", Upload.script, "kido-drop", "", "id"]).map(SSH.quote).joined(separator: " ")
        let old = try await Child.run("/bin/tcsh", ["-c", multiline], env: ["HOME": root + "/home", "PATH": "/usr/bin:/bin"])
        XCTAssertNotEqual(old.status, 0, "negative control: the script quoted across lines fails under tcsh")
        XCTAssertTrue(old.err.contains("Unmatched"), old.err)
    }

    func testEscapeDuringImagePreparationPastesNothing() async throws {
        let (owner, pane, board, input, root) = try localPane()
        defer { Upload.visualImagePreparation = nil }
        func published() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root + "/state/drops")) ?? [] }
        let preparations = WindowOwner.visualPreparedUploads
        var preparation: CheckedContinuation<Void, Never>?
        Upload.visualImagePreparation = { await withCheckedContinuation { preparation = $0 } }
        board.clearContents()
        board.setData(pngData(width: 2, height: 2, type: .tiff), forType: .tiff)
        XCTAssertTrue(ghostty_surface_binding_action(pane.surface, "paste_from_clipboard", 20))
        try await wait("image preparation started") { preparation != nil }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window.windowNumber,
                                                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        pane.keyDown(with: escape)
        preparation?.resume()
        try await wait("cancelled image preparation finished") { WindowOwner.visualPreparedUploads > preparations }
        Upload.visualImagePreparation = nil
        try await drain(pane.runtime)
        XCTAssertFalse(owner.uploading(pane))
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
        XCTAssertFalse(owner.uploading(pane))
        try await drain(runtime)
        XCTAssertEqual(published().count, 2)
        XCTAssertNil(notice(owner))
        XCTAssertEqual(input.data, Data())
    }
}

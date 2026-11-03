import GhosttyKit
import KoClient
import KoModel
import XCTest
@testable import Kido

final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var state: (onMain: Bool, error: Error?)?
    var finished: Bool { lock.withLock { state != nil } }
    var onMain: Bool { lock.withLock { state?.onMain ?? true } }
    var error: Error? { lock.withLock { state?.error } }

    func run(_ call: () throws -> Void) {
        let onMain = Thread.isMainThread
        let error: Error?
        do { try call(); error = nil } catch let caught { error = caught }
        lock.withLock { state = (onMain, error) }
    }
}

final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

final class Decoded: @unchecked Sendable {
    struct Restore { var onMain: Bool; var thread: String; var generation: UInt64; var offset: UInt64; var continuation: Int }
    private let lock = NSLock()
    private var restores: [Restore] = []
    private var results: [Int32] = []
    var all: [Restore] { lock.withLock { restores } }
    var returned: [Int32] { lock.withLock { results } }

    var hooks: KoViewHooks {
        var hooks = KoViewHooks()
        hooks.beforeRestore = { [self] snapshot in
            var name = [CChar](repeating: 0, count: 64)
            pthread_getname_np(pthread_self(), &name, name.count)
            lock.withLock {
                restores.append(Restore(onMain: Thread.isMainThread, thread: String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), generation: snapshot.generation, offset: snapshot.offset, continuation: snapshot.continuation_max_bytes))
            }
        }
        hooks.afterRestore = { [self] result in lock.withLock { results.append(result) } }
        return hooks
    }
}

@MainActor final class KoViewTests: KoTestCase {
    // The pane and its size as the server's layout document gives them.
    private func leaf(_ connection: KoClient) throws -> (pane: PaneID, cols: Int, rows: Int) {
        let window = try XCTUnwrap(try connection.model().layout.layout.windows.first)
        guard case .leaf(let leaf) = window.tree else { throw XCTSkip("not a single pane window") }
        return (leaf.pane, leaf.cols, leaf.rows)
    }

    // Opens a view on a new surface until its snapshot stands at or past `minOffset`:
    // then the pane has printed all that the test needs the snapshot to hold.
    private func settledView(_ connection: KoClient, _ pane: (pane: PaneID, cols: Int, rows: Int), minOffset: UInt64, continuationOverride: Int? = nil, sink: Recorder)
        throws -> (surface: KoSurface, view: KoView, decoded: Decoded) {
        for _ in 0..<100 {
            let surface = KoSurface(cols: pane.cols, rows: pane.rows)
            let decoded = Decoded()
            var hooks = decoded.hooks
            hooks.continuationOverride = continuationOverride
            sink.view = []
            let view = try connection.openView(pane: pane.pane, surface: surface.surface, hooks: hooks) { sink.view.append($0) }
            wait("the first restore") { !sink.restored.isEmpty }
            if let restore = decoded.all.first, restore.offset >= minOffset { return (surface, view, decoded) }
            view.close()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        throw XCTSkip("the pane did not print \(minOffset) bytes")
    }

    func testARealSnapshotRestoresOnTheViewsDecoderThreadAndTheSurfaceGoesOnLikeALiveOne() throws {
        let printed = "\u{1b}[2J\u{1b}[1;1H\u{1b}[38;2;255;100;0mAB\u{1b}[2;1Hhello\u{1b}(0\u{1b}[3;1H" + String(repeating: "q", count: 80)
        let dir = try serverWithPane(#"stty -echo; printf '\033[2J\033[1;1H\033[38;2;255;100;0mAB\033[2;1Hhello\033(0\033[3;1H'; printf 'q%.0s' $(seq 1 80); read go; printf 'qZ'; exec sleep 60"#)
        let recorder = Recorder()
        let connection = try connect(dir, recorder)
        let pane = try leaf(connection)
        let (restored, view, decoded) = try settledView(connection, pane, minOffset: UInt64(printed.utf8.count), sink: recorder)
        let live = KoSurface(cols: pane.cols, rows: pane.rows)
        live.feed(printed)

        XCTAssertTrue(live.text.contains("hello"))
        XCTAssertEqual(restored.text, live.text, "the restored surface shows what the live one shows")
        let restore = try XCTUnwrap(decoded.all.first)
        XCTAssertFalse(restore.onMain)
        XCTAssertEqual(restore.thread, "ko-view-decoder")
        XCTAssertEqual(restore.generation, 1)
        XCTAssertEqual(recorder.restored.map(\.1), [GHOSTTY_SNAPSHOT_RESTORE_OK])
        XCTAssertEqual(decoded.returned, [Int32(GHOSTTY_SNAPSHOT_RESTORE_OK.rawValue)])

        try view.text(Data("go\n".utf8))
        wait("the bytes after the snapshot") { restored.text.contains("Z") }
        live.feed("qZ")
        XCTAssertEqual(restored.text, live.text, "the charset and the pending wrap went across the snapshot")
        XCTAssertTrue(restored.text.contains(String(repeating: "─", count: 81) + "Z"), restored.text)
        view.close()
    }

    func testTheServersSizeWinsAndAWrongSizedSurfaceIsRejectedUntilItIsSized() throws {
        let dir = try serverWithPane(#"printf 'hello'; exec sleep 60"#)
        let recorder = Recorder()
        let connection = try connect(dir, recorder)
        let pane = try leaf(connection)
        let surface = KoSurface(cols: pane.cols + 20, rows: pane.rows + 6)
        let decoded = Decoded()
        let view = try connection.openView(pane: pane.pane, surface: surface.surface, hooks: decoded.hooks) { recorder.view.append($0) }
        wait("the rejected restore") { !recorder.restored.isEmpty }
        XCTAssertEqual(recorder.restored.map(\.1), [GHOSTTY_SNAPSHOT_RESTORE_SIZE_MISMATCH])
        XCTAssertEqual(surface.text, "", "the surface keeps its terminal")
        XCTAssertEqual(surface.grid.cols, pane.cols + 20)

        surface.resize(cols: pane.cols, rows: pane.rows)
        try view.resync()
        wait("the restore of the second snapshot") { recorder.restored.count == 2 }
        XCTAssertEqual(recorder.restored.map(\.0), [1, 2])
        XCTAssertEqual(recorder.restored.last?.1, GHOSTTY_SNAPSHOT_RESTORE_OK)
        XCTAssertEqual(surface.text, "hello")
        XCTAssertEqual(decoded.all.map(\.thread), ["ko-view-decoder", "ko-view-decoder"])
        view.close()
    }

    func testAnApcOfOnePointFiveMegabytesRestoresWithTheServersLimitAndNotWithAFixedMebibyte() throws {
        let dir = try serverWithPane(#"stty -echo; printf 'ready'; printf '\033_Gx'; head -c 1500000 /dev/zero | tr '\0' a; read go; printf '\033\\ok'; exec sleep 60"#)
        let recorder = Recorder()
        let connection = try connect(dir, recorder)
        let pane = try leaf(connection)
        let printed: UInt64 = 5 + 4 + 1_500_000

        let (fixed, fixedView, fixedDecoded) = try settledView(connection, pane, minOffset: printed, continuationOverride: 1 << 20, sink: recorder)
        XCTAssertEqual(recorder.restored.map(\.1), [GHOSTTY_SNAPSHOT_RESTORE_REJECTED], "a fixed 1 MiB cannot hold the APC")
        XCTAssertEqual(fixed.text, "")
        XCTAssertGreaterThan(try XCTUnwrap(fixedDecoded.all.first).continuation, 1 << 20, "the server announced more")
        fixedView.close()

        let (restored, view, decoded) = try settledView(connection, pane, minOffset: printed, sink: recorder)
        XCTAssertEqual(recorder.restored.map(\.1), [GHOSTTY_SNAPSHOT_RESTORE_OK])
        XCTAssertEqual(try XCTUnwrap(decoded.all.first).continuation, try XCTUnwrap(fixedDecoded.all.first).continuation)
        XCTAssertEqual(restored.text, "ready")
        try view.text(Data("go\n".utf8))
        wait("the end of the APC and the text after it") { restored.text == "readyok" }
        view.close()
    }

    func testAViewCloseDuringARealRestoreFailsItsReadsWaitsForTheRestoreAndLeavesTheSurfaceAlone() throws {
        let dir = try serverWithPane(#"printf 'hello'; exec sleep 60"#)
        let recorder = Recorder()
        let connection = try connect(dir, recorder)
        let pane = try leaf(connection)
        let surface = KoSurface(cols: pane.cols, rows: pane.rows)
        let started = Latch()
        let decoded = Decoded()
        var hooks = decoded.hooks
        let counting = hooks.beforeRestore
        let closing = DispatchSemaphore(value: 0)
        hooks.beforeRestore = { snapshot in
            counting?(snapshot)
            started.set()
            _ = closing.wait(timeout: .now() + 10)
        }
        let view = try connection.openView(pane: pane.pane, surface: surface.surface, hooks: hooks) { recorder.view.append($0) }
        wait("the restore began") { started.isSet }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.1) { closing.signal() }
        view.close()
        XCTAssertEqual(decoded.returned, [Int32(GHOSTTY_SNAPSHOT_RESTORE_REJECTED.rawValue)], "close returned before the restore ended")
        XCTAssertEqual(surface.text, "")
        mainQueueDrained()
        XCTAssertEqual(recorder.view, [], "no event of a closed view")
    }

    func testTheModelAndTheCallsReachTheServer() throws {
        let dir = try serverWithPane("exec sleep 60")
        let recorder = Recorder()
        let connection = try connect(dir, recorder)
        let model = try connection.model()
        let pane = PaneID(number: 1), window = WindowID(number: 1), session = SessionID(number: 1)
        XCTAssertEqual(model.panes.map(\.id), [pane])
        XCTAssertEqual(model.panes.first?.mark, .none_)
        XCTAssertEqual(model.panes.first?.label, "sh")
        XCTAssertEqual(model.outline, [.session(.init(id: session, name: "s")), .pane(.init(depth: 0, id: pane, window: window))])

        try connection.select(KO_SELECT_WINDOW, window)
        wait("the selection") { recorder.events.contains(.selected(session: session, window: window, pane: pane)) }
        try connection.focus(true)
        try connection.observe([pane], attending: true)

        let offMain = Outcome()
        DispatchQueue.global().async {
            offMain.run { _ = try connection.edit(.renameWindow(KoSchema.EditRenameWindow(name: "renamed", window: window))) }
        }
        wait("the call off the main thread") { offMain.finished }
        XCTAssertFalse(offMain.onMain, "a blocking call runs off the main thread")
        XCTAssertNil(offMain.error)
        wait("the model with the new name") { (try? connection.model()).map { $0.layout.layout.windows.map(\.name) } == ["renamed"] }

        XCTAssertThrowsError(try connection.prompt(from: pane, to: pane, "hello")) { error in
            XCTAssertEqual((error as? KoError)?.code, KO_ERR_INVALID)
            XCTAssertFalse((error as? KoError)?.detail.isEmpty ?? true, "the server's refusal text")
        }
    }
}

import KoClient
import KoModel
import XCTest
@testable import Kido

// A gate that the test opens to let the edit in flight return, so no test waits out a delay.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var sent: [String] = []
    var revision = 0
    var failing = false

    var edits: [String] { lock.withLock { sent } }

    func perform(_ edit: KoSchema.Edit) throws -> KoSchema.Edited {
        guard case .renameWindow(let rename) = edit else { fatalError("unexpected edit") }
        lock.withLock { sent.append(rename.name) }
        semaphore.wait()
        if failing { throw KoError(code: KO_ERR_INVALID, detail: "refused") }
        return KoSchema.Edited(snapshot: KoSchema.Snapshot(layout: KoSchema.Layout(sessions: []), revision: revision))
    }

    func release() { semaphore.signal() }
}

@MainActor final class LayoutEditorTests: KoTestCase {
    private func rename(_ name: String) -> KoSchema.Edit { .renameWindow(KoSchema.EditRenameWindow(name: name, window: WindowID(number: 1))) }

    private func editor(_ gate: Gate) -> LayoutEditor { LayoutEditor { try gate.perform($0) } }

    func testNewSessionUsesTheFocusedPaneDirectoryOrTheServerDefault() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = app.appendingPathComponent("Packages/PaneGeometry/Tests/PaneGeometryTests/Fixtures/ko-layout.json")
        var model = try JSONDecoder().decode(KoModel.self, from: Data(contentsOf: fixture))
        let focus = try XCTUnwrap(model.current?.window.focus)
        guard case .addSession(let focused) = model.newSession("focused") else { return XCTFail("expected addSession") }
        XCTAssertEqual(focused.new.cwd, .pane(.init(pane: focus)))
        model.layout.layout.sessions = []
        model.panes = []
        guard case .addSession(let empty) = model.newSession("empty") else { return XCTFail("expected addSession") }
        XCTAssertNil(empty.new.cwd)
    }

    func testOneEditIsInFlightAndTheKeyedSuccessorReplacesTheWaitingOne() {
        let gate = Gate()
        let editor = editor(gate)
        editor.submit(rename("first"))
        wait("the first edit in flight") { gate.edits == ["first"] }
        editor.submit(rename("drag 1"), key: .float(PaneID(number: 1)))
        editor.submit(rename("drag 2"), key: .float(PaneID(number: 1)))
        editor.submit(rename("other"), key: .float(PaneID(number: 2)))
        mainQueueDrained()
        XCTAssertEqual(gate.edits, ["first"])
        gate.release()
        wait("the latest drag step") { gate.edits == ["first", "drag 2"] }
        gate.release()
        wait("the other edit") { gate.edits == ["first", "drag 2", "other"] }
        gate.release()
        wait("the queue ended") { !editor.holding }
    }

    func testEditsWithoutAKeyAreSentInOrder() {
        let gate = Gate()
        let editor = editor(gate)
        var results: [String] = []
        for name in ["a", "b", "c"] { editor.submit(rename(name)) { _ in results.append(name) } }
        for count in 1...3 {
            wait("edit \(count)") { gate.edits.count == count }
            gate.release()
        }
        wait("every result") { results.count == 3 }
        XCTAssertEqual(gate.edits, ["a", "b", "c"])
        XCTAssertEqual(results, ["a", "b", "c"])
    }

    func testTheHoldEndsWhenALayoutEventShowsTheRevisionOfTheLastEdit() {
        let gate = Gate()
        gate.revision = 5
        let editor = editor(gate)
        var settled = 0
        editor.onSettled = { settled += 1 }
        editor.layoutChanged(revision: 3)
        XCTAssertEqual(settled, 0)
        editor.submit(rename("a"))
        wait("sent") { gate.edits == ["a"] }
        gate.release()
        wait("the edit returned") { editor.expected == 5 }
        XCTAssertTrue(editor.holding)
        editor.layoutChanged(revision: 4)
        XCTAssertTrue(editor.holding)
        XCTAssertEqual(settled, 0)
        editor.layoutChanged(revision: 5)
        XCTAssertFalse(editor.holding)
        XCTAssertEqual(settled, 1)
        editor.layoutChanged(revision: 6)
        XCTAssertEqual(settled, 1)
    }

    func testFailureCallbackCanSubmitTheNextEdit() {
        let gate = Gate()
        gate.failing = true
        let editor = editor(gate)
        var completed = false
        editor.onFailure = { [weak editor] _, _ in editor?.submit(self.rename("next")) { _ in completed = true } }
        editor.submit(rename("first"))
        wait("first sent") { gate.edits == ["first"] }
        gate.release()
        wait("callback edit sent") { gate.edits == ["first", "next"] }
        gate.release()
        wait("callback edit completed") { completed }
        XCTAssertFalse(editor.holding)
    }

    func testOwnedRefusalOnlyInvokesCompletion() {
        let gate = Gate()
        gate.failing = true
        let editor = editor(gate)
        var failures = 0
        var completed = false
        editor.onFailure = { _, _ in failures += 1 }
        editor.submit(rename("owned")) { _ in completed = true }
        wait("sent") { gate.edits == ["owned"] }
        gate.release()
        wait("completion") { completed }
        XCTAssertEqual(failures, 0)
    }

    func testAFailureReportsItsMessageAndEndsTheHold() {
        let gate = Gate()
        gate.failing = true
        let editor = editor(gate)
        var failures: [String] = []
        var settled = 0
        editor.onFailure = { _, text in failures.append(text) }
        editor.onSettled = { settled += 1 }
        editor.submit(rename("a"))
        wait("sent") { gate.edits == ["a"] }
        gate.release()
        wait("the failure") { failures.count == 1 && settled == 1 }
        XCTAssertTrue(failures[0].contains("refused"), failures[0])
        XCTAssertFalse(editor.holding)
    }
}

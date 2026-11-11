import AppKit
import GhosttyKit
import KoClient
import KoModel
import SidebarFeed
import SnapshotTesting
import XCTest
@testable import Kido

@MainActor final class RuntimeWindowTests: AppWindowCase {
    private func marks(_ condition: @escaping @MainActor ([PaneID: RuntimeMark]) -> Bool) async throws {
        try await wait("the runtimes' marks") { condition(self.session.marks) }
    }

    // The window of the test over a private server. The dark theme is a runtime of its own, with a config file
    // that stays in place.
    private func startThemed(_ dark: Bool, windows: String) async throws {
        var config: String?
        if dark {
            config = FileManager.default.temporaryDirectory.appendingPathComponent("kido-runtime-dark-\(getpid()).yaml").path
            try "app: {theme: kido-dark}\n".write(toFile: try XCTUnwrap(config), atomically: true, encoding: .utf8)
        }
        try await start(configFile: config, windows: windows)
        if dark { window.appearance = NSAppearance(named: .darkAqua) }
    }

    // Replaces what a pane of a runtime shows: the wrapper of the runtime clears the screen as the pane starts.
    private func fill(_ id: PaneID, _ text: String) async throws {
        let pane = try XCTUnwrap(terminal?.displayedPanes.first { $0.pane == id })
        try await emit(pane, "\u{1b}[2J\u{1b}[H" + text)
    }

    private func runtimeSnapshot(_ dark: Bool, _ state: String) async throws {
        try await snapshot("\(dark ? "dark" : "light")-\(state)", testName: "runtime")
    }

    private func hover(_ pane: PaneID, entering: Bool = true) async throws {
        let chrome = try XCTUnwrap(terminal?.subviews.compactMap { $0 as? PaneChrome }.first { $0.pane == pane })
        let point = chrome.convert(NSPoint(x: chrome.toolbarFrame.midX, y: chrome.toolbarFrame.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: entering ? point : .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        chrome.mouseMoved(with: event)
        if entering {
            try await wait("the toolbar fades in") { chrome.subviews.compactMap { $0 as? PaneToolbar }.first.map { $0.alphaValue == 1 } == true }
        } else {
            try await wait("the toolbar fades out") { chrome.subviews.compactMap { $0 as? PaneToolbar }.allSatisfy { $0.alphaValue == 0 } }
        }
    }

    // window, window-hover, zoomed and label-find: a runtime pane, a host pane and a routed pi agent.
    func runtimeWindowStates(dark: Bool, find: Bool = false) async throws {
        try koRuntimes(["buildbox": ["command": [String: Any]()]])
        RuntimePill.spins = false
        let tree = splitTree("h", [
            runtimePane("buildbox", "buildbox ~/src/kido\\r\\n$ make verify\\r\\ncargo build ok\\r\\n"),
            splitTree("v", [
                runtimePane(nil, "~/Workspace/kido\\r\\n$ git status --short\\r\\n M ko_server/src/runtime/pane.rs\\r\\n"),
                runtimePane(nil, "pi - kido-app\\r\\ntools in buildbox\\r\\n", vars: routedVars, status: piStatus),
            ]),
        ])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        let (first, routed) = (PaneID(number: 1), PaneID(number: 3))
        try await marks { $0[first]?.state == .up && $0[routed]?.routed == true && $0[PaneID(number: 2)] == nil }
        try client?.select(KO_SELECT_PANE, first)
        try await wait("the runtime pane is active") { self.terminal?.active == first }
        try await fill(first, "buildbox ~/src/kido\r\n$ make verify\r\ncargo build ok")
        try await settle()
        if find {
            let pane = try XCTUnwrap(terminal?.displayedPanes.first { $0.pane == first })
            pane.showFind(nil)
            try await wait("the find capsule") { pane.find != nil }
            try await hover(first)
            try await runtimeSnapshot(dark, "label-find")
            pane.find?.close()
            try await wait("the find capsule closed") { pane.find == nil }
            return
        }
        try await runtimeSnapshot(dark, "window")
        try await hover(first)
        try await runtimeSnapshot(dark, "window-hover")
        try await hover(first, entering: false)
        try await toggleZoom(1)
        try await wait("the zoom") { self.terminal?.displayedPanes.filter { !$0.isHidden }.count == 1 }
        try await settle()
        try await runtimeSnapshot(dark, "zoomed")
    }

    // starting: a runtime whose start is held, with its dashed stripe and the spinner in the pill.
    func runtimeStartingState(dark: Bool) async throws {
        let fifo = directory.path + "/hold"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        try koRuntimes(["e2e": ["command": ["up": ["/bin/sh", "-c", "read hold < '\(fifo)'"]]]])
        RuntimePill.spins = false
        let tree = splitTree("h", [runtimePane("e2e", ""), runtimePane(nil, "~/Workspace/kido\\r\\n$ \\r\\n")])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        try await marks { $0[PaneID(number: 1)]?.state == .starting }
        try client?.select(KO_SELECT_PANE, PaneID(number: 1))
        try await wait("the runtime pane is active") { self.terminal?.active == PaneID(number: 1) }
        try await settle()
        try await runtimeSnapshot(dark, "starting")
    }

    // failed: the pill carries the message, and the pane's screen the same message from ko.
    func runtimeFailedState(dark: Bool) async throws {
        try koRuntimes(["gpu-1": ["command": ["up": ["/bin/sh", "-c", "echo '\(runtimeGapWithMessage)' >&2; exit 255"]]]])
        RuntimePill.spins = false
        let tree = splitTree("h", [runtimePane("gpu-1", ""), runtimePane(nil, "~/Workspace/kido\\r\\n$ \\r\\n")])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        try await marks { $0[PaneID(number: 1)]?.failure == runtimeGapWithMessage }
        try client?.select(KO_SELECT_PANE, PaneID(number: 1))
        try await wait("the runtime pane is active") { self.terminal?.active == PaneID(number: 1) }
        try await settle()
        try await runtimeSnapshot(dark, "failed")
    }

    // float: a float in a runtime over two host panes, its stripe clipped by the card's corners.
    func runtimeFloatState(dark: Bool) async throws {
        try koRuntimes(["py311": ["command": [String: Any]()]])
        RuntimePill.spins = false
        let float = runtimePane("py311", "py311 /work\\r\\n$ pytest -x\\r\\n")
        let tree = splitTree("h", [runtimePane(nil, "left\\r\\n"), runtimePane(nil, "right\\r\\n")])
        let floats = #"[{"pane":\#(String(float.dropFirst(8).dropLast())),"x":10,"y":4,"cols":34,"rows":8}]"#
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree),"floats":\#(floats)}]"#)
        let pane = PaneID(number: 3)
        try await marks { $0[pane]?.state == .up }
        try client?.select(KO_SELECT_PANE, pane)
        try await wait("the float is active") { self.terminal?.active == pane }
        try await fill(pane, "py311 /work\r\n$ pytest -x")
        try await settle()
        try await runtimeSnapshot(dark, "float")
    }

    // colour-hash and colour-config: four runtimes in four panes; gpu-1 takes its configured colour.
    func runtimeColourState(dark: Bool, configured: Bool) async throws {
        var gpu: [String: Any] = ["command": [String: Any]()]
        if configured { gpu["color"] = "#d08a2a" }
        try koRuntimes(["buildbox": ["command": [String: Any]()], "py311": ["command": [String: Any]()], "gpu-1": gpu, "e2e": ["command": [String: Any]()]])
        RuntimePill.spins = false
        let names = ["buildbox", "py311", "gpu-1", "e2e"]
        let tree = splitTree("h", [splitTree("v", names[..<2].map { runtimePane($0, "\($0)\\r\\n") }), splitTree("v", names[2...].map { runtimePane($0, "\($0)\\r\\n") })])
        try await startThemed(dark, windows: #"[{"name":"w","tree":\#(tree)}]"#)
        try await marks { marks in names.indices.allSatisfy { marks[PaneID(number: UInt32($0 + 1))]?.state == .up } }
        try client?.select(KO_SELECT_PANE, PaneID(number: 1))
        try await wait("the first pane is active") { self.terminal?.active == PaneID(number: 1) }
        for (index, name) in names.enumerated() { try await fill(PaneID(number: UInt32(index + 1)), name) }
        try await settle()
        try await runtimeSnapshot(dark, configured ? "colour-config" : "colour-hash")
    }

    func testRuntimeWindowLight() async throws { try await runtimeWindowStates(dark: false) }
    func testRuntimeWindowDark() async throws { try await runtimeWindowStates(dark: true) }
    func testRuntimeLabelFindLight() async throws { try await runtimeWindowStates(dark: false, find: true) }
    func testRuntimeLabelFindDark() async throws { try await runtimeWindowStates(dark: true, find: true) }
    func testRuntimeStartingLight() async throws { try await runtimeStartingState(dark: false) }
    func testRuntimeStartingDark() async throws { try await runtimeStartingState(dark: true) }
    func testRuntimeFailedLight() async throws { try await runtimeFailedState(dark: false) }
    func testRuntimeFailedDark() async throws { try await runtimeFailedState(dark: true) }
    func testRuntimeFloatLight() async throws { try await runtimeFloatState(dark: false) }
    func testRuntimeFloatDark() async throws { try await runtimeFloatState(dark: true) }
    func testRuntimeColourHashLight() async throws { try await runtimeColourState(dark: false, configured: false) }
    func testRuntimeColourHashDark() async throws { try await runtimeColourState(dark: true, configured: false) }
    func testRuntimeColourConfigLight() async throws { try await runtimeColourState(dark: false, configured: true) }
    func testRuntimeColourConfigDark() async throws { try await runtimeColourState(dark: true, configured: true) }
}

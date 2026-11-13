import AppKit
import GhosttyKit
import KoClientKit
import KoModel
import KoClient
import PaneGeometry
import SidebarFeed
import SnapshotTesting
import XCTest
@testable import Kido

@MainActor final class SidebarChildrenTests: VisualTestCase {
    private func ownerFixture() async throws -> (dir: String, runtime: GhosttyRuntime, owner: WindowOwner, children: [Snapshot.Position]) {
        let dir = try await koLaunched(pane: koPane("stty raw -echo; printf '\\033[?25lparent'; exec cat"))
        let split = KoSchema.Edit.split(.init(axis: .h, new: .init(command: .shell(.init(command: "stty raw -echo; printf '\\033[?25l~/Workspace/kido\\r\\n$ '; exec cat"))), pane: .init(number: 1)))
        try await ko(["layout", "edit", String(decoding: JSONEncoder().encode(split), as: UTF8.self)], dir: dir)
        var children: [Snapshot.Position] = []
        for parent in [1, 2] {
            let cwd = dir + "/child-work-\(parent)"
            try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            let body = KoSchema.CreatePane(command: .shell(.init(command: "stty raw -echo; printf '\\033[?25lpi · ~/Workspace/kido\\r\\n\\r\\n› Designing session cards and pane states\\r\\n\\r\\nReading App/SidebarView.swift\\r\\n\\r\\n› '; exec cat")), cwd: .absPath(cwd), parent: .init(number: UInt32(parent)))
            let input = dir + "/child-\(parent).json"
            try JSONEncoder().encode(body).write(to: URL(fileURLWithPath: input))
            let text = try await ko(["api", "-X", "POST", "--input", input, "/panes"], dir: dir)
            children.append(try JSONDecoder().decode(Snapshot.Position.self, from: Data(text.utf8)))
        }
        let board = NSPasteboard(name: .init("children-" + UUID().uuidString))
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let owner = WindowOwner(host: .local, runtime: runtime, start: false)
        owner.testServerDir = dir
        SidebarView.visualNow = 0
        runtime.onConfigChange = { [weak owner] in owner?.updateAppearance() }
        runtime.onConfigReload = { [weak owner] font in owner?.testSession?.reloadConfig(font: font) }
        owner.window.setContentSize(NSSize(width: 1040, height: 720))
        owner.window.colorSpace = .displayP3
        PaneView.renderOffscreen = true
        addTeardownBlock { @MainActor in
            SidebarView.visualNow = nil
            owner.close()
            board.releaseGlobally()
            PaneView.renderOffscreen = false
        }
        owner.start()
        try await wait("root and child panes") { owner.testModel?.panes.count == 4 && owner.testSession?.windows[WindowID(number: 1)]?.displayedPanes.count == 2 }
        return (dir, runtime, owner, children)
    }

    private func theme(_ runtime: GhosttyRuntime, dark: Bool) async throws {
        runtime.previewTheme(dark ? "kido-dark" : "kido-light")
        runtime.flushTheme()
        try await drain(runtime)
        XCTAssertEqual(runtime.background.isDark, dark)
    }

    func testSidebarChildren() async throws {
        let previousNow = SidebarView.visualNow
        SidebarView.visualNow = sidebarChildrenNow
        defer { SidebarView.visualNow = previousNow }
        enum Scenario: CaseIterable {
            case collapsed, expanded, narrow, recordsCollapsed, recordsExpanded, waitCleared, sixPlus, singleIdle, ellipsis, directories, directoryNarrow, singleLong, narrowNine, paneWaitFolded, paneWaitExpanded, recordWaitFolded, recordWaitExpanded, recordOffered, recordSelected, closeHover, countOnly, summaryAbsent
            var configuration: (name: String, records: Bool, width: Int) {
                switch self {
                case .collapsed: ("stress-collapsed", false, 292)
                case .expanded: ("stress-expanded", false, 292)
                case .narrow: ("stress-collapsed-236", false, 236)
                case .recordsCollapsed: ("records-collapsed", true, 292)
                case .recordsExpanded: ("records-expanded", true, 292)
                case .waitCleared: ("stress-wait-cleared", false, 292)
                case .sixPlus: ("six-plus", false, 292)
                case .singleIdle: ("single-idle", false, 292)
                case .ellipsis: ("activity-ellipsis", false, 292)
                case .directories: ("directories", false, 292)
                case .directoryNarrow: ("directory-narrow-circles", false, 150)
                case .singleLong: ("single-long-name", false, 236)
                case .narrowNine: ("narrow-nine-hidden", false, 80)
                case .countOnly: ("deep-count-only", false, 96)
                case .summaryAbsent: ("deep-summary-absent", false, 56)
                case .paneWaitFolded: ("pane-wait-folded", false, 292)
                case .paneWaitExpanded: ("pane-wait-expanded", false, 292)
                case .recordWaitFolded: ("record-wait-folded", true, 292)
                case .recordWaitExpanded: ("record-wait-expanded", true, 292)
                case .recordOffered: ("record-offered", false, 292)
                case .recordSelected: ("record-selected", false, 292)
                case .closeHover: ("trailing-close-hover", false, 292)
                }
            }
        }
        for dark in [false, true] {
            let side = dark ? "dark" : "light"
            let board = NSPasteboard(name: .init("children-colors-" + UUID().uuidString))
            let colors = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
            try await theme(colors, dark: dark)
            defer { board.releaseGlobally() }
            for scenario in Scenario.allCases {
                let (name, records, width) = scenario.configuration
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.colorSpace = .displayP3
                let list = SidebarView()
                list.captionDelay = 0
                window.contentView = list
                list.layer?.backgroundColor = colors.background.shifted(colors.sidebarShade).cgColor
                var snapshot = sidebarChildrenFixture(records: records)
                switch scenario {
                case .waitCleared:
                    snapshot.mapItems { if $0.id.number == 940 { $0.fixtureLifecycle = piLifecycle(); $0.pane.mark = .none_ } }
                case .expanded:
                    snapshot.client = .init(session: .init(number: 0), window: .init(number: 458), pane: .init(number: 936))
                case .sixPlus, .singleIdle:
                    let count = scenario == .singleIdle ? 1 : 8
                    let children = (1...count).map { index in fixtureNode(UInt32(index), "child-\(index)", piLifecycle(index == 1 ? .idle(.init()) : .running(.init())), mark: index == 1 ? .none_ : .running) }
                    snapshot = fixtureSnapshot(window: 99, pane: 99, [("main", [fixtureNode(0, "Parent", piLifecycle(), children: children)])])
                case .singleLong, .narrowNine, .countOnly, .summaryAbsent:
                    let count = scenario == .singleLong ? 1 : 9
                    let children = (1...count).map { fixtureNode(UInt32($0), "A very long hidden child name that must ellipsize", piLifecycle(.running(.init())), mark: .running) }
                    snapshot = fixtureSnapshot(window: 99, pane: 99, [("main", [fixtureNode(0, "Parent", piLifecycle(.running(.init()), msg: "A very long activity caption that must ellipsize before the circles"), mark: .running, children: children)])])
                    if scenario == .countOnly || scenario == .summaryAbsent {
                        snapshot = fixtureSnapshot(window: 101, pane: 101, [("main", [fixtureNode(100, "Root", piLifecycle(), children: [fixtureNode(101, "Ancestor", piLifecycle(), children: snapshot.sessions[0].nodes)])])])
                    }
                case .directories:
                    let ssh = Lifecycle.live(.ssh(.init(destination: "dev@devbox", pane: .terminal(.init(interactive: true, status: .init(phase: .idle(.init())))))))
                    snapshot = fixtureSnapshot(window: 99, pane: 99, [("main", [
                        .item(fixtureItem(1, cwd: "/Users/dev/Workspace/kido", "Terminal", shellLifecycle())),
                        .item(fixtureItem(2, cwd: "/Users/dev/Documents", "Idle agent", piLifecycle(), mark: .none_)),
                        .item(fixtureItem(3, cwd: "/Users/dev/Workspace/kido", "Busy agent", piLifecycle(.running(.init()), msg: "Refactoring the sidebar rows"), mark: .running)),
                        .item(fixtureItem(4, cwd: "/var/log", "ssh dev@devbox", ssh)),
                        .item(fixtureItem(5, cwd: "/etc", "Ended", .ended(.exited(.init(code: 2))))),
                    ])])
                case .directoryNarrow:
                    let children = (1...3).map { fixtureNode(UInt32($0), "Child \($0)", piLifecycle(.running(.init())), mark: .running) }
                    snapshot = fixtureSnapshot(window: 99, pane: 99, [("main", [.item(fixtureItem(0, cwd: "/Users/dev/Workspace/kido/app/Packages/SidebarFeed", "Terminal", shellLifecycle(), children: children))])])
                case .ellipsis:
                    snapshot.mapItems { if $0.id.number == 940 { $0.fixtureLifecycle = piLifecycle(.waiting(.init()), msg: "Allow running make test in the worktree before continuing?") } }
                    snapshot.client = .init(session: .init(number: 0), window: .init(number: 458), pane: .init(number: 936))
                case .paneWaitFolded, .paneWaitExpanded:
                    snapshot = fixtureSnapshot(window: 0, pane: scenario == .paneWaitExpanded ? 0 : 99, [("main", [fixtureNode(0, "Parent", piLifecycle(), children: [fixtureNode(1, "Waiting child", piLifecycle(.waiting(.init(kind: .permission))), mark: .waiting)])])])
                case .recordWaitFolded, .recordWaitExpanded:
                    snapshot = fixtureSnapshot(window: 0, pane: scenario == .recordWaitExpanded ? 0 : 99, [("main", [.item(fixtureItem(0, "Claude Code", agentLifecycle(.running(.init())), records: [
                        .working(.init(id: "a", msg: "Working", title: "Record parent")),
                        .blocked(.init(id: "a/b", msg: "Approve command", title: "Waiting record"))
                    ]))])])
                case .recordOffered, .recordSelected:
                    let second: KoSchema.RecordSelection = scenario == .recordSelected ? .selected : .offered
                    snapshot = fixtureSnapshot(window: 0, pane: 0, [("main", [.item(fixtureItem(0, "Claude Code", agentLifecycle(.running(.init())), records: [
                        .working(.init(id: "agents/a", msg: "Reading the plan", selection: scenario == .recordSelected ? .offered : .selected, title: "Planner")),
                        .idle(.init(id: "agents/b", msg: "Ready", selection: second, title: "Reviewer")),
                        .done(.init(id: "job/build", msg: "Built", title: "Build"))
                    ]))])])
                case .recordsCollapsed:
                    snapshot.client = .init(session: .init(number: 0), window: .init(number: 458), pane: .init(number: 937))
                case .collapsed, .narrow, .recordsExpanded, .closeHover: break
                }
                list.show(snapshot)
                if scenario == .recordsCollapsed {
                    XCTAssertEqual(list.visualRows.compactMap { if case .program = $0.id { $0.title } else { nil } }, ["Investigate sidebar layout", "Approve test command"])
                }
                switch scenario {
                case .countOnly, .summaryAbsent:
                    window.layoutIfNeeded()
                    list.layoutSubtreeIfNeeded()
                    list.visualTable.tile()
                    list.visualTable.layoutSubtreeIfNeeded()
                    let index = try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane.number == 0 })
                    let cell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell)
                    cell.layoutSubtreeIfNeeded()
                    XCTAssertEqual(cell.children.isHidden, scenario == .summaryAbsent, "row width \(cell.bounds.width), leading \(list.visualRows[index].leading), children \(cell.children.frame)")
                    XCTAssertLessThanOrEqual(cell.children.frame.maxX, cell.bounds.width - 5)
                default: break
                }
                if scenario == .closeHover,
                   let index = list.visualRows.firstIndex(where: { $0.target != nil && $0.started != nil }),
                   let cell = list.visualTable.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarCell {
                    cell.layoutSubtreeIfNeeded()
                    let point = cell.convert(NSPoint(x: cell.close.frame.midX, y: cell.close.frame.midY), to: nil)
                    let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
                    cell.mouseEntered(with: event)
                }
                sidebarSnapshot(list, "\(name)-\(side)")
                window.close()
            }
        }
        let fixture = try await ownerFixture()
        let owner = fixture.owner, child = fixture.children[0]
        let titleInput = fixture.dir + "/tab-titles.json"
        for (pane, title) in [(PaneID(number: 1), "@kido-app"), (child.pane, "@sidebar-mockup"), (fixture.children[1].pane, "@sidebar-tests")] {
            try JSONSerialization.data(withJSONObject: ["type": "text", "data": Data("\u{1b}]0;\(title)\u{7}".utf8).base64EncodedString()]).write(to: URL(fileURLWithPath: titleInput))
            try await ko(["api", "--input", titleInput, "/panes/\(pane)/input"], dir: fixture.dir)
        }
        owner.perform(.jump(.init(session: child.session, window: child.window, pane: child.pane)))
        try await wait("child shown for full-window snapshot") {
            guard let pane = owner.testSession?.pane(child.pane) else { return false }
            return owner.testSession?.windows[child.window]?.active == child.pane && self.surfaceText(pane).contains("Designing session cards")
                && owner.sidebar.tabs.entries.map(\.name) == ["@kido-app", "@sidebar-tests", "@sidebar-mockup"]
        }
        func feed(split: Bool) -> Snapshot {
            var snapshot = sidebarChildrenFixture()
            snapshot.mapItems { item in
                let original = item.id.number
                if original == 502 { item.pane.id = PaneID(number: 1) }
                if original == 937 { item.pane.id = PaneID(number: 2) }
                if original == 936 { item.pane.id = child.pane; item.pane.parent = PaneID(number: 1) }
                if item.window.number == 458 { item.window = WindowID(number: 1) }
            }
            for index in snapshot.sessions.indices { snapshot.sessions[index].id = index == 0 ? child.session : SessionID(number: UInt32(100 + index)) }
            snapshot.sessions[0].nodes[1].group.id = WindowID(number: 1)
            if split, let selected = owner.testModel?.selection.pane {
                snapshot.sessions[0].nodes[1].group.children.insert(fixtureItem(selected.number, window: 1, "zsh", shellLifecycle()), at: 1)
                snapshot.client = .init(session: child.session, window: WindowID(number: 1), pane: selected)
            } else { snapshot.client = .init(session: child.session, window: WindowID(number: 1), pane: child.pane) }
            return snapshot
        }
        for split in [false, true] {
            if split {
                owner.paneCommand(.split(.right), child.pane)
                try await wait("new split is selected beside the child in its own window") {
                    guard let model = owner.testModel, let selected = model.selection.pane, let panes = model.layout.layout.window(child.window)?.panes else { return false }
                    return panes.count == 2 && panes.contains(selected) && selected.number > 2
                }
                let selected = try XCTUnwrap(owner.testModel?.selection.pane)
                let input = fixture.dir + "/snapshot-input.json"
                let text = "stty raw -echo; printf '\\033[2J\\033[H\\033[?25l~/Workspace/kido\\r\\n$ '; exec cat\n"
                try JSONSerialization.data(withJSONObject: ["type": "paste", "text": text, "check_safe": false]).write(to: URL(fileURLWithPath: input))
                try await ko(["api", "--input", input, "/panes/\(selected)/input"], dir: fixture.dir)
                try JSONSerialization.data(withJSONObject: ["type": "text", "data": Data("\r".utf8).base64EncodedString()]).write(to: URL(fileURLWithPath: input))
                try await ko(["api", "--input", input, "/panes/\(selected)/input"], dir: fixture.dir)
                try await wait("split terminal executed the pasted command") {
                    owner.testSession?.pane(selected).map { self.surfaceText($0).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("~/Workspace/kido\n$") } == true
                }
            }
            for dark in [false, true] {
                try await theme(fixture.runtime, dark: dark)
                for pane in owner.testSession?.windows.values.filter({ !$0.isHidden }).flatMap(\.displayedPanes) ?? [] where !pane.isHidden { await presentedFrame(pane) }
                owner.testReceive(feed(split: split))
                owner.window.layoutIfNeeded()
                owner.window.contentView?.layoutSubtreeIfNeeded()
                owner.window.displayIfNeeded()
                CATransaction.flush()
                let content = try XCTUnwrap(owner.window.contentView?.superview)
                let name = "\(split ? "split-adds-top-level-pane" : "stress-child-in-place")-\(dark ? "dark" : "light")"
                checkSnapshot { verifyWindowView(content, named: name, record: $0) }
                let fullscreen = try fullscreenHostImage(owner, root: content)
                checkSnapshot { verifySnapshot(of: fullscreen, as: .pixels, named: name + "-fullscreen", record: $0) }
            }
        }
    }

    func testWindowBlockLayers() throws {
        let previousNow = SidebarView.visualNow
        SidebarView.visualNow = sidebarChildrenNow
        defer { SidebarView.visualNow = previousNow }
        for dark in [false, true] {
            for name in ["single", "records-and-children", "keyboard-other", "keyboard-focused", "scroll-clipped"] {
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: name == "scroll-clipped" ? 150 : 640), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let list = SidebarView()
                list.captionDelay = 0
                window.contentView = list
                var snapshot = sidebarChildrenFixture(records: name == "records-and-children")
                if name == "single" { snapshot = fixtureSnapshot(window: 0, pane: 0, [("main", [fixtureNode(0, "One pane", piLifecycle())])]) }
                if name == "records-and-children" {
                    var first = snapshot.sessions[0].nodes[0].item
                    first.children.append(.item(fixtureItem(3002, parent: 3000, "Child agent", piLifecycle())))
                    snapshot.sessions[0].nodes[0] = .window(.init(id: .init(number: 3000), children: [
                        first, fixtureItem(3001, window: 3000, "Second pane", shellLifecycle()),
                    ]))
                }
                if name == "records-and-children" { snapshot.client = .init(session: .init(number: 0), window: .init(number: 3000), pane: .init(number: 3000)) }
                if name == "scroll-clipped" { snapshot.client = .init(session: .init(number: 0), window: .init(number: 458), pane: .init(number: 936)) }
                list.show(snapshot)
                if name.hasPrefix("keyboard") {
                    list.focus()
                    let row = try XCTUnwrap(list.visualRows.firstIndex { name == "keyboard-focused" ? $0.focused : $0.target?.pane.number == 905 })
                    list.visualTable.selectRowIndexes([row], byExtendingSelection: false)
                    (list.visualTable as? Table)?.keyboardSelection = true
                }
                if name == "scroll-clipped" {
                    list.layoutSubtreeIfNeeded()
                    let row = try XCTUnwrap(list.visualRows.firstIndex { $0.target?.pane.number == 502 })
                    list.visualScroll.contentView.scroll(to: NSPoint(x: 0, y: list.visualTable.rect(ofRow: row).minY + 8))
                }
                sidebarSnapshot(list, "\(name)-\(dark ? "dark" : "light")")
                window.close()
            }
        }
    }

    func testServerRestartResetsSurfaces() async throws {
        let fixture = try await ownerFixture()
        let owner = fixture.owner
        let root = PaneID(number: 1), window = WindowID(number: 1)
        try await ko(["api", "-X", "DELETE", "/panes/pane_2"], dir: fixture.dir)
        try await wait("one root remains") { owner.testModel?.layout.layout.window(window)?.panes == [root] }
        try await wait("root shown before restart") { owner.testModel?.selection.pane == root && (owner.testSession?.pane(root)?.visualRestores ?? 0) > 0 }
        let old = try XCTUnwrap(owner.testSession?.pane(root))
        let instance = try XCTUnwrap(owner.snapshot?.serverInstance)
        try await ko(["kill-server"], dir: fixture.dir)
        try await wait("fresh server root restored") {
            owner.snapshot?.serverInstance != instance && owner.testModel?.selection.pane == root && owner.testSession?.pane(root) != nil
        }
        XCTAssertFalse(owner.testSession?.pane(root) === old)
        for index in 0..<3 {
            let input = fixture.dir + "/restart-child-\(index).json"
            let body = KoSchema.CreatePane(command: .shell(.init(command: rawScript)), parent: root)
            try JSONEncoder().encode(body).write(to: URL(fileURLWithPath: input))
            try await ko(["api", "-X", "POST", "--input", input, "/panes"], dir: fixture.dir)
        }
        try await wait("new children in semantic snapshot") { PaneProjection(owner.snapshot).items.values.filter { $0.item.pane.parent == root }.count == 3 }
        XCTAssertEqual(owner.testModel?.selection.pane, root, "a new child does not take the selection")
    }

    func testFoldedDoneUsesIdleDotAndSubtreeUsesRunningCircle() throws {
        let rows = sidebarRows(sidebarChildrenFixture())
        let parent = try XCTUnwrap(rows.first { $0.target?.pane == PaneID(number: 502) })
        let waiting = try XCTUnwrap(rows.first { $0.target?.pane == PaneID(number: 940) })
        XCTAssertEqual(parent.hidden.map(\.status), [.running, .quiet])
        XCTAssertEqual(waiting.hidden.map(\.status), [.running, .quiet])
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 44, height: 12), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 12))
        window.contentView = host
        for (index, hidden) in [parent.hidden, waiting.hidden].enumerated() {
            let control = SidebarChildren(SidebarFonts())
            control.content = hidden
            control.frame = NSRect(x: index * 24, y: 0, width: 20, height: 12)
            host.addSubview(control)
        }
        host.displayIfNeeded()
        checkSnapshot { verifySnapshot(of: host, as: .pixels, named: "subtree-running-and-idle-dots", record: $0) }
    }

    private func click(_ control: NSView) throws {
        let window = try XCTUnwrap(control.window)
        window.orderBack(nil)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        control.superview?.layoutSubtreeIfNeeded()
        let point = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
        let location = control.convert(point, to: nil)
        let host = try XCTUnwrap(window.contentView?.superview)
        let hit = host.hitTest(host.convert(location, from: nil))
        XCTAssertTrue(hit === control, "expected \(control), hit \(String(describing: hit))")
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        control.mouseDown(with: down)
    }

    func testRecordWordFollowsDisplayedStatus() throws {
        let list = SidebarView()
        var snapshot = fixtureSnapshot(window: 0, pane: 0, [("main", [.item(fixtureItem(0, "Claude", agentLifecycle(.running(.init())), records: [
            .done(.init(id: "seen")), .error(.init(id: "failed", msg: "boom")),
        ]))])])
        snapshot.mapItems { $0.pane.recordsSeen = true }
        list.show(snapshot)
        let labels = list.visualRows.filter { if case .program = $0.id { true } else { false } }.map { row in
            let cell = SidebarCell(SidebarFonts())
            cell.configure(row, now: 0)
            return cell.accessibilityLabel() ?? ""
        }
        XCTAssertTrue(labels[1].contains("idle"), labels[1])
        XCTAssertTrue(labels[0].contains("boom"), labels[0])
    }

    func testProgramRowsDoNotNavigate() throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 292, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarView()
        list.captionDelay = 0
        window.contentView = list
        var snapshot = sidebarChildrenFixture(records: true)
        snapshot.client = .init(session: .init(number: 0), window: .init(number: 3000), pane: .init(number: 3000))
        snapshot.mapItems { if $0.id.number == 3000 { $0.pane.status?.programStatus.records.append(.working(.init(id: "agent-b/nested", title: "Nested record"))) } }
        list.show(snapshot)
        var navigations = 0
        list.navigate = { _, _ in navigations += 1 }
        let record = try XCTUnwrap(list.visualRows.firstIndex { if case .program(_, _, let id) = $0.id { id == Data("agent-b".utf8) } else { false } })
        let recordCell = try XCTUnwrap(list.visualTable.view(atColumn: 0, row: record, makeIfNecessary: true) as? SidebarCell)
        XCTAssertFalse(list.tableView(list.visualTable, shouldSelectRow: record))
        XCTAssertTrue(recordCell.close.isHidden)
        XCTAssertEqual(recordCell.accessibilityRole(), .staticText)
        XCTAssertTrue(list.visualRows.contains { $0.title == "Nested record" })
        list.visualJump(list.visualRows[record])
        XCTAssertEqual(navigations, 0)
        list.focus()
        list.select(snapshot.client)
        for code: UInt16 in [123, 124] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            let rows = list.visualRows
            list.visualTable.keyDown(with: key)
            XCTAssertEqual(list.visualRows, rows, "Left and Right do nothing")
        }
        let rows = list.visualRows
        list.paneCommand = { _, _ in XCTFail("⌘↑ and ⌘↓ command nothing") }
        for code: UInt16 in [125, 126] {
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            list.visualTable.keyDown(with: key)
        }
        XCTAssertEqual(list.visualRows, rows)
        XCTAssertEqual(navigations, 0)
    }

    func testQueuedWindowSwitchesYieldToJumpsAndDisconnect() async throws {
        let fixture = try await ownerFixture()
        let owner = fixture.owner
        for _ in 0..<2 {
            let input = fixture.dir + "/navigation-pane.json"
            let request: [String: Any] = ["session": fixture.children[0].session.description, "command": ["type": "shell", "command": "stty raw -echo; exec cat"]]
            try JSONSerialization.data(withJSONObject: request).write(to: URL(fileURLWithPath: input))
            try await ko(["api", "-X", "POST", "--input", input, "/panes"], dir: fixture.dir)
        }
        try await wait("five windows", within: 5) { owner.navigation.windows.count == 5 }
        let order = owner.navigation.windows.map(\.id)
        func focus(_ index: Int) throws -> Snapshot.Position {
            let window = try XCTUnwrap(owner.testModel?.layout.layout.window(order[index]))
            return Snapshot.Position(session: fixture.children[0].session, window: window.id, pane: window.focus)
        }
        func settled(_ index: Int) -> Bool { owner.testNavigationIdle && owner.navigation.window == order[index] }
        owner.perform(.jump(try focus(0)))
        try await wait("first window", within: 5) { settled(0) }
        owner.perform(.switchWindow(next: true))
        owner.perform(.switchWindow(next: false))
        try await wait("rapid next/previous returns to the first window", within: 5) { settled(0) }
        owner.perform(.switchWindow(next: true))
        owner.perform(.jump(try focus(2)))
        owner.perform(.switchWindow(next: true))
        try await wait("switch/jump/switch drains the canceled answer and ends after the jump", within: 5) { settled(3) }
        owner.perform(.switchWindow(next: true))
        owner.perform(.switchWindow(next: true))
        try await wait("rapid double switch wraps to the first window", within: 5) { settled(0) }
        owner.perform(.switchWindow(next: true))
        owner.perform(.switchWindow(next: true))
        let target = try focus(1)
        owner.perform(.jump(target))
        try await wait("jump cancels a pending switch and its queued direction", within: 5) { owner.testNavigationIdle && owner.testModel?.selection.pane == target.pane }
        owner.perform(.switchWindow(next: true))
        owner.testReceive(KoEvent.failed(code: KO_ERR_CLOSED, message: "test disconnect"))
        XCTAssertTrue(owner.testNavigationIdle)
        owner.testReceive(KoEvent.welcome(client: "client_1", fresh: false))
        owner.testReceive(KoEvent.model)
        try await wait("same-instance reconnect drops the pending switch", within: 5) { owner.testNavigationIdle }
    }

    func testSelectingAFloatRaisesItOverItsOverlappingFloat() async throws {
        let fixture = try await ownerFixture()
        let owner = fixture.owner, root = WindowID(number: 1), lower = PaneID(number: 2)
        owner.paneCommand(.split(.right), PaneID(number: 1))
        try await wait("third pane created") { owner.testModel?.layout.layout.window(root)?.panes.count == 3 && (owner.testModel?.selection.pane?.number ?? 0) > 4 }
        let upper = try XCTUnwrap(owner.testModel?.selection.pane)
        for (pane, x, y) in [(lower, 5, 2), (upper, 8, 4)] {
            let edit = KoSchema.Edit.float(.init(cols: 35, pane: pane, rows: 10, x: x, y: y))
            try await ko(["layout", "edit", String(decoding: JSONEncoder().encode(edit), as: UTF8.self)], dir: fixture.dir)
        }
        try await wait("two overlapping floats") { owner.testModel?.layout.layout.window(root)?.floats.map(\.pane) == [lower, upper] }
        let view = try XCTUnwrap(owner.testSession?.pane(lower))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        try await wait("the lower float is selected and raised") {
            owner.testModel?.selection.pane == lower && owner.testModel?.layout.layout.window(root)?.floats.last?.pane == lower
        }
    }

    func testAFloatInAChildWindowDocksBesideItsPaneAndCloseReturnsFocusToIt() async throws {
        let fixture = try await ownerFixture()
        let owner = fixture.owner, child = fixture.children[0]
        owner.perform(.jump(child))
        try await wait("the child's own window is shown") { owner.testModel?.selection.pane == child.pane && owner.navigation.window == child.window }
        let text = try await ko(["api", "/layout"], dir: fixture.dir)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        document["panes"] = nil
        var layout = try XCTUnwrap(document["layout"] as? [String: Any])
        var sessions = try XCTUnwrap(layout["sessions"] as? [[String: Any]])
        var windows = try XCTUnwrap(sessions[0]["windows"] as? [[String: Any]])
        let at = try XCTUnwrap(windows.firstIndex { ($0["id"] as? String) == child.window.description })
        windows[at]["floats"] = [["pane": ["new": ["parent": child.pane.description, "close": "on_exit", "command": ["type": "shell", "command": "stty raw -echo; exec cat"]]], "border": true, "cols": 30, "rows": 6, "x": 1, "y": 1]]
        sessions[0]["windows"] = windows
        layout["sessions"] = sessions
        document["layout"] = layout
        let draft = fixture.dir + "/float.json"
        try JSONSerialization.data(withJSONObject: document).write(to: URL(fileURLWithPath: draft))
        try await ko(["api", "-X", "PUT", "--input", draft, "/layout"], dir: fixture.dir)
        try await wait("the child's float") { owner.testModel?.layout.layout.window(child.window)?.floats.count == 1 }
        let float = try XCTUnwrap(owner.testModel?.layout.layout.window(child.window)?.floats.first?.pane)
        try await wait("the float is displayed over the child") { owner.testSession?.windows[child.window]?.displayedPanes.contains { $0.pane == float } == true }
        owner.perform(.jump(Snapshot.Position(session: child.session, window: child.window, pane: float)))
        try await wait("the float is selected") { owner.testModel?.selection.pane == float }
        let displayed = try XCTUnwrap(owner.testSession?.windows[child.window]?.displayedPanes.map(\.pane))
        XCTAssertTrue(displayed.contains(child.pane) && displayed.contains(float), "the child stays shown under its float")
        owner.paneCommand(.float, float)
        try await wait("the float docks beside the child in the child's window") { owner.testModel?.layout.layout.window(child.window)?.floats.isEmpty == true && owner.testModel?.layout.layout.window(child.window)?.panes.contains(float) == true }
        XCTAssertEqual(owner.testModel?.layout.layout.window(WindowID(number: 1))?.panes, [PaneID(number: 1), PaneID(number: 2)], "the parent's window is unchanged")
        owner.paneCommand(.float, float)
        try await wait("the pane floats again") { owner.testModel?.layout.layout.window(child.window)?.floats.count == 1 }
        try await ko(["api", "-X", "DELETE", "/panes/\(float)"], dir: fixture.dir)
        try await wait("focus returns to the child") { owner.testModel?.selection.pane == child.pane && owner.testSession?.windows[child.window]?.displayedPanes.contains { $0.pane == float } != true }
    }

    func testChildWindowNavigationSizingAndClose() async throws {
        let fixture = try await ownerFixture()
        let owner = fixture.owner
        let first = fixture.children[0], second = fixture.children[1]
        let inheritedDirectory = URL(fileURLWithPath: fixture.dir + "/child-work-2").resolvingSymlinksInPath().path
        func directory(_ pane: PaneID) -> String? { owner.testModel?.pane(pane).map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path } }
        for child in [first, second] {
            owner.perform(.jump(child))
            try await wait("child selected in its own window") {
                owner.testModel?.selection.pane == child.pane && owner.navigation.window == child.window
                    && owner.testSession?.windows[child.window]?.displayedPanes.contains { $0.pane == child.pane } == true
            }
        }
        func fitted() -> Bool {
            guard let model = owner.testModel, let server = model.layout.layout.window(second.window), let pane = owner.testSession?.windows[second.window]?.displayedPanes.first(where: { $0.pane == second.pane }) else { return false }
            return Int(pane.geometry.columns) == server.cols && Int(pane.geometry.rows) == server.rows
        }
        try await wait("the shown child's surface fits its own window") { fitted() }
        let display = try XCTUnwrap(owner.testSession)
        let sendSize = display.sizeClient
        var reports: [[WindowID]] = []
        display.sizeClient = { viewport, windows in reports.append(windows.map(\.window)); return sendSize(viewport, windows) }
        defer { display.sizeClient = sendSize }
        display.resetSizeReport()
        let rename = KoSchema.Edit.renameSession(.init(name: "resumed", session: first.session))
        try await ko(["layout", "edit", String(decoding: JSONEncoder().encode(rename), as: UTF8.self)], dir: fixture.dir)
        try await wait("unchanged layout resends the sizing after Welcome reset") { !reports.isEmpty }
        XCTAssertEqual(try XCTUnwrap(reports.last), [second.window], "the report names the shown window only")
        owner.window.setContentSize(NSSize(width: 1140, height: 780))
        try await wait("the child follows the resize") { fitted() }
        owner.paneCommand(.newWindow, second.pane)
        try await wait("new tab from the child") { owner.navigation.window != second.window && owner.testModel?.selection.pane != second.pane }
        let createdPane = try XCTUnwrap(owner.testModel?.selection.pane)
        XCTAssertEqual(directory(createdPane), inheritedDirectory)
        let body = KoSchema.CreatePane(command: .shell(.init(command: rawScript)), parent: first.pane)
        let input = fixture.dir + "/grandchild.json"
        try JSONEncoder().encode(body).write(to: URL(fileURLWithPath: input))
        let reply = try await ko(["api", "-X", "POST", "--input", input, "/panes"], dir: fixture.dir)
        let grandchild = try JSONDecoder().decode(Snapshot.Position.self, from: Data(reply.utf8))
        try await wait("grandchild in its own tab") { owner.navigation.windows.contains { $0.id == grandchild.window } }
        owner.perform(.jump(grandchild))
        try await wait("grandchild focused in its own window") { owner.testModel?.selection.pane == grandchild.pane && owner.testSession?.windows[grandchild.window]?.active == grandchild.pane }
        owner.paneCommand(.close, first.pane)
        XCTAssertTrue(owner.preparedAlert?.alert.informativeText.contains("2 panes") == true)
        owner.respondToAlert(.alertSecondButtonReturn)
        try await wait("close cancelled") { owner.window.attachedSheet == nil }
        XCTAssertNotNil(owner.testModel?.pane(first.pane))
        XCTAssertNotNil(owner.testModel?.pane(grandchild.pane))
        owner.paneCommand(.close, first.pane)
        owner.respondToAlert(.alertFirstButtonReturn)
        try await wait("the child and its descendant are closed") { owner.testModel?.pane(first.pane) == nil && owner.testModel?.pane(grandchild.pane) == nil }
    }
}

import Foundation
import Testing
import KoModel
@testable import SidebarFeed

private func notifier() throws -> NotifierState {
    var state = NotifierState()
    _ = state.step(owner: "a", host: "local", snapshot: makeSnapshot([]), fresh: true, shown: [], appActive: false)
    return state
}

private func step(_ state: inout NotifierState, _ nodes: [Node], owner: String = "a", host: String = "local",
                  identity: String? = nil, fresh: Bool = false, seen: Bool = false, shown: Set<WindowID> = [], appActive: Bool = false) throws -> NotifierEffects {
    let snapshot: Snapshot = makeSnapshot(nodes)
    return state.step(owner: owner, host: host, identity: identity, snapshot: seen ? markedSeen(snapshot) : snapshot, fresh: fresh, shown: shown, appActive: appActive)
}

@Test func notificationBaselines() throws {
    let nodes = [pane(1, lifecycle: agent(waiting()), mark: .waiting), pane(2, lifecycle: agent(idle(outcome(17, .failure))), mark: .failed)]
    var state = NotifierState()
    #expect(try step(&state, nodes, fresh: true).post.isEmpty)
    #expect(try step(&state, nodes).post.isEmpty)
    let changed = [pane(1, lifecycle: agent(idle(outcome(18, .failure))), mark: .failed)]
    #expect(try step(&state, changed).post.count == 1)
    #expect(try step(&state, nodes, fresh: true).withdraw.count == 1)
    #expect(try step(&state, nodes).post.isEmpty)
    #expect(try step(&state, changed).post.count == 1)
    let snapshot = makeSnapshot(nodes, instance: "12346/1780000000")
    let effects = state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, shown: [], appActive: false)
    #expect(effects.withdraw.count == 1)
    #expect(effects.post.isEmpty)
    #expect(sidebarRows(snapshot).contains { $0.status == .error })
    #expect(state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, shown: [], appActive: false).post.isEmpty)
}

@Test func notificationSuppressionAcknowledges() throws {
    var state = try notifier()
    let nodes = [pane(1, window: 7, lifecycle: agent(waiting()), mark: .waiting)]
    #expect(try step(&state, nodes, shown: [WindowID(number: 7)]).post.isEmpty)
    #expect(try step(&state, nodes).post.isEmpty)
    _ = try step(&state, [])
    #expect(try step(&state, nodes).post.count == 1)
    #expect(try step(&state, nodes, shown: [WindowID(number: 7)]).withdraw.count == 1)
    #expect(try step(&state, nodes).post.isEmpty)
}

// A failure posts when the core's mark turns failed; it posts again only after the mark cleared.
@Test func notificationFailureFollowsTheMark() throws {
    var state = try notifier()
    let first = [pane(1, lifecycle: agent(idle(outcome(17, .failure))), mark: .failed)]
    #expect(try step(&state, first).post.count == 1)
    #expect(try step(&state, first).post.isEmpty)
    let second = [pane(1, lifecycle: agent(idle(outcome(18, .failure))), mark: .failed)]
    #expect(try step(&state, second).post.isEmpty, "the mark stays failed")
    #expect(try step(&state, second, seen: true).withdraw.count == 1)
    #expect(try step(&state, first).post.count == 1)
    #expect(try step(&state, [pane(1, lifecycle: terminal(exited(130)), mark: .failed)]).withdraw.count == 1, "an interrupted command is no failure")
    let effects = try step(&state, [pane(1, lifecycle: terminal(exited(1)), mark: .failed)])
    #expect(effects.post.map(\.body) == ["Exit 1: false"])
}

@Test func notificationWaitingIsOneReason() throws {
    var state = try notifier()
    #expect(try step(&state, [pane(1, lifecycle: agent(waiting(.permission)), mark: .waiting)]).post.count == 1)
    #expect(try step(&state, [pane(1, lifecycle: agent(waiting(.question)), mark: .waiting)]).post.isEmpty)
    #expect(try step(&state, [pane(1, lifecycle: agent(working()), mark: .running)]).withdraw.count == 1)
    #expect(try step(&state, [pane(1, lifecycle: agent(waiting()), mark: .waiting)]).post.count == 1)
}

@Test(arguments: ["seen", "work", "success", "waiting-ended", "disappeared"])
func notificationWithdraws(cause: String) throws {
    var state = try notifier()
    let lifecycle = cause == "waiting-ended" ? agent(waiting()) : agent(idle(outcome(17, .failure)))
    let nodes = [pane(1, lifecycle: lifecycle, mark: cause == "waiting-ended" ? .waiting : .failed)]
    #expect(try step(&state, nodes).post.count == 1)
    let seen = cause == "seen"
    let next: [Node]
    switch cause {
    case "seen": next = nodes
    case "work": next = [pane(1, lifecycle: agent(working()), mark: .running)]
    case "success": next = [pane(1, lifecycle: agent(idle(outcome(18, .success))), mark: .done)]
    case "waiting-ended": next = [pane(1, lifecycle: agent(idle()))]
    default: next = []
    }
    let effects = try step(&state, next, seen: seen)
    #expect(effects.withdraw.map(\.pane) == [PaneID(number: 1)])
    #expect(effects.post.isEmpty)
    #expect(try step(&state, next, seen: seen).withdraw.isEmpty)
}

// The core clears the mark of an outcome that an attended view showed; every owner withdraws it.
@Test func notificationSeenMarkWithdrawsForEveryOwner() throws {
    let nodes = [pane(1, lifecycle: agent(idle(outcome(17, .failure))), mark: .failed)]
    var state = try notifier()
    #expect(try step(&state, nodes).post.count == 1)
    _ = try step(&state, [], owner: "b", fresh: true)
    #expect(try step(&state, nodes, owner: "b").post.count == 1)
    for owner in ["a", "b"] { #expect(try step(&state, nodes, owner: owner, seen: true).withdraw.count == 1) }
    #expect(try step(&state, nodes, fresh: true, seen: true).post.isEmpty)
    #expect(try step(&state, nodes, seen: true).post.isEmpty)
    #expect(!sidebarRows(markedSeen(makeSnapshot(nodes))).contains { $0.status == .error })
    #expect(sidebarRows(makeSnapshot(nodes)).contains { $0.status == .error })
}

@Test func notificationTopLevelPanePosts() throws {
    var state = try notifier()
    let effects = try step(&state, [pane(1, lifecycle: piAgent(waiting()), mark: .waiting)])
    #expect(effects.post.count == 1 && effects.post.first?.kind == .waiting)
}

@Test func notificationNestedPanePosts() throws {
    var state = try notifier()
    let parent = pane(0, lifecycle: piAgent(working()), mark: .running, children: [pane(1, lifecycle: piAgent(waiting()), mark: .waiting)])
    #expect(try step(&state, [parent]).post.count == 1)
}

private func paneGroup() -> Node {
    group(5, [pane(1, window: 5, lifecycle: piAgent(waiting()), mark: .waiting), pane(2, window: 5, lifecycle: terminal())])
}

@Test func notificationTopLevelGroupPanePosts() throws {
    var state = try notifier()
    let effects = try step(&state, [paneGroup()])
    #expect(effects.post.count == 1 && effects.post.first?.key.pane == PaneID(number: 1))
}

@Test func notificationNestedGroupPanePosts() throws {
    var state = try notifier()
    let parent = pane(0, lifecycle: piAgent(working()), mark: .running, children: [paneGroup()])
    #expect(try step(&state, [parent]).post.count == 1)
}

@Test func notificationNonFailuresNeverPost() throws {
    var state = try notifier()
    let nodes = [pane(1, lifecycle: terminal(exited(130)), mark: .failed), pane(2, lifecycle: terminal(exited(0)), mark: .done),
                 pane(3, lifecycle: agent(idle(outcome(1, .success))), mark: .done),
                 pane(5, lifecycle: terminal(running()), mark: .running), pane(6, lifecycle: terminal(.unknown)),
                 pane(7, lifecycle: terminal(.pending(.init(last: .init(code: 130, command: "cancel", endedAt: since + 1_000_000_000, startedAt: since)))), mark: .failed)]
    #expect(try step(&state, nodes).post.isEmpty)
    #expect(sidebarRows(makeSnapshot(nodes)).contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 1)) && $0.status == .error })
}

@Test(arguments: ["unknown", "idle", "pending", "running", "fullscreen"])
func notificationReportsFollowIndicator(phaseName: String) throws {
    let phase: KoSchema.Phase = switch phaseName {
    case "unknown": .unknown
    case "idle": exited(0)
    case "pending": .pending(.init(last: .init(code: 130, command: "cancel", endedAt: since + 1_000_000_000, startedAt: since)))
    case "fullscreen": running(nil, fullscreen: true)
    default: running()
    }
    var state = try notifier()
    let waitingNodes = [pane(1, lifecycle: terminal(phase, report: report(waiting(), msg: "permission")), mark: .waiting)]
    #expect(try step(&state, waitingNodes).post.first?.body == "Waiting: permission")
    let failed = [pane(1, lifecycle: terminal(phase, report: report(idle(outcome(1, .failure)), msg: "broken")), mark: .failed)]
    #expect(try step(&state, failed).post.first?.body == "Failed: broken")
    let quiet = [pane(1, lifecycle: terminal(phase, report: report(idle(outcome(2, .success)))), mark: .done)]
    #expect(try step(&state, quiet).withdraw.count == 1)
    #expect(try step(&state, quiet).post.isEmpty)
    let empty = [pane(1, lifecycle: terminal(phase, report: report(idle())))]
    #expect(try step(&state, empty).post.isEmpty)
    #expect(!sidebarRows(makeSnapshot(empty)).contains { $0.status == .error })
}

@Test func notificationOwnersAndForgetAreIndependent() throws {
    var state = try notifier()
    _ = try step(&state, [], owner: "b", fresh: true)
    let nodes = [pane(1, lifecycle: agent(waiting()), mark: .waiting)]
    let a = try step(&state, nodes).post
    let b = try step(&state, nodes, owner: "b").post
    #expect(a.count == 1 && b.count == 1 && a.first?.key != b.first?.key)
    #expect(state.forget(owner: "a").withdraw == a.map(\.key))
    #expect(state.forget(owner: "a").withdraw.isEmpty)
    #expect(try step(&state, nodes, owner: "b").post.isEmpty)
    #expect(state.forget(owner: "b").withdraw == b.map(\.key))
    _ = try step(&state, nodes, fresh: true)
    #expect(state.forget(owner: "a").withdraw.isEmpty)
}

@Test func notificationLinkedPanePrefersClientSession() throws {
    var state = try notifier()
    let nodes = [pane(1, lifecycle: agent(waiting()), mark: .waiting)]
    var snapshot = makeSnapshot(nodes, sessions: [2, 0, 1])
    var effects = state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, shown: [], appActive: false)
    #expect(effects.post.count == 1)
    #expect(effects.post.first?.subtitle == "session-0")
    #expect(effects.post.first?.target.position.session == SessionID(number: 0))
    _ = state.forget(owner: "a")
    _ = try step(&state, [], fresh: true)
    snapshot = makeSnapshot(nodes, client: 9, clientSession: 9, sessions: [2, 0, 1])
    effects = state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, shown: [], appActive: false)
    #expect(effects.post.count == 1)
    #expect(effects.post.first?.subtitle == "session-2")
}

@Test func notificationContentAndTargetCoding() throws {
    var state = try notifier()
    let pi = piAgent(waiting(), msg: "Allow access")
    let nodes = [pane(1, title: "worker", lifecycle: pi, mark: .waiting), pane(2, title: "@named", lifecycle: pi, mark: .waiting),
                 pane(3, title: "raw", lifecycle: terminal(exited(2)), mark: .failed),
                 pane(4, title: "remote worker", lifecycle: remote(.agent(.init(name: "pi", status: report(waiting())))), mark: .waiting),
                 pane(5, title: "raw", lifecycle: remote(.terminal(.init(interactive: true, status: shell(exited(1))))), mark: .failed),
                 pane(6, title: "remote agent", lifecycle: .live(.ssh(.init(destination: "@host", pane: .agent(.init(name: "pi", status: report(waiting())))))), mark: .waiting)]
    let posts = try step(&state, nodes).post
    #expect(posts.map(\.title) == ["@worker", "@named", "Terminal", "remote worker", "ssh alice@devbox", "remote agent"])
    #expect(posts[0].body == "Waiting: Allow access")
    #expect(posts[2].body == "Exit 2: false")
    #expect(posts[3].subtitle == "session-0 · alice@devbox")
    #expect(posts[4].subtitle == "session-0")
    #expect(posts[5].subtitle == "session-0 · @host")
    #expect(try JSONDecoder().decode(NoticeTarget.self, from: JSONEncoder().encode(posts[0].target)) == posts[0].target)
    _ = try step(&state, [], owner: "remote", host: "ssh:dev", fresh: true)
    let remotePosts = try step(&state, nodes, owner: "remote", host: "ssh:dev", identity: "bob@machine").post
    #expect(remotePosts[0].subtitle == "bob@machine · session-0")
    #expect(remotePosts[0].target.host == "ssh:dev")
}

@Test(arguments: [false, true]) func notificationFullCommand(pending: Bool) throws {
    var state = try notifier()
    let command = "line\n" + String(repeating: "x", count: 130)
    let last = KoSchema.CommandExit(code: 2, command: command, endedAt: since + 1_000_000_000, startedAt: since)
    let phase: KoSchema.Phase = pending ? .pending(.init(last: last)) : .idle(.init(last: last))
    #expect(try step(&state, [pane(1, lifecycle: terminal(phase), mark: .failed)]).post.first?.body == "Exit 2: " + command)
}


@Test func notificationActiveAcknowledges() throws {
    var state = try notifier()
    let waiting = [pane(1, lifecycle: agent(waiting()), mark: .waiting)]
    #expect(try step(&state, waiting, appActive: true).post.isEmpty)
    #expect(try step(&state, waiting).post.isEmpty)
    let failed = [pane(1, lifecycle: agent(idle(outcome(17, .failure))), mark: .failed)]
    let post = try step(&state, failed)
    #expect(post.post.first?.kind == .failed)
    #expect(state.postedCount == 1)
    #expect(try step(&state, failed, appActive: true).withdraw.isEmpty)
    #expect(state.postedCount == 1)
    #expect(try step(&state, waiting, appActive: true).withdraw.count == 1)
    #expect(state.postedCount == 0)
    #expect(try step(&state, waiting).post.isEmpty)
    #expect(try step(&state, failed).post.count == 1)
    #expect(state.forget(owner: "a").withdraw.count == 1)
    #expect(state.postedCount == 0)
}

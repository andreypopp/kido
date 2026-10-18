import Foundation
import Testing
import TmuxControl
@testable import SidebarFeed

private func notifier() throws -> NotifierState {
    var state = NotifierState()
    _ = state.step(owner: "a", host: "local", snapshot: try decode(snapshotObject([])), fresh: true, seen: SidebarSeen(), shown: [], appActive: false)
    return state
}

private func step(_ state: inout NotifierState, _ nodes: [[String: Any]], owner: String = "a", host: String = "local",
                  identity: String? = nil, fresh: Bool = false, seen: SidebarSeen = SidebarSeen(), shown: Set<WindowID> = [], appActive: Bool = false) throws -> NotifierEffects {
    state.step(owner: owner, host: host, identity: identity, snapshot: try decode(snapshotObject(nodes)), fresh: fresh, seen: seen, shown: shown, appActive: appActive)
}

@Test func notificationBaselines() throws {
    let nodes = [pane(1, lifecycle: agent(waiting())), pane(2, lifecycle: agent(idle(outcome(17, "failure"))))]
    var state = NotifierState()
    #expect(try step(&state, nodes, fresh: true).post.isEmpty)
    #expect(try step(&state, nodes).post.isEmpty)
    let changed = [pane(1, lifecycle: agent(idle(outcome(18, "failure"))))]
    #expect(try step(&state, changed).post.count == 1)
    #expect(try step(&state, nodes, fresh: true).withdraw.count == 1)
    #expect(try step(&state, nodes).post.isEmpty)
    var object = snapshotObject(nodes)
    object["server_instance"] = ["started_at": 1780000000, "pid": 12346]
    #expect(try step(&state, changed).post.count == 1)
    let snapshot: Snapshot = try decode(object)
    let effects = state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, seen: SidebarSeen(), shown: [], appActive: false)
    #expect(effects.withdraw.count == 1)
    #expect(effects.post.isEmpty)
    #expect(sidebarRows(snapshot).contains { $0.status == .error })
    #expect(state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, seen: SidebarSeen(), shown: [], appActive: false).post.isEmpty)
}

@Test func notificationErrorsAreInert() throws {
    var state = try notifier()
    let nodes = [pane(1, lifecycle: agent(waiting()))]
    #expect(try step(&state, nodes).post.count == 1)
    let before = state
    let error: Snapshot = try decode(snapshotObject([], error: "offline"))
    let effects = state.step(owner: "a", host: "local", snapshot: error, fresh: true, seen: SidebarSeen(), shown: [], appActive: false)
    #expect(effects.post.isEmpty && effects.withdraw.isEmpty)
    #expect(state == before)
    #expect(try step(&state, nodes, fresh: true).withdraw.count == 1)
    #expect(try step(&state, nodes).post.isEmpty)
    var initial = NotifierState()
    #expect(initial.step(owner: "a", host: "local", snapshot: error, fresh: true, seen: SidebarSeen(), shown: [], appActive: false).post.isEmpty)
    #expect(try step(&initial, nodes, fresh: true).post.isEmpty)
}

@Test func notificationSuppressionAcknowledges() throws {
    var state = try notifier()
    let nodes = [pane(1, window: 7, lifecycle: agent(waiting()))]
    #expect(try step(&state, nodes, shown: [WindowID(number: 7)]).post.isEmpty)
    #expect(try step(&state, nodes).post.isEmpty)
    _ = try step(&state, [])
    #expect(try step(&state, nodes).post.count == 1)
    #expect(try step(&state, nodes, shown: [WindowID(number: 7)]).withdraw.count == 1)
    #expect(try step(&state, nodes).post.isEmpty)
}

@Test func notificationFailureIdentityReposts() throws {
    var state = try notifier()
    let first = [pane(1, lifecycle: agent(idle(outcome(17, "failure"))))]
    #expect(try step(&state, first).post.count == 1)
    #expect(try step(&state, first).post.isEmpty)
    let second = [pane(1, lifecycle: agent(idle(outcome(18, "failure"))))]
    let effects = try step(&state, second)
    #expect(effects.post.count == 1 && effects.withdraw.isEmpty)
    #expect(try step(&state, second, shown: [WindowID(number: 1)]).withdraw.count == 1)
    #expect(try step(&state, first).post.count == 1)
    let command = [pane(1, lifecycle: terminal(exited(1)))]
    #expect(try step(&state, command).post.count == 1)
    #expect(try step(&state, [pane(1, lifecycle: terminal(exited(1, ended: 1780000002)))]).post.count == 1)
}

@Test func notificationWaitingIsOneReason() throws {
    var state = try notifier()
    #expect(try step(&state, [pane(1, lifecycle: agent(waiting("permission")))]).post.count == 1)
    #expect(try step(&state, [pane(1, lifecycle: agent(waiting("question")))]).post.isEmpty)
    #expect(try step(&state, [pane(1, lifecycle: agent(working()))]).withdraw.count == 1)
    #expect(try step(&state, [pane(1, lifecycle: agent(waiting()))]).post.count == 1)
}

@Test(arguments: ["seen", "work", "success", "waiting-ended", "disappeared"])
func notificationWithdraws(cause: String) throws {
    var state = try notifier()
    let lifecycle = cause == "waiting-ended" ? agent(waiting()) : agent(idle(outcome(17, "failure")))
    let nodes = [pane(1, lifecycle: lifecycle)]
    #expect(try step(&state, nodes).post.count == 1)
    var seen = SidebarSeen()
    let next: [[String: Any]]
    switch cause {
    case "seen": seen.observe(try decode(snapshotObject([])), attended: false); seen.observe(try decode(snapshotObject(nodes, client: 1)), attended: true); next = nodes
    case "work": next = [pane(1, lifecycle: agent(working()))]
    case "success": next = [pane(1, lifecycle: agent(idle(outcome(18, "success"))))]
    case "waiting-ended": next = [pane(1, lifecycle: agent(idle()))]
    default: next = []
    }
    let effects = try step(&state, next, seen: seen)
    #expect(effects.withdraw.map(\.pane) == [PaneID(number: 1)])
    #expect(effects.post.isEmpty)
    #expect(try step(&state, next, seen: seen).withdraw.isEmpty)
}

@Test func notificationSeenAttendanceAndReconnect() throws {
    var seen = SidebarSeen()
    seen.observe(try decode(snapshotObject([])), attended: false)
    let nodes = [pane(1, lifecycle: agent(idle(outcome(17, "failure"))))]
    let snapshot: Snapshot = try decode(snapshotObject(nodes, client: 1))
    seen.observe(snapshot, attended: false)
    var state = try notifier()
    #expect(try step(&state, nodes, seen: seen).post.count == 1)
    _ = try step(&state, [], owner: "b", fresh: true)
    #expect(try step(&state, nodes, owner: "b", seen: seen).post.count == 1)
    seen.observe(snapshot, attended: true)
    for owner in ["a", "b"] { #expect(try step(&state, nodes, owner: owner, seen: seen).withdraw.count == 1) }
    #expect(try step(&state, nodes, fresh: true, seen: seen).post.isEmpty)
    #expect(try step(&state, nodes, seen: seen).post.isEmpty)
    var object = snapshotObject(nodes)
    object["server_instance"] = ["started_at": 1780000000, "pid": 12346]
    let restarted: Snapshot = try decode(object)
    seen.observe(restarted, attended: false)
    #expect(sidebarRows(restarted, seen: seen).contains { $0.status == .error })
}

@Test(arguments: ["agent", "bash", "stream"])
func notificationRunsNeverPost(run: String) throws {
    var state = try notifier()
    #expect(try step(&state, [pane(1, lifecycle: agent(waiting()), run: run),
                             pane(2, lifecycle: ["Ended", ["result": "failed"]], run: run)]).post.isEmpty)
}

@Test func notificationNonFailuresNeverPost() throws {
    var state = try notifier()
    let nodes = [pane(1, lifecycle: terminal(exited(130))), pane(2, lifecycle: terminal(exited(0))),
                 pane(3, lifecycle: agent(idle(outcome(1, "success")))),
                 pane(5, lifecycle: terminal(running())), pane(6, lifecycle: terminal(["Unknown"]))]
    #expect(try step(&state, nodes).post.isEmpty)
    #expect(sidebarRows(try decode(snapshotObject(nodes))).contains { $0.id == .pane(SessionID(number: 0), PaneID(number: 1)) && $0.status == .error })
}

@Test(arguments: ["unknown", "idle", "running", "fullscreen"])
func notificationReportsFollowIndicator(phaseName: String) throws {
    let phase: [Any] = switch phaseName {
    case "unknown": ["Unknown"]
    case "idle": exited(2)
    case "fullscreen": running(nil, fullscreen: true)
    default: running()
    }
    var state = try notifier()
    let waitingNodes = [pane(1, lifecycle: terminal(phase, report: report(waiting(), msg: "permission")))]
    #expect(try step(&state, waitingNodes).post.first?.body == "Waiting: permission")
    let failed = [pane(1, lifecycle: terminal(phase, report: report(idle(outcome(1, "failure")), msg: "broken")))]
    #expect(try step(&state, failed).post.first?.body == "Failed: broken")
    let quiet = [pane(1, lifecycle: terminal(phase, report: report(idle(outcome(2, "success")))))]
    #expect(try step(&state, quiet).withdraw.count == 1)
    #expect(try step(&state, quiet).post.isEmpty)
    let empty = [pane(1, lifecycle: terminal(phase, report: report(idle())))]
    #expect(try step(&state, empty).post.isEmpty)
    #expect(!sidebarRows(try decode(snapshotObject(empty))).contains { $0.status == .error })
}

@Test func notificationSeenReportStillMasksCommandFailure() throws {
    var state = try notifier()
    var seen = SidebarSeen()
    seen.observe(try decode(snapshotObject([])), attended: false)
    let nodes = [pane(1, lifecycle: terminal(exited(2), report: report(idle(outcome(17, "failure")))))]
    #expect(try step(&state, nodes).post.first?.body == "Failed")
    seen.observe(try decode(snapshotObject(nodes, client: 1)), attended: true)
    let next = [pane(1, lifecycle: terminal(exited(2, ended: 1780000003), report: report(idle(outcome(17, "failure")))))]
    #expect(try step(&state, next, seen: seen).withdraw.count == 1)
    #expect(try step(&state, next, seen: seen).post.isEmpty)
    #expect(!sidebarRows(try decode(snapshotObject(next)), seen: seen).contains { $0.status == .error })
}

@Test func notificationFailureSourceIsPartOfIdentity() throws {
    var state = try notifier()
    #expect(try step(&state, [pane(1, lifecycle: agent(idle(outcome(17, "failure"))))]).post.count == 1)
    #expect(try step(&state, [pane(1, lifecycle: terminal(report: report(idle(outcome(17, "failure")))))]).post.count == 1)
}

@Test func notificationOwnersAndForgetAreIndependent() throws {
    var state = try notifier()
    _ = try step(&state, [], owner: "b", fresh: true)
    let nodes = [pane(1, lifecycle: agent(waiting()))]
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
    var object = snapshotObject([pane(1, lifecycle: agent(waiting()))], sessions: [2, 0, 1])
    var snapshot: Snapshot = try decode(object)
    var effects = state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, seen: SidebarSeen(), shown: [], appActive: false)
    #expect(effects.post.count == 1)
    #expect(effects.post.first?.subtitle == "session-0")
    #expect(effects.post.first?.target.position.session == SessionID(number: 0))
    _ = state.forget(owner: "a")
    _ = try step(&state, [], fresh: true)
    object["client"] = ["session": "$9", "window": "@9", "pane": "%9"]
    snapshot = try decode(object)
    effects = state.step(owner: "a", host: "local", snapshot: snapshot, fresh: false, seen: SidebarSeen(), shown: [], appActive: false)
    #expect(effects.post.count == 1)
    #expect(effects.post.first?.subtitle == "session-2")
}

@Test func notificationContentAndTargetCoding() throws {
    var state = try notifier()
    let pi: [Any] = ["Live", ["Pi_agent", ["id": "pi", "status": report(waiting(), msg: "Allow access")]]]
    let nodes = [pane(1, title: "worker", lifecycle: pi), pane(2, title: "@named", lifecycle: pi),
                 pane(3, title: "raw", lifecycle: terminal(exited(2))),
                 pane(4, title: "remote worker", lifecycle: remote(["Remote_agent", ["name": "pi", "status": report(waiting())]])),
                 pane(5, title: "raw", lifecycle: remote(["Remote_terminal", ["interactive": true, "status": shell(exited(1))]]))]
    let posts = try step(&state, nodes).post
    #expect(posts.map(\.title) == ["@worker", "@named", "Terminal", "remote worker", "ssh alice@devbox"])
    #expect(posts[0].body == "Waiting: Allow access")
    #expect(posts[2].body == "Exit 2: false")
    #expect(posts[3].subtitle == "session-0 · alice@devbox")
    #expect(posts[4].subtitle == "session-0")
    #expect(try JSONDecoder().decode(NoticeTarget.self, from: JSONEncoder().encode(posts[0].target)) == posts[0].target)
    _ = try step(&state, [], owner: "remote", host: "ssh:dev", fresh: true)
    let remotePosts = try step(&state, nodes, owner: "remote", host: "ssh:dev", identity: "bob@machine").post
    #expect(remotePosts[0].subtitle == "bob@machine · session-0")
    #expect(remotePosts[0].target.host == "ssh:dev")
}

@Test func notificationFullCommand() throws {
    var state = try notifier()
    let command = "line\n" + String(repeating: "x", count: 130)
    let phase: [Any] = ["Idle", ["last": ["code": 2, "command": command, "started_at": 1780000000, "ended_at": 1780000001]]]
    #expect(try step(&state, [pane(1, lifecycle: terminal(phase))]).post.first?.body == "Exit 2: " + command)
}


@Test func notificationActiveAcknowledges() throws {
    var state = try notifier()
    let waiting = [pane(1, lifecycle: agent(waiting()))]
    #expect(try step(&state, waiting, appActive: true).post.isEmpty)
    #expect(try step(&state, waiting).post.isEmpty)
    let failed = [pane(1, lifecycle: agent(idle(outcome(17, "failure"))))]
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

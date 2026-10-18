import Foundation
@testable import SidebarFeed

var null: NSNull { NSNull() }

func idle(_ outcome: Any = null) -> [Any] { ["Idle", ["outcome": outcome]] }
func outcome(_ serial: Int, _ result: String) -> [String: Any] { ["serial": serial, "result": result] }

func agent(_ state: [Any] = idle(), msg: Any = null, name: String = "claude-code") -> [Any] {
    ["Live", ["Some_agent", ["name": name, "status": report(state, msg: msg)]]]
}

func shell(_ phase: [Any] = ["Idle", ["last": null]], report: Any = null) -> [String: Any] { ["phase": phase, "report": report] }
func terminal(_ phase: [Any] = ["Idle", ["last": null]], report: Any = null) -> [Any] { ["Live", ["Terminal", shell(phase, report: report)]] }
func exited(_ code: Int, started: Double = 1780000000, ended: Double = 1780000001.25) -> [Any] {
    ["Idle", ["last": ["code": code, "command": "false", "started_at": started, "ended_at": ended]]]
}
func running(_ command: String? = "make", fullscreen: Bool = false) -> [Any] {
    ["Running", ["origin": command.map { ["Command", ["command": $0, "started_at": 1780000000]] as [Any] } ?? ["Unknown"], "fullscreen": fullscreen]]
}
func report(_ state: [Any], msg: Any = null) -> [String: Any] { ["since": 1780000000, "msg": msg, "state": state] }

func pane(_ id: Int, window: Int? = nil, title: String = "", lifecycle: [Any] = terminal(), run: String? = nil, started: Double? = nil,
          records: [[String: Any]] = [], serial: Int = 0, children: [[String: Any]] = []) -> [String: Any] {
    ["kind": "pane", "id": "%\(id)", "pane": "%\(id)", "window": "@\(window ?? id)", "title": title, "lifecycle": lifecycle,
     "program_status": ["serial": serial, "records": records], "run": run as Any? ?? null, "started": started as Any? ?? null, "children": children]
}

func snapshotObject(_ nodes: [[String: Any]], client: Int = 0, window: Int? = nil, sessions: [Int] = [0], error: Any = null) -> [String: Any] {
    ["v": 2, "client": ["session": "$0", "window": "@\(window ?? client)", "pane": "%\(client)"], "server_instance": ["started_at": 1780000000, "pid": 12345], "error": error,
     "sessions": sessions.map { ["id": "$\($0)", "name": "session-\($0)", "current": $0 == 0, "nodes": nodes] }]
}

func decode<T: Decodable>(_ object: Any, as type: T.Type = Snapshot.self) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
func waiting(_ kind: Any = null, progress: Any = null) -> [Any] { ["Waiting", ["kind": kind, "progress": progress]] }
func working(_ progress: Any = null) -> [Any] { ["Running", ["progress": progress]] }
func remote(_ pane: [Any], user: String = "alice", host: String = "devbox") -> [Any] { ["Live", ["Ssh", ["user": user, "host": host, "pane": pane]]] }

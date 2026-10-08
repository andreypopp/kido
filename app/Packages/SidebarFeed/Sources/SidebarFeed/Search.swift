import Foundation

public func sidebarSearch(_ snapshot: Snapshot?, query: String) -> Snapshot? {
    guard var snapshot, !query.isEmpty else { return snapshot }
    let pattern = query.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
    func score(_ text: String) -> Int? {
        var i = 0, score = 0, run = 0
        for byte in text.utf8 {
            if i == pattern.count { return score }
            let lower = (65...90).contains(byte) ? byte + 32 : byte
            if lower == pattern[i] { i += 1; score += 1 + run; run += 2 }
            else { score -= 1; run = 0 }
        }
        return i == pattern.count ? score : nil
    }
    let matches: [(Int, Int, SessionNodes)] = snapshot.sessions.enumerated().compactMap { index, session in
        var best = score(session.name)
        func visit(_ node: Node) {
            if case .item(let item) = node {
                let title: String? = item.kind == .agent ? item.label : item.kind == .ssh && item.title.count > 1 ? item.title[1].text : nil
                if let title, let match = score(title) { best = max(best ?? match, match) }
            }
            node.children.forEach(visit)
        }
        session.nodes.forEach(visit)
        return best.map { (index, $0, session) }
    }
    snapshot.sessions = matches.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.map { $0.2 }
    return snapshot
}

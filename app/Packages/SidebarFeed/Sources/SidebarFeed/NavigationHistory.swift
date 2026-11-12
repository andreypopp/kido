import KoModel

public struct NavigationHistory: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case back, forward }

    private enum Cursor: Equatable, Sendable {
        case at(Int)
        case gap(Int)
    }

    static let capacity = 100
    private var entries: [Snapshot.Position] = []
    private var cursor = Cursor.gap(0)

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var current: Snapshot.Position? {
        if case .at(let index) = cursor { entries[index] } else { nil }
    }
    public var canBack: Bool { target(.back) != nil }
    public var canForward: Bool { target(.forward) != nil }

    private func index(_ step: Step) -> Int? {
        let next: Int
        switch (cursor, step) {
        case (.at(let i), .back), (.gap(let i), .back): next = i - 1
        case (.at(let i), .forward): next = i + 1
        case (.gap(let i), .forward): next = i
        }
        return entries.indices.contains(next) ? next : nil
    }

    public func target(_ step: Step) -> Snapshot.Position? {
        index(step).map { entries[$0] }
    }

    public mutating func go(_ step: Step, to position: Snapshot.Position) {
        if let index = index(step), entries[index] == position { cursor = .at(index) }
    }

    public mutating func push(_ position: Snapshot.Position) {
        guard position != current else { return }
        switch cursor {
        case .at(let i): entries.removeSubrange((i + 1)...)
        case .gap(let i): entries.removeSubrange(i...)
        }
        entries.append(position)
        if entries.count > Self.capacity { entries.removeFirst() }
        cursor = .at(entries.count - 1)
    }

    public mutating func prune(live: (PaneID) -> Snapshot.Position?) {
        var kept: [Snapshot.Position] = []
        var mapped: [Int?] = []
        var keptBeforeCursor = 0
        var breaksNext = false
        let marked: Int
        let wasGap: Bool
        switch cursor {
        case .at(let i): (marked, wasGap) = (i, false)
        case .gap(let i): (marked, wasGap) = (i, true)
        }
        for (i, entry) in entries.enumerated() {
            let position = live(entry.pane)
            if i == marked {
                keptBeforeCursor = kept.count
                breaksNext = wasGap || position == nil
            }
            guard let position else { mapped.append(nil); continue }
            if kept.last != position || breaksNext { kept.append(position) }
            if i >= marked { breaksNext = false }
            mapped.append(kept.count - 1)
        }
        if marked >= entries.count { keptBeforeCursor = kept.count }
        switch cursor {
        case .at(let i): cursor = mapped[i].map { .at($0) } ?? .gap(keptBeforeCursor)
        case .gap: cursor = .gap(keptBeforeCursor)
        }
        entries = kept
    }
}

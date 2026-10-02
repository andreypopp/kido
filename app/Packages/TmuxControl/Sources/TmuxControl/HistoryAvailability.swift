public enum HistoryAvailability: Equatable, Sendable {
    case ready(gap: Int)
    case limited(history: Int)

    public static func settled(total: Int, loaded: Int, insertionRefused: Bool = false) -> Self {
        let gap = max(0, total - loaded)
        return gap > 0 && insertionRefused ? .limited(history: total) : .ready(gap: gap)
    }
}

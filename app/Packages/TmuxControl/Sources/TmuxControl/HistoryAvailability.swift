public enum HistoryAvailability: Equatable, Sendable {
    case ready(gap: Int)
    case limited(history: Int)

    public static func settled(total: Int, loaded: Int, insertionRefused: Bool = false, emptyCaptureChunk: Int? = nil) -> Self {
        let gap = max(0, total - loaded)
        if gap > 0 && insertionRefused { return .limited(history: total) }
        return .ready(gap: emptyCaptureChunk.map { $0 >= gap } == true ? 0 : gap)
    }
}

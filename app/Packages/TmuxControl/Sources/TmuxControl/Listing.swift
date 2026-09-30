public struct SessionListing: Equatable, Sendable {
    public let id: SessionID
    public let name: String

    public static let format = "#{session_id}\u{1F}#{session_name}"

    public init?(_ line: String) {
        let f = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        guard f.count == 2, let id = SessionID(f[0]) else { return nil }
        self.id = id
        name = String(f[1])
    }
}

public struct WindowListing: Equatable, Sendable {
    public let id: WindowID
    public let active: Bool
    public let layout: Layout
    public let visible: Layout
    public let name: String

    public static let format =
        "#{window_id}\u{1F}#{window_active}\u{1F}#{window_layout}\u{1F}#{window_visible_layout}\u{1F}#{window_name}"

    public init?(_ line: String) {
        let f = line.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false)
        guard f.count == 5, let id = WindowID(f[0]), f[1] == "0" || f[1] == "1",
            let layout = try? Layout(json: f[2]), let visible = try? Layout(json: f[3])
        else { return nil }
        self.id = id
        active = f[1] == "1"
        self.layout = layout
        self.visible = visible
        name = String(f[4])
    }
}

// What the model says of a pane's runtime: derived from it, never stored. The colour to draw is the
// client's to decide from `color` and `name`.
public struct RuntimeMark: Equatable, Sendable {
    public let name: String
    public let kind: KoSchema.RuntimeKind?
    // The configured `#rrggbb`, as given.
    public let color: String?
    public let state: KoSchema.LinkState
    // A host pane of a pi agent whose tools run in the runtime.
    public let routed: Bool

    public init(name: String, kind: KoSchema.RuntimeKind?, color: String?, state: KoSchema.LinkState, routed: Bool) {
        self.name = name
        self.kind = kind
        self.color = color
        self.state = state
        self.routed = routed
    }

    public init(_ runtime: KoSchema.ClientRuntime, routed: Bool = false) {
        self.init(name: runtime.name, kind: runtime.kind, color: runtime.color, state: runtime.state, routed: routed)
    }

    // The failure message of a failed link, on one line.
    public var failure: String? {
        guard case .failed(let failed) = state else { return nil }
        return failed.message.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    public var stateWord: String {
        switch state {
        case .down: "down"
        case .starting: "starting"
        case .up: "up"
        case .failed: "failed"
        }
    }
}

extension KoSchema.ModelJson {
    private func runtime(_ name: String) -> KoSchema.ClientRuntime? { runtimes.first { $0.name == name } }

    // The runtime that a pane shows: its own, or the one that a routed pi agent works in. A runtime that the
    // list does not hold shows by its name alone.
    public func runtimeMark(_ pane: KoSchema.PaneJson) -> RuntimeMark? {
        guard let place = pane.place else { return nil }
        let (name, routed): (String, Bool) = switch place {
        case .pane(let place): (place.name, false)
        case .routed(let place): (place.name, true)
        }
        return runtime(name).map { RuntimeMark($0, routed: routed) }
            ?? RuntimeMark(name: name, kind: nil, color: nil, state: .down, routed: routed)
    }

    public var runtimeMarks: [PaneID: RuntimeMark] {
        Dictionary(panes.compactMap { pane in runtimeMark(pane).map { (pane.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    // The window's pane that a new pane is made from: the one that this client selected, else the window's focus.
    public func source(in window: KoSchema.Window) -> PaneID {
        if let current, current.window.id == window.id { current.pane } else { window.focus }
    }
}

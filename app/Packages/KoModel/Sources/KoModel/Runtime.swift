public struct RuntimeKey: Equatable, Sendable {
    public let name: String
    public let source: KoSchema.RuntimeSource

    public init(name: String, source: KoSchema.RuntimeSource) {
        self.name = name
        self.source = source
    }
}

extension KoSchema.ClientRuntime {
    public var key: RuntimeKey { RuntimeKey(name: name, source: source) }
}

extension KoSchema.Place {
    public var key: RuntimeKey {
        switch self {
        case .pane(let place): RuntimeKey(name: place.name, source: place.source)
        case .routed(let place): RuntimeKey(name: place.name, source: place.source)
        }
    }
}

public struct RuntimeMark: Equatable, Sendable {
    public let key: RuntimeKey
    public var name: String { key.name }
    public let kind: KoSchema.RuntimeKind?
    public let color: String?
    public let state: KoSchema.LinkState
    public let routed: Bool

    public init(key: RuntimeKey, kind: KoSchema.RuntimeKind?, color: String?, state: KoSchema.LinkState, routed: Bool) {
        self.key = key
        self.kind = kind
        self.color = color
        self.state = state
        self.routed = routed
    }

    public init(_ runtime: KoSchema.ClientRuntime, routed: Bool = false) {
        self.init(key: runtime.key, kind: runtime.kind, color: runtime.color, state: runtime.state, routed: routed)
    }

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
    public func runtime(_ key: RuntimeKey) -> KoSchema.ClientRuntime? { runtimes.first { $0.key == key } }

    public func runtimeMark(_ pane: KoSchema.PaneJson) -> RuntimeMark? {
        guard let place = pane.place else { return nil }
        let routed: Bool = if case .routed = place { true } else { false }
        return runtime(place.key).map { RuntimeMark($0, routed: routed) }
            ?? RuntimeMark(key: place.key, kind: nil, color: nil, state: .down, routed: routed)
    }

    public var runtimeMarks: [PaneID: RuntimeMark] {
        Dictionary(panes.compactMap { pane in runtimeMark(pane).map { (pane.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    public func source(in window: KoSchema.Window) -> PaneID {
        if let current, current.window.id == window.id { current.pane } else { window.focus }
    }
}

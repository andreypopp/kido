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

public enum RuntimeMark: Equatable, Sendable {
    case known(KoSchema.ClientRuntime, routed: Bool)
    case unavailable(RuntimeKey, routed: Bool)

    public var key: RuntimeKey {
        switch self {
        case .known(let runtime, _): runtime.key
        case .unavailable(let key, _): key
        }
    }
    public var name: String { key.name }
    public var kind: KoSchema.RuntimeKind? {
        if case .known(let runtime, _) = self { runtime.kind } else { nil }
    }
    public var color: String? {
        if case .known(let runtime, _) = self { runtime.color } else { nil }
    }
    public var state: KoSchema.LinkState {
        if case .known(let runtime, _) = self { runtime.state } else { .down }
    }
    public var routed: Bool {
        switch self {
        case .known(_, let routed), .unavailable(_, let routed): routed
        }
    }

    public var failure: String? { state.failure }
    public var stateWord: String { state.stateWord }
}

extension KoSchema.LinkState {
    public var failure: String? {
        guard case .failed(let failed) = self else { return nil }
        return failed.message.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    public var stateWord: String {
        switch self {
        case .down: "down"
        case .starting: "starting"
        case .up: "up"
        case .failed: "failed"
        }
    }
}

extension KoSchema.ModelJson {
    public func runtime(_ key: RuntimeKey) -> KoSchema.ClientRuntime? { runtimes.first { $0.runtime.key == key }?.runtime }

    public func runtimeMark(_ pane: KoSchema.PaneJson) -> RuntimeMark? {
        guard let place = pane.place else { return nil }
        let routed: Bool = if case .routed = place { true } else { false }
        return runtime(place.key).map { .known($0, routed: routed) }
            ?? .unavailable(place.key, routed: routed)
    }

    public var runtimeMarks: [PaneID: RuntimeMark] {
        Dictionary(panes.compactMap { pane in runtimeMark(pane).map { (pane.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    public func source(in window: KoSchema.Window) -> PaneID {
        if let current, current.window.id == window.id { current.pane } else { window.focus }
    }
}

public typealias KoModel = KoSchema.ModelJson

extension KoSchema.Window {
    // The panes of the tree in document order, then the floats.
    public var panes: [PaneID] {
        func leaves(_ node: KoSchema.LeafNode) -> [PaneID] {
            switch node {
            case .leaf(let leaf): [leaf.pane]
            case .split(let split): split.children.flatMap(leaves)
            }
        }
        return leaves(tree) + floats.map(\.pane)
    }
}

extension KoSchema.ModelJson {
    public func pane(_ id: PaneID) -> KoSchema.PaneJson? { panes.first { $0.id == id } }

    // The client's pane, else the selected session (else the first one), its selected window (else the
    // first one) and that window's focus.
    public var current: (session: KoSchema.Session, window: KoSchema.Window, pane: PaneID)? {
        let sessions = layout.layout.sessions
        if let pane = selection.pane, let (session, window) = layout.layout.locate(pane) { return (session, window, pane) }
        guard let session = sessions.first(where: { $0.id == selection.session }) ?? sessions.first,
              let window = session.windows.first(where: { $0.id == selection.window }) ?? session.windows.first else { return nil }
        return (session, window, window.focus)
    }
}

extension KoSchema.Layout {
    public var windows: [KoSchema.Window] { sessions.flatMap(\.windows) }
    public func session(_ id: SessionID) -> KoSchema.Session? { sessions.first { $0.id == id } }
    public func window(_ id: WindowID) -> KoSchema.Window? { windows.first { $0.id == id } }

    // The session and window that hold the pane.
    public func locate(_ pane: PaneID) -> (session: KoSchema.Session, window: KoSchema.Window)? {
        for session in sessions {
            if let window = session.windows.first(where: { $0.panes.contains(pane) }) { return (session, window) }
        }
        return nil
    }
}

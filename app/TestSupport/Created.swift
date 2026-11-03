import KoModel

extension KoSchema.Edited {
    var createdWindow: WindowID? { if case .window(let created)? = created { created.window } else { nil } }
    var createdPane: PaneID? { if case .pane(let created)? = created { created.pane } else { nil } }
}

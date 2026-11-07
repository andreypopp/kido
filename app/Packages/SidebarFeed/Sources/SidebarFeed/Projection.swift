import Foundation
import KoModel

extension Snapshot {
    /// The sidebar tree of the model, in the core's outline. Nil when the model holds no pane.
    public init?(model: KoModel, marks: [PaneID: RuntimeMark]? = nil) {
        guard let (session, window, pane) = model.current else { return nil }
        let projection = Projection(model, marks: marks ?? model.runtimeMarks)
        self.init(clock: .init(now: model.now, local: Int(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))), client: Position(session: session.id, window: window.id, pane: pane), serverInstance: ServerInstance(model.instance),
                  sessions: projection.sessions())
    }
}

private struct Projection {
    let model: KoModel
    let panes: [PaneID: KoSchema.PaneJson]
    let marks: [PaneID: RuntimeMark]

    init(_ model: KoModel, marks: [PaneID: RuntimeMark]) {
        self.model = model
        self.marks = marks
        panes = Dictionary(model.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // The outline lists each session and then its panes, a pane with a parent under that parent.
    func sessions() -> [SessionNodes] {
        var result: [SessionNodes] = []
        var outline: [KoSchema.ItemPane] = []
        func close() {
            guard let last = result.indices.last else { return }
            var start = 0
            result[last].nodes = nodes(outline, from: &start, depth: 0)
            outline = []
        }
        for entry in model.outline {
            switch entry {
            case .session(let session):
                close()
                result.append(SessionNodes(id: session.id, name: session.name, nodes: []))
            case .pane(let pane): outline.append(pane)
            }
        }
        close()
        return result
    }

    // The entries at `depth` from `start` on, each with the deeper entries that follow it as its children.
    // Neighbouring entries of one window form its group.
    private func nodes(_ outline: [KoSchema.ItemPane], from start: inout Int, depth: Int) -> [Node] {
        var nodes: [Node] = []
        while start < outline.count, outline[start].depth >= depth {
            let entry = outline[start]
            start += 1
            let children = self.nodes(outline, from: &start, depth: entry.depth + 1)
            guard let pane = panes[entry.id] else { continue }
            let item = Item(pane: pane, window: entry.window, children: children, runtime: marks[entry.id])
            switch nodes.last {
            case .item(let previous) where previous.window == item.window:
                nodes[nodes.count - 1] = .window(.init(id: item.window, children: [previous, item]))
            case .window(var group) where group.id == item.window:
                group.children.append(item)
                nodes[nodes.count - 1] = .window(group)
            default: nodes.append(.item(item))
            }
        }
        return nodes
    }
}

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
    let floats: Set<PaneID>

    init(_ model: KoModel, marks: [PaneID: RuntimeMark]) {
        self.model = model
        floats = Set(model.layout.layout.windows.flatMap { $0.floats.map(\.pane) })
        self.marks = marks
        panes = Dictionary(model.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func sessions() -> [SessionNodes] {
        var result: [SessionNodes] = []
        var outline: [KoSchema.ItemPane] = []
        func close() {
            guard let last = result.indices.last else { return }
            result[last].nodes = nodes(outline)
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

    private func nodes(_ outline: [KoSchema.ItemPane]) -> [Node] {
        var nodes: [Node] = []
        for entry in outline {
            guard let pane = panes[entry.id] else { continue }
            let item = Item(pane: pane, window: entry.window, runtime: marks[entry.id], placement: floats.contains(entry.id) ? .floating : .tiled)
            nodes.appendGrouped(item)
        }
        return nodes
    }
}

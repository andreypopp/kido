import Foundation
import KoClient
import KoModel
import PaneGeometry

// Sends the layout edits of the user's gestures, one at a time. The edit in flight runs on `queue`
// because the core blocks until the server answered; the successor waits. A waiting edit with the
// same key as a later one is replaced by it, so a drag sends only its latest step.
// The optimistic state of a gesture holds until a layout event shows the revision of the last
// accepted edit, or until the edits failed.
@MainActor final class LayoutEditor {
    enum Key: Hashable {
        case divider(PaneID)
        case float(PaneID)
    }

    private enum State {
        case idle
        case sending(edit: KoSchema.Edit, then: Done?, waiting: [Waiting])
    }

    typealias Done = (Result<KoSchema.Edited, Error>) -> Void
    private typealias Waiting = (edit: KoSchema.Edit, key: Key?, then: Done?)

    private let queue = DispatchQueue(label: "kido.layout-editor", qos: .utility)
    let perform: @Sendable (KoSchema.Edit) throws -> KoSchema.Edited
    private var state = State.idle
    private(set) var expected: Int?
    private var seen = 0
    var onFailure: (KoSchema.Edit, String) -> Void = { _, _ in }
    var onSettled: () -> Void = {}

    // `perform` sends one edit and returns the layout that the server made of it, and what it made.
    init(perform: @escaping @Sendable (KoSchema.Edit) throws -> KoSchema.Edited) {
        self.perform = perform
    }

    var holding: Bool {
        if case .sending = state { return true }
        return expected != nil
    }

    // `then` runs on main with the edit's result; a keyed edit that a successor replaced has none.
    func submit(_ edit: KoSchema.Edit, key: Key? = nil, then: Done? = nil) {
        guard case .sending(let currentEdit, let current, var waiting) = state else { return start((edit, key, then)) }
        if let key, let index = waiting.firstIndex(where: { $0.key == key }) { waiting[index] = (edit, key, then) }
        else { waiting.append((edit, key, then)) }
        state = .sending(edit: currentEdit, then: current, waiting: waiting)
    }

    func layoutChanged(revision: Int) {
        seen = revision
        if expected != nil { settle() }
    }

    private func start(_ next: Waiting, waiting: [Waiting] = []) {
        state = .sending(edit: next.edit, then: next.then, waiting: waiting)
        let perform = perform, edit = next.edit
        queue.async { [weak self] in
            let result = Result { try perform(edit) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(result) } }
        }
    }

    private func finished(_ result: Result<KoSchema.Edited, Error>) {
        guard case .sending(let edit, let then, var waiting) = state else { return }
        switch result {
        case .success(let edited): expected = max(expected ?? 0, edited.snapshot.revision)
        case .failure(let error): if then == nil { onFailure(edit, failureText(error)) }
        }
        if case .sending(_, _, let queued) = state { waiting = queued }
        if waiting.isEmpty { state = .idle } else { start(waiting.removeFirst(), waiting: waiting) }
        then?(result)
        settle()
    }

    private func settle() {
        guard case .idle = state, expected.map({ seen >= $0 }) ?? true else { return }
        expected = nil
        onSettled()
    }
}

// The edits of the pane commands.
enum PaneAction: Equatable {
    case edit(KoSchema.Edit)
    case select(PaneID)
}

// The pane that a gesture's edit selects: a split selects the pane it made, a zoom the pane it zooms.
func selectedPane(by edit: KoSchema.Edit, _ edited: KoSchema.Edited) -> PaneID? {
    switch (edit, edited.created) {
    case (.split, .pane(let created)?): created.pane
    case (.toggleZoom(let toggle), _): edited.snapshot.layout.windows.contains { $0.zoom == toggle.pane } ? toggle.pane : nil
    default: nil
    }
}

extension Side {
    var edge: KoSchema.Edge {
        switch self {
        case .left: .left
        case .up: .top
        case .right: .right
        case .down: .bottom
        }
    }
}

// Where a new pane runs: the runtime of the pane that it is made from, the host, or a named runtime.
enum NewPaneRuntime: Equatable {
    case inherit, host, named(String)
}

extension KoModel {
    func newPane(from pane: PaneID?, _ choice: NewPaneRuntime = .inherit) -> KoSchema.CreatePane {
        let source = pane.flatMap(self.pane)
        let runtime: String? = switch choice {
        case .inherit: source?.runtime
        case .host: nil
        case .named(let name): name
        }
        return KoSchema.CreatePane(cwd: source.map { .pane(.init(pane: $0.id)) }, runtime: runtime)
    }
}

extension PaneCommand {
    // The layout action of a command on `pane` of `window`; nil for the commands of the owner and
    // for a select with no pane on that side. Ghostty's resize amount is in points.
    func action(_ pane: PaneID, in window: KoSchema.Window, new: KoSchema.CreatePane, cell: CGSize) -> PaneAction? {
        let panes = Layout(window, visible: true).root.panes
        switch self {
        case .split(let side):
            return .edit(.split(KoSchema.EditSplit(axis: side == .left || side == .right ? .h : .v, before: side == .left || side == .up,
                                                   new: new, pane: pane)))
        case .select(let side):
            guard let from = panes.first(where: { $0.id == pane })?.geometry else { return nil }
            func overlap(_ a: Int, _ al: Int, _ b: Int, _ bl: Int) -> Bool { a < b + bl && b < a + al }
            let candidates = panes.filter { $0.layer == .tiled && $0.id != pane }.compactMap { other -> (Int, PaneID)? in
                let g = other.geometry
                let distance: Int? = switch side {
                case .left where overlap(g.y, g.height, from.y, from.height): g.x + g.width <= from.x ? from.x - g.x - g.width : nil
                case .right where overlap(g.y, g.height, from.y, from.height): g.x >= from.x + from.width ? g.x - from.x - from.width : nil
                case .up where overlap(g.x, g.width, from.x, from.width): g.y + g.height <= from.y ? from.y - g.y - g.height : nil
                case .down where overlap(g.x, g.width, from.x, from.width): g.y >= from.y + from.height ? g.y - from.y - from.height : nil
                default: nil
                }
                return distance.map { ($0, other.id) }
            }
            return candidates.min { $0.0 < $1.0 }.map { .select($0.1) }
        case .resize(let side, let points):
            let horizontal = side == .left || side == .right
            let cells = max(1, Int((points / max(horizontal ? cell.width : cell.height, 1)).rounded()))
            return .edit(.resizeBy(KoSchema.EditResizeBy(delta: cells, edge: side.edge, pane: pane)))
        case .next, .previous:
            guard let at = panes.firstIndex(where: { $0.id == pane }), panes.count > 1 else { return nil }
            let step = if case .next = self { 1 } else { panes.count - 1 }
            return .select(panes[(at + step) % panes.count].id)
        case .zoom: return .edit(.toggleZoom(KoSchema.EditToggleZoom(pane: pane)))
        case .equalize: return .edit(.equalize(KoSchema.EditEqualize(pane: pane)))
        case .window, .newWindow, .close, .parent, .child: return nil
        }
    }
}

// The edits that make sessions and windows, in the directory of the pane that the user works in.
extension KoModel {
    func newSession(_ name: String) -> KoSchema.Edit {
        let cwd: KoSchema.Cwd? = current.flatMap { pane($0.window.focus) }.map { .pane(.init(pane: $0.id)) }
        return .addSession(KoSchema.EditAddSession(name: name, new: KoSchema.CreatePane(cwd: cwd)))
    }

    // After `window` of the session, else after its last window.
    func newWindow(in id: SessionID, after window: WindowID?, _ choice: NewPaneRuntime = .inherit, from pane: PaneID? = nil) -> KoSchema.Edit? {
        guard let session = layout.layout.session(id),
              let current = session.windows.first(where: { $0.id == window }) ?? session.windows.last else { return nil }
        return .addWindow(KoSchema.EditAddWindow(after: current.id, new: newPane(from: pane ?? source(in: current), choice), session: session.id))
    }
}

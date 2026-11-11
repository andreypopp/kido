import Foundation
import KoModel

public struct Layout: Equatable, Sendable {
    public let root: Node
}

// The floats of a child window that a tiled slot of this window shows in place of its own pane.
public struct ChildFloats: Equatable, Sendable {
    public let slot: PaneID
    public let floats: [KoSchema.Float]
    public init(slot: PaneID, floats: [KoSchema.Float]) { self.slot = slot; self.floats = floats }
}

extension Layout {
    // Siblings of a split are separated by one divider cell. The floats follow the tiled panes in the root split.
    // With `visible`, a zoomed pane alone fills the window and is its active pane. Otherwise `active` is the pane
    // of the client's selection, else the window's focus.
    public init(_ window: KoSchema.Window, visible: Bool = false, active: PaneID? = nil, children: [ChildFloats] = []) {
        let active = (visible ? window.zoom : nil) ?? active ?? window.focus
        var index = 0
        func pane(_ id: PaneID, _ geometry: Geometry, _ layer: Layer) -> Node {
            defer { index += 1 }
            return .pane(Pane(id: id, index: index, geometry: geometry, active: id == active, layer: layer))
        }
        let whole = Geometry(x: 0, y: 0, width: window.cols, height: window.rows)
        var stacked = window.floats.count
        // A child's float lies in the child's window; it is drawn over its slot and confined to it.
        func overlays(_ slots: [PaneID: Geometry]) -> [Node] {
            children.flatMap { child -> [Node] in
                guard let slot = slots[child.slot] else { return [] }
                return child.floats.sorted { $0.z < $1.z }.map { float in
                    let width = min(float.cols, slot.width), height = min(float.rows, slot.height)
                    let geometry = Geometry(
                        x: slot.x + min(max(0, float.x), slot.width - width), y: slot.y + min(max(0, float.y), slot.height - height),
                        width: width, height: height)
                    defer { stacked += 1 }
                    return pane(float.pane, geometry, .floating(z: stacked, source: .child(clip: slot, z: float.z, count: child.floats.count)))
                }
            }
        }
        if visible, let zoom = window.zoom {
            let zoomed = pane(zoom, whole, .tiled)
            let extra = overlays([zoom: whole])
            root = extra.isEmpty ? zoomed : .split(.leftRight, whole, [zoomed] + extra)
            return
        }
        func walk(_ node: KoSchema.LeafNode, _ x: Int, _ y: Int) -> Node {
            switch node {
            case .leaf(let leaf): return pane(leaf.pane, Geometry(x: x, y: y, width: leaf.cols, height: leaf.rows), .tiled)
            case .split(let split):
                let direction: Direction = split.split == .h ? .leftRight : .topBottom
                var offset = 0
                var children: [Node] = []
                for child in split.children {
                    let node = walk(child, direction == .leftRight ? x + offset : x, direction == .leftRight ? y : y + offset)
                    children.append(node)
                    offset += (direction == .leftRight ? node.geometry.width : node.geometry.height) + 1
                }
                let sizes = children.map(\.geometry)
                return .split(direction, Geometry(
                    x: x, y: y,
                    width: direction == .leftRight ? offset - 1 : sizes.map(\.width).max() ?? 0,
                    height: direction == .topBottom ? offset - 1 : sizes.map(\.height).max() ?? 0), children)
            }
        }
        let tiled = walk(window.tree, 0, 0)
        let floats = window.floats.sorted { $0.z < $1.z }.map {
            pane($0.pane, Geometry(x: $0.x, y: $0.y, width: $0.cols, height: $0.rows), .floating(z: $0.z, source: .window))
        }
        let slots = Dictionary(tiled.panes.map { ($0.id, $0.geometry) }) { first, _ in first }
        let drawn = floats + overlays(slots)
        switch tiled {
        case .split(let direction, let geometry, let siblings): root = .split(direction, geometry, siblings + drawn)
        case .pane: root = drawn.isEmpty ? tiled : .split(.leftRight, whole, [tiled] + drawn)
        }
    }
}

public struct Geometry: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
}

public enum Direction: Sendable {
    case leftRight
    case topBottom
}

// A float lies in the window itself, or in a child window whose pane the slot `clip` of this window shows. `z` and
// `count` of a child float are its z and the float count in the child window, which is where edits of it go.
public enum Layer: Equatable, Sendable {
    case tiled
    case floating(z: Int, source: Source)

    public enum Source: Equatable, Sendable {
        case window
        case child(clip: Geometry, z: Int, count: Int)
    }

    public var clip: Geometry? {
        if case .floating(_, .child(let clip, _, _)) = self { clip } else { nil }
    }
}

extension Layer: CustomStringConvertible {
    public var description: String {
        switch self {
        case .tiled: "tiled"
        case .floating(let z, .window): "floating(z: \(z))"
        case .floating(let z, .child(let clip, let source, let count)): "floating(z: \(z), in: \(clip), source: \(source)/\(count))"
        }
    }
}

public struct Pane: Equatable, Sendable {
    public let id: PaneID
    public let index: Int
    public let geometry: Geometry
    public let active: Bool
    public let layer: Layer
}

public indirect enum Node: Equatable, Sendable {
    case pane(Pane)
    case split(Direction, Geometry, [Node])
}

extension Node {
    public var geometry: Geometry {
        switch self {
        case .pane(let pane): pane.geometry
        case .split(_, let geometry, _): geometry
        }
    }

    public var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let children): children.flatMap(\.panes)
        }
    }

    public var dividers: [Divider] {
        guard case .split(let direction, let g, let children) = self else { return [] }
        let tiled = children.filter { if case .pane(let p) = $0, case .floating = p.layer { false } else { true } }
        let between = zip(tiled, tiled.dropFirst()).compactMap { a, b -> Divider? in
            guard let first = a.panes.first?.id, let second = b.panes.first?.id else { return nil }
            let a = a.geometry
            return switch direction {
            case .leftRight:
                Divider(geometry: Geometry(x: a.x + a.width, y: g.y, width: 1, height: g.height),
                        direction: direction, start: a.x, first: first, second: second)
            case .topBottom:
                Divider(geometry: Geometry(x: g.x, y: a.y + a.height, width: g.width, height: 1),
                        direction: direction, start: a.y, first: first, second: second)
            }
        }
        return between + children.flatMap(\.dividers)
    }
}

public struct Divider: Equatable, Sendable {
    public let geometry: Geometry
    public let direction: Direction
    let start: Int
    public let first: PaneID
    let second: PaneID

    public func resize(to position: Int) -> KoSchema.Edit? {
        guard position > start else { return nil }
        return .resizePair(KoSchema.EditResizePair(first: first, firstSize: position - start, second: second))
    }
}

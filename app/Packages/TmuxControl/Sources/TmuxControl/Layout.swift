import Foundation

public struct Layout: Decodable, Equatable, Sendable {
    public let root: Node
}

extension Layout {
    public init(json: some StringProtocol) throws {
        self = try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
    }

    private enum CodingKeys: String, CodingKey { case version = "V", root = "L" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c, debugDescription: "unsupported layout version \(version)")
        }
        root = try c.decode(Node.self, forKey: .root)
    }
}

public struct Geometry: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
}

public enum Direction: String, Sendable {
    case leftRight = "h"
    case topBottom = "v"
}

public enum Focus: Equatable, Sendable {
    case active
    case visited(Int)
    case unvisited
}

public enum Layer: Equatable, Sendable {
    case tiled
    case floating(z: Int)
}

public struct Pane: Equatable, Sendable {
    public let id: PaneID
    public let index: Int
    public let geometry: Geometry
    public let focus: Focus
    public let layer: Layer
}

public indirect enum Node: Decodable, Equatable, Sendable {
    case pane(Pane)
    case split(Direction, Geometry, [Node])

    enum CodingKeys: String, CodingKey {
        case type = "t", width = "w", height = "h", x, y
        case children = "c", active = "a", last = "l", index = "i", z, id = "I"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let geometry = Geometry(
            x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y),
            width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height))
        let type = try c.decode(String.self, forKey: .type)
        if let direction = Direction(rawValue: type) {
            self = .split(direction, geometry, try c.decode([Node].self, forKey: .children))
            return
        }
        guard type == "p" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown cell type \(type)")
        }
        let id = try c.decode(PaneID.self, forKey: .id)
        let focus: Focus =
            if try c.decodeIfPresent(Bool.self, forKey: .active) == true { .active }
            else if let last = try c.decodeIfPresent(Int.self, forKey: .last) { .visited(last) }
            else { .unvisited }
        self = .pane(Pane(
            id: id, index: try c.decode(Int.self, forKey: .index), geometry: geometry, focus: focus,
            layer: try c.decodeIfPresent(Int.self, forKey: .z).map { .floating(z: $0) } ?? .tiled))
    }
}

extension Node {
    public var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(_, _, let children): children.flatMap(\.panes)
        }
    }

    public var dividers: [Divider] {
        guard case .split(let direction, let g, let children) = self else { return [] }
        let tiled = children.filter { if case .pane(let p) = $0, case .floating = p.layer { false } else { true } }
        let between = tiled.dropLast().map { a in
            let anchor = a.anchor(direction)
            let a = switch a {
            case .pane(let pane): pane.geometry
            case .split(_, let geometry, _): geometry
            }
            return switch direction {
            case .leftRight:
                Divider(geometry: Geometry(x: a.x + a.width, y: g.y, width: 1, height: g.height),
                        direction: direction, start: a.x, anchor: anchor)
            case .topBottom:
                Divider(geometry: Geometry(x: g.x, y: a.y + a.height, width: g.width, height: 1),
                        direction: direction, start: a.y, anchor: anchor)
            }
        }
        return between + children.flatMap(\.dividers)
    }

    // tmux resizes a pane along the nearest enclosing split of that direction.
    private func anchor(_ direction: Direction) -> PaneID? {
        switch self {
        case .pane(let pane): if case .tiled = pane.layer { pane.id } else { nil }
        case .split(let d, _, let children): d == direction ? nil : children.lazy.compactMap { $0.anchor(direction) }.first
        }
    }
}

public struct Divider: Equatable, Sendable {
    public let geometry: Geometry
    public let direction: Direction
    let start: Int
    let anchor: PaneID?

    public func resize(to position: Int) -> Command? {
        guard let anchor, position > start else { return nil }
        return Command("resize-pane", "-t", anchor, direction == .leftRight ? "-x" : "-y", position - start)
    }
}

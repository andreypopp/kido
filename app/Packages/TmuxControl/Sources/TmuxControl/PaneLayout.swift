import Foundation
import CoreGraphics

public struct PaneLayout: Equatable {
    public enum ResizeEdge {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
        public var left: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        public var right: Bool { self == .right || self == .topRight || self == .bottomRight }
        public var top: Bool { self == .top || self == .topLeft || self == .topRight }
        public var bottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }
    public struct TiledPlacement: Equatable {
        public let grid: CGRect
        public let chrome: CGRect
    }
    private struct Card: Equatable {
        let grid: CGRect
        let chrome: CGRect
    }
    public let client: CGSize
    public let before: CGSize
    public let after: CGSize
    public let origin: CGPoint
    private let cell: CGSize
    private let bottom: CGFloat
    public let top: CGFloat
    private let cards: [Geometry: Card]
    private let gutters: [Geometry: CGRect]

    public static func == (a: PaneLayout, b: PaneLayout) -> Bool {
        a.client == b.client && a.before == b.before && a.after == b.after && a.origin == b.origin
            && a.cell == b.cell && a.bottom == b.bottom && a.top == b.top
    }

    public init(root: Node, shape: Node? = nil, bounds: CGRect, cell: CGSize, pixel: CGFloat, spacing: CGFloat) {
        self.cell = cell
        before = CGSize(width: floor((cell.width / pixel - 1) / 2) * pixel,
                        height: floor((cell.height / pixel - 1) / 2) * pixel)
        after = CGSize(width: cell.width - pixel - before.width, height: cell.height - pixel - before.height)
        top = ceil(bounds.minY / pixel) * pixel
        let g = root.geometry
        let extra = CGSize(width: max(0, ceil((3 * spacing - cell.width) / pixel) * pixel),
                           height: max(0, ceil((2 * spacing - cell.height) / pixel) * pixel))
        let pad = CGSize(width: (cell.width + extra.width - spacing) / 2, height: (cell.height + extra.height - spacing) / 2)
        let inner = CGRect(x: bounds.minX + spacing + pad.width, y: top + spacing + pad.height,
                           width: max(0, bounds.width - 2 * (spacing + pad.width)),
                           height: max(0, bounds.maxY - top - 2 * (spacing + pad.height)))
        let shape = shape ?? root
        client = CGSize(width: max(1, floor((inner.width - CGFloat(shape.across(.leftRight)) * extra.width) / cell.width)),
                        height: max(1, floor((inner.height - CGFloat(shape.across(.topBottom)) * extra.height) / cell.height)))
        let area = inner
        bottom = area.maxY
        origin = CGPoint(x: area.minX - CGFloat(g.x) * cell.width, y: bottom - CGFloat(g.y + g.height) * cell.height)
        var cards: [Geometry: Card] = [:], gutters: [Geometry: CGRect] = [:]
        func place(_ node: Node, _ area: CGRect) {
            switch node {
            case .pane(let pane):
                guard case .tiled = pane.layer else { return }
                let size = CGSize(width: CGFloat(pane.geometry.width) * cell.width, height: CGFloat(pane.geometry.height) * cell.height)
                let grid = CGRect(origin: CGPoint(x: floor((area.midX - size.width / 2) / pixel) * pixel,
                                                  y: floor((area.midY - size.height / 2) / pixel) * pixel), size: size)
                cards[pane.geometry] = Card(grid: grid, chrome: area.insetBy(dx: -pad.width, dy: -pad.height))
            case .split(let direction, let g, let children):
                let tiled = children.filter(\.tiled)
                let across = direction == .leftRight
                var at = across ? area.minX : area.minY
                for (index, child) in tiled.enumerated() {
                    let c = child.geometry
                    let last = index == tiled.count - 1
                    let end = last ? (across ? area.maxX : area.maxY) : at + (across
                        ? CGFloat(c.width) * cell.width + CGFloat(child.across(direction)) * extra.width
                        : CGFloat(c.height) * cell.height + CGFloat(child.across(direction)) * extra.height)
                    place(child, across ? CGRect(x: at, y: area.minY, width: end - at, height: area.height)
                                        : CGRect(x: area.minX, y: at, width: area.width, height: end - at))
                    if last { break }
                    let step = across ? cell.width + extra.width : cell.height + extra.height
                    if across {
                        gutters[Geometry(x: c.x + c.width, y: g.y, width: 1, height: g.height)] =
                            CGRect(x: end + pad.width, y: area.minY - pad.height, width: spacing, height: area.height + 2 * pad.height)
                    } else {
                        gutters[Geometry(x: g.x, y: c.y + c.height, width: g.width, height: 1)] =
                            CGRect(x: area.minX - pad.width, y: end + pad.height, width: area.width + 2 * pad.width, height: spacing)
                    }
                    at = end + step
                }
            }
        }
        place(root, area)
        self.cards = cards
        self.gutters = gutters
    }

    public func grid(_ g: Geometry) -> CGRect {
        CGRect(x: origin.x + CGFloat(g.x) * cell.width, y: origin.y + CGFloat(g.y) * cell.height,
               width: CGFloat(g.width) * cell.width, height: CGFloat(g.height) * cell.height)
    }

    public func frame(_ g: Geometry) -> CGRect {
        let grid = grid(g)
        return CGRect(x: grid.minX - before.width, y: grid.minY - before.height,
                      width: grid.width + before.width + after.width, height: grid.height + before.height + after.height)
    }

    public func tiled(_ g: Geometry) -> TiledPlacement {
        let card = cards[g] ?? Card(grid: grid(g), chrome: frame(g))
        return TiledPlacement(grid: card.grid, chrome: card.chrome)
    }

    public func geometry(_ frame: CGRect) -> Geometry {
        Geometry(x: Int(((frame.minX + before.width - origin.x) / cell.width).rounded()),
                 y: Int(((frame.minY + before.height - origin.y) / cell.height).rounded()),
                 width: max(2, Int(((frame.width - before.width - after.width) / cell.width).rounded())),
                 height: max(2, Int(((frame.height - before.height - after.height) / cell.height).rounded())))
    }

    public var floatingBounds: CGRect {
        CGRect(x: origin.x - before.width, y: top,
               width: client.width * cell.width + before.width + after.width,
               height: max(0, bottom - top))
    }

    public func clamp(_ frame: CGRect, resizing edge: ResizeEdge? = nil) -> CGRect {
        let area = floatingBounds
        var r = frame
        if let edge {
            if edge.left { let x = max(area.minX, r.minX); r.size.width = r.maxX - x; r.origin.x = x }
            if edge.right { r.size.width = min(r.maxX, area.maxX) - r.minX }
            if edge.top { let y = max(area.minY, r.minY); r.size.height = r.maxY - y; r.origin.y = y }
            if edge.bottom { r.size.height = min(r.maxY, area.maxY) - r.minY }
        } else {
            r.size.width = min(r.width, area.width)
            r.size.height = min(r.height, area.height)
            r.origin.x = min(max(area.minX, r.minX), area.maxX - r.width)
            r.origin.y = min(max(area.minY, r.minY), area.maxY - r.height)
        }
        return r
    }

    public func line(_ divider: Divider) -> CGRect {
        gutters[divider.geometry] ?? .zero
    }
}

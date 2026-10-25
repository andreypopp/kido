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
    public struct RenderInsets: Equatable, Sendable {
        public var top: CGFloat = 0
        public var bottom: CGFloat = 0
        public init(top: CGFloat = 0, bottom: CGFloat = 0) { self.top = top; self.bottom = bottom }
    }
    public struct TiledPlacement: Equatable {
        public let grid: CGRect
        public let content: CGRect
        public let chrome: CGRect
        public let insets: RenderInsets
    }
    private struct Card: Equatable {
        let grid: CGRect
        let chrome: CGRect
    }
    public static let minimumMargin = CGSize(width: 4, height: 12)
    public let client: CGSize
    public let before: CGSize
    public let after: CGSize
    public let origin: CGPoint
    public let rightEdge: CGFloat
    private let cell: CGSize
    private let bounds: CGRect
    private let bottom: CGFloat
    public let topLine: CGRect
    private let rootTop: Int
    private let spaced: Bool
    private let cards: [Geometry: Card]
    private let gutters: [Geometry: CGRect]

    public static func == (a: PaneLayout, b: PaneLayout) -> Bool {
        a.client == b.client && a.before == b.before && a.after == b.after && a.origin == b.origin
            && a.rightEdge == b.rightEdge && a.cell == b.cell && a.bounds == b.bounds && a.bottom == b.bottom
            && a.topLine == b.topLine && a.rootTop == b.rootTop && a.spaced == b.spaced
    }

    public init(root: Node, shape: Node? = nil, bounds: CGRect, cell: CGSize, pixel: CGFloat, spacing: CGFloat = 0) {
        self.cell = cell
        self.bounds = bounds
        before = CGSize(width: floor((cell.width / pixel - 1) / 2) * pixel,
                        height: floor((cell.height / pixel - 1) / 2) * pixel)
        after = CGSize(width: cell.width - pixel - before.width, height: cell.height - pixel - before.height)
        topLine = CGRect(x: bounds.minX, y: ceil(bounds.minY / pixel) * pixel, width: bounds.width, height: pixel)
        let g = root.geometry
        rootTop = g.y
        spaced = spacing > 0
        guard spacing > 0 else {
            bottom = floor((bounds.maxY - Self.minimumMargin.height) / pixel) * pixel
            client = CGSize(width: max(1, floor((bounds.width - 2 * Self.minimumMargin.width - cell.width + pixel) / cell.width)),
                            height: max(1, floor((bottom - topLine.maxY) / cell.height)))
            origin = CGPoint(
                x: bounds.minX + floor((bounds.width - CGFloat(g.width) * cell.width - before.width - after.width) / (2 * pixel)) * pixel + before.width,
                y: bottom - CGFloat(g.y + g.height) * cell.height)
            rightEdge = origin.x + CGFloat(g.x + g.width) * cell.width
            cards = [:]
            gutters = [:]
            return
        }
        let extra = CGSize(width: max(0, ceil((3 * spacing - cell.width) / pixel) * pixel),
                           height: max(0, ceil((2 * spacing - cell.height) / pixel) * pixel))
        let pad = CGSize(width: (cell.width + extra.width - spacing) / 2, height: (cell.height + extra.height - spacing) / 2)
        let inner = CGRect(x: bounds.minX + spacing + pad.width, y: topLine.maxY + spacing + pad.height,
                           width: max(0, bounds.width - 2 * (spacing + pad.width)),
                           height: max(0, bounds.maxY - topLine.maxY - 2 * (spacing + pad.height)))
        let shape = shape ?? root
        bottom = floor(inner.maxY / pixel) * pixel
        client = CGSize(width: max(1, floor((inner.width - CGFloat(shape.across(.leftRight)) * extra.width) / cell.width)),
                        height: max(1, floor((inner.height - CGFloat(shape.across(.topBottom)) * extra.height) / cell.height)))
        let size = CGSize(width: CGFloat(g.width) * cell.width + CGFloat(root.across(.leftRight)) * extra.width,
                          height: CGFloat(g.height) * cell.height + CGFloat(root.across(.topBottom)) * extra.height)
        let area = CGRect(x: floor((inner.midX - size.width / 2) / pixel) * pixel, y: bottom - size.height, width: size.width, height: size.height)
        origin = CGPoint(x: area.minX - CGFloat(g.x) * cell.width, y: bottom - CGFloat(g.y + g.height) * cell.height)
        rightEdge = origin.x + CGFloat(g.x + g.width) * cell.width
        var cards: [Geometry: Card] = [:], gutters: [Geometry: CGRect] = [:]
        func place(_ node: Node, _ area: CGRect) {
            switch node {
            case .pane(let pane):
                guard case .tiled = pane.layer else { return }
                let size = CGSize(width: CGFloat(pane.geometry.width) * cell.width, height: CGFloat(pane.geometry.height) * cell.height)
                let grid = CGRect(origin: CGPoint(x: floor(area.minX / pixel) * pixel, y: floor((area.maxY - size.height) / pixel) * pixel), size: size)
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

    public func tiled(_ g: Geometry, alternate: Bool) -> TiledPlacement {
        if spaced {
            let card = cards[g] ?? Card(grid: grid(g), chrome: frame(g))
            return TiledPlacement(grid: card.grid, content: card.grid, chrome: card.chrome, insets: RenderInsets())
        }
        let grid = grid(g)
        var chrome = frame(g)
        let left = g.x == 0 ? bounds.minX : chrome.minX
        let right = grid.maxX == rightEdge ? bounds.maxX : chrome.maxX
        chrome.origin.x = left
        chrome.size.width = right - left
        chrome.origin.y = max(topLine.maxY, g.y == rootTop ? topLine.maxY : chrome.minY)
        chrome.size.height = (grid.maxY == bottom ? bounds.maxY : min(grid.maxY + after.height, bounds.maxY)) - chrome.minY
        chrome = clip(chrome)
        let insets = alternate ? RenderInsets() : RenderInsets(
            top: max(0, grid.minY - chrome.minY),
            bottom: grid.maxY == bottom ? bounds.maxY - grid.maxY : after.height)
        let content = CGRect(x: grid.minX, y: grid.minY - insets.top, width: grid.width, height: grid.height + insets.top + insets.bottom)
        return TiledPlacement(grid: grid, content: content, chrome: chrome, insets: insets)
    }

    public func geometry(_ frame: CGRect) -> Geometry {
        Geometry(x: Int(((frame.minX + before.width - origin.x) / cell.width).rounded()),
                 y: Int(((frame.minY + before.height - origin.y) / cell.height).rounded()),
                 width: max(2, Int(((frame.width - before.width - after.width) / cell.width).rounded())),
                 height: max(2, Int(((frame.height - before.height - after.height) / cell.height).rounded())))
    }

    public var floatingBounds: CGRect {
        CGRect(x: origin.x - before.width, y: topLine.maxY,
               width: client.width * cell.width + before.width + after.width,
               height: max(0, bottom - topLine.maxY))
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

    private func clip(_ rect: CGRect) -> CGRect {
        guard rect.size.width > 0, rect.size.height > 0 else { return .zero }
        let area = CGRect(x: bounds.minX, y: topLine.maxY, width: bounds.width, height: max(0, bounds.maxY - topLine.maxY))
        let clipped = rect.intersection(area)
        return clipped.isNull ? .zero : clipped
    }

    public func line(_ divider: Divider, pixel: CGFloat) -> CGRect {
        if spaced { return gutters[divider.geometry] ?? .zero }
        let rect = grid(divider.geometry)
        if divider.direction == .leftRight {
            let top = divider.geometry.y == rootTop ? topLine.maxY : rect.minY - before.height
            return clip(CGRect(x: rect.minX + after.width, y: top, width: pixel,
                               height: min(rect.maxY + after.height, bottom) - top))
        }
        return clip(CGRect(x: rect.minX - before.width, y: rect.minY + after.height, width: rect.width + before.width + after.width, height: pixel))
    }
}

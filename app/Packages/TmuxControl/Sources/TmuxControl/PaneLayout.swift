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
    public static let minimumMargin = CGSize(width: 4, height: 2)
    public static let topMargin: CGFloat = 40
    public let client: CGSize
    public let before: CGSize
    public let after: CGSize
    public let origin: CGPoint
    public let rightEdge: CGFloat
    public let historyStrip: CGFloat
    private let cell: CGSize
    private let bounds: CGRect
    private let bottom: CGFloat

    public init(root: Node, bounds: CGRect, cell: CGSize, pixel: CGFloat) {
        self.cell = cell
        self.bounds = bounds
        before = CGSize(width: floor((cell.width / pixel - 1) / 2) * pixel,
                        height: floor((cell.height / pixel - 1) / 2) * pixel)
        after = CGSize(width: cell.width - pixel - before.width, height: cell.height - pixel - before.height)
        let top = ceil(Self.topMargin / pixel) * pixel
        bottom = floor((bounds.maxY - Self.minimumMargin.height) / pixel) * pixel
        client = CGSize(width: max(1, floor((bounds.width - 2 * Self.minimumMargin.width - cell.width + pixel) / cell.width)),
                        height: max(1, floor((bounds.height - top - Self.minimumMargin.height) / cell.height)))
        let g: Geometry = switch root { case .pane(let p): p.geometry; case .split(_, let g, _): g }
        origin = CGPoint(
            x: bounds.minX + floor((bounds.width - CGFloat(g.width) * cell.width - before.width - after.width) / (2 * pixel)) * pixel + before.width,
            y: bottom - CGFloat(g.y + g.height) * cell.height)
        historyStrip = max(0, min(cell.height - pixel, origin.y - bounds.minY - top))
        rightEdge = origin.x + CGFloat(g.x + g.width) * cell.width
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

    public func geometry(_ frame: CGRect) -> Geometry {
        Geometry(x: Int(((frame.minX + before.width - origin.x) / cell.width).rounded()),
                 y: Int(((frame.minY + before.height - origin.y) / cell.height).rounded()),
                 width: max(2, Int(((frame.width - before.width - after.width) / cell.width).rounded())),
                 height: max(2, Int(((frame.height - before.height - after.height) / cell.height).rounded())))
    }

    public var floatingBounds: CGRect {
        CGRect(x: origin.x - before.width, y: origin.y - before.height,
               width: client.width * cell.width + before.width + after.width,
               height: max(0, bottom - origin.y + before.height))
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

    public func line(_ divider: Divider, pixel: CGFloat) -> CGRect {
        let rect = grid(divider.geometry)
        if divider.direction == .leftRight {
            let top = divider.geometry.y == 0
                ? max(bounds.minY + ceil(Self.topMargin / pixel) * pixel, rect.minY - historyStrip)
                : rect.minY - before.height
            return CGRect(x: rect.minX + after.width, y: top, width: pixel,
                          height: min(rect.maxY + after.height, bottom) - top)
        }
        return CGRect(x: rect.minX - before.width, y: rect.minY + after.height, width: rect.width + before.width + after.width, height: pixel)
    }
}

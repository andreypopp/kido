import Foundation
import CoreGraphics

public struct PaneLayout {
    public static let minimumMargin = CGSize(width: 8, height: 6)
    public static let topMargin: CGFloat = 44
    public let client: CGSize
    public let before: CGSize
    public let after: CGSize
    public let origin: CGPoint
    public let rightEdge: CGFloat
    private let cell: CGSize

    public init(root: Node, bounds: CGRect, cell: CGSize, pixel: CGFloat) {
        self.cell = cell
        before = CGSize(width: floor((cell.width / pixel - 1) / 2) * pixel,
                        height: floor((cell.height / pixel - 1) / 2) * pixel)
        after = CGSize(width: cell.width - pixel - before.width, height: cell.height - pixel - before.height)
        let top = ceil(Self.topMargin / pixel) * pixel
        client = CGSize(width: max(1, floor((bounds.width - 2 * Self.minimumMargin.width - cell.width + pixel) / cell.width)),
                        height: max(1, floor((bounds.height - top - Self.minimumMargin.height - after.height) / cell.height)))
        let g: Geometry = switch root { case .pane(let p): p.geometry; case .split(_, let g, _): g }
        origin = CGPoint(
            x: bounds.minX + floor((bounds.width - CGFloat(g.width) * cell.width - before.width - after.width) / (2 * pixel)) * pixel + before.width,
            y: bounds.minY + top)
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

    public func line(_ divider: Divider, pixel: CGFloat) -> CGRect {
        let rect = grid(divider.geometry)
        return divider.direction == .leftRight
            ? CGRect(x: rect.minX + after.width, y: rect.minY - before.height, width: pixel, height: rect.height + before.height + after.height)
            : CGRect(x: rect.minX - before.width, y: rect.minY + after.height, width: rect.width + before.width + after.width, height: pixel)
    }
}

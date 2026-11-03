import Foundation

final class SurfaceRef: Sendable {
    enum Owner: @unchecked Sendable {
        case pane(Unmanaged<PaneView>)
        case scrollback(Unmanaged<ScrollbackView>)
    }

    let owner: Owner

    init(_ owner: Owner) { self.owner = owner }

    nonisolated static func owner(_ userdata: UnsafeMutableRawPointer?) -> Owner {
        Unmanaged<SurfaceRef>.fromOpaque(userdata!)._withUnsafeGuaranteedRef { $0.owner }
    }

    nonisolated static func pane(_ userdata: UnsafeMutableRawPointer?) -> Unmanaged<PaneView> {
        guard case .pane(let view) = owner(userdata) else { preconditionFailure("a scrollback surface reached a pane callback") }
        return view
    }
}

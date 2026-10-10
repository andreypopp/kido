import AppKit
import QuartzCore
import GhosttyKit

@MainActor final class VsyncDriver: NSObject {
    private weak var view: NSView?
    private var surface: ghostty_surface_t?
    private var link: CADisplayLink?
    private var closed = false
    private var available = false

    #if KIDO_VISUAL
    private(set) var jobs = 0
    private(set) var creates = 0
    private(set) var ticks = 0
    var visualTick: ((Double, Double) -> Void)?
    var hasLink: Bool { link != nil }
    #endif

    init(view: NSView) { self.view = view }

    nonisolated static func request(_ userdata: UnsafeMutableRawPointer?) {
        let driver = Unmanaged<VsyncDriver>.fromOpaque(userdata!).takeUnretainedValue()
        DispatchQueue.main.async { driver.drain() }
    }

    func attach(_ surface: ghostty_surface_t) {
        precondition(!closed && self.surface == nil)
        self.surface = surface
        updateAvailability()
    }

    func updateAvailability() {
        guard !closed else { return }
        let window = view?.window
        let next = window?.screen != nil && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
            && view?.isHiddenOrHasHiddenAncestor == false
        if available != next {
            available = next
            if !next { invalidate() }
            if let surface { ghostty_surface_set_vsync_state(surface, next ? GHOSTTY_VSYNC_AVAILABLE : GHOSTTY_VSYNC_UNAVAILABLE) }
        }
        drain()
    }

    func drain() {
        guard !closed, let surface else { return }
        #if KIDO_VISUAL
        jobs += 1
        #endif
        let wanted = ghostty_surface_take_vsync_demand(surface)
        guard wanted && available, let view else { invalidate(); return }
        let link = self.link ?? view.displayLink(target: self, selector: #selector(tick))
        if let screen = view.window?.screen {
            let maximum = Float(screen.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        }
        if self.link == nil {
            self.link = link
            link.add(to: .main, forMode: .common)
            #if KIDO_VISUAL
            creates += 1
            #endif
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !closed, available, let surface else { return }
        #if KIDO_VISUAL
        ticks += 1
        visualTick?(link.timestamp, link.targetTimestamp)
        #endif
        ghostty_surface_vsync_tick(surface)
    }

    private func invalidate() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let surface { ghostty_surface_set_vsync_state(surface, GHOSTTY_VSYNC_CLOSED) }
        invalidate()
        surface = nil
    }
}

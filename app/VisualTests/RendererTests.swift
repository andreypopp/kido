import AppKit
import Darwin
import GhosttyKit
import IOSurface
import TmuxControl
import XCTest
@testable import Kido

@MainActor final class RendererTests: VisualTestCase {
    private var runtime: GhosttyRuntime!
    private var config: URL!
    private var board: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        config = URL(fileURLWithPath: "/tmp/kido-renderer-\(UUID().uuidString).conf")
        try "cursor-style-blink = false\ncustom-shader-animation = false\nwindow-vsync = true\n".write(to: config, atomically: true, encoding: .utf8)
        board = NSPasteboard(name: .init("kido-renderer-\(UUID().uuidString)"))
        runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        PaneView.renderOffscreen = true
    }

    override func tearDown() async throws {
        runtime = nil
        board?.releaseGlobally()
        PaneView.renderOffscreen = false
        try? FileManager.default.removeItem(at: config)
    }

    private func probe<F>(_ name: String, _ type: F.Type) throws -> F {
        unsafeBitCast(try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)), to: type)
    }

    private func makePane(windowed: Bool = false) throws -> (pane: PaneView, window: NSWindow?) {
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { _ in })
        let window = windowed ? NSWindow(contentRect: pane.bounds, styleMask: .borderless, backing: .buffered, defer: false) : nil
        window?.isReleasedWhenClosed = false
        window?.contentView = pane
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        return (pane, window)
    }

    private func drainAnimation(_ runtime: GhosttyRuntime) async throws {
        for _ in 0..<20 { ghostty_app_tick(runtime.app); try await Task.sleep(for: .milliseconds(10)) }
    }

    private func assertIdleCPU(_ ids: Set<UInt64>) async throws {
        let before = try rendererCPU(only: ids)
        try await Task.sleep(for: .seconds(3))
        let after = try rendererCPU(only: ids)
        XCTAssertEqual(after.count, before.count)
        XCTAssertLessThanOrEqual(after.cpu - before.cpu, 0.003, "no periodic renderer work (3ms CPU tolerance over 3s)")
    }

    private func rendererCPU(only ids: Set<UInt64>? = nil) throws -> (cpu: Double, count: Int) {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        XCTAssertEqual(task_threads(mach_task_self_, &list, &count), KERN_SUCCESS)
        let threads = try XCTUnwrap(list)
        defer {
            for i in 0..<Int(count) { _ = mach_port_deallocate(mach_task_self_, threads[i]) }
            _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        var renderers = 0
        for i in 0..<Int(count) {
            guard let pthread = pthread_from_mach_thread_np(threads[i]) else { continue }
            var name = [CChar](repeating: 0, count: 64)
            guard pthread_getname_np(pthread, &name, name.count) == 0,
                  name.withUnsafeBufferPointer({ String(cString: $0.baseAddress!) }) == "renderer" else { continue }
            if let ids {
                var identifier = thread_identifier_info_data_t()
                var identifierSize = mach_msg_type_number_t(MemoryLayout.size(ofValue: identifier) / MemoryLayout<integer_t>.size)
                let identified = withUnsafeMutablePointer(to: &identifier) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(identifierSize)) { thread_info(threads[i], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierSize) }
                }
                XCTAssertEqual(identified, KERN_SUCCESS)
                if !ids.contains(identifier.thread_id) { continue }
            }
            var info = thread_basic_info_data_t()
            var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size) }
            }
            XCTAssertEqual(status, KERN_SUCCESS)
            total += Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
            renderers += 1
        }
        return (total, renderers)
    }

    private func reload(_ text: String) throws {
        let changed = try XCTUnwrap(ghostty_config_clone(runtime.config))
        ghostty_config_load_string(changed, text, UInt(text.utf8.count), "/renderer-test")
        ghostty_config_finalize(changed)
        ghostty_app_update_config(runtime.app, changed)
        ghostty_config_free(changed)
    }

    private func flow(_ panes: [PaneView]) async throws {
        for step in 0..<12 {
            for pane in panes { XCTAssertTrue(pane.feed(Data("\u{1b}[?25lordinary output \(step)\r\n".utf8))) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testFailedSurfaceInitJoinsRendererAndReleasesAllocations() async throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var options = ghostty_surface_config_new()
        options.platform_tag = GHOSTTY_PLATFORM_MACOS
        options.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        options.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        var callbacks = ghostty_runtime_config_s()
        callbacks.wakeup_cb = { _ in }
        callbacks.action_cb = { _, _, _ in false }
        callbacks.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        callbacks.confirm_read_clipboard_cb = { _, _, _, _ in }
        callbacks.write_clipboard_cb = { _, _, _, _, _ in GHOSTTY_CLIPBOARD_WRITE_OK }
        let config = try XCTUnwrap(ghostty_config_clone(runtime.config))
        let initial = "cursor-style-blink = true\nfont-size = 6\n"
        ghostty_config_load_string(config, initial, UInt(initial.utf8.count), "/renderer-test")
        ghostty_config_finalize(config)
        defer { ghostty_config_free(config) }
        let app = try XCTUnwrap(ghostty_app_new(&callbacks, config))
        defer { ghostty_app_free(app) }
        var invalid = options
        invalid.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: nil))
        XCTAssertNil(ghostty_surface_new(app, &invalid))
        let fault = try probe("kido_io_spawn_fault", (@convention(c) (Bool) -> UInt).self)
        invalid.platform = options.platform
        invalid.scale_factor = 0.25
        let allocationBytes = try probe("kido_renderer_allocation_bytes", (@convention(c) (Bool) -> UInt).self)
        let resetAllocations = try probe("kido_renderer_allocation_reset", (@convention(c) () -> Void).self)
        let threadsBeforeFailure = try rendererCPU().count
        let failures = fault(true)
        let rejected = ghostty_surface_new(app, &invalid)
        XCTAssertEqual(fault(false), failures + 1, "IO spawn failed after a live named renderer was started")
        XCTAssertNil(rejected)
        XCTAssertEqual(try rendererCPU().count, threadsBeforeFailure, "failed constructor joins renderer before returning")
        if let rejected { ghostty_surface_free(rejected) }
        XCTAssertGreaterThan(allocationBytes(true), 65536, "renderer performed allocating initial work before IO spawn failed")
        try await wait("renderer allocations released after failed constructor") { allocationBytes(false) <= 65536 }
        XCTAssertLessThanOrEqual(allocationBytes(false), 65536, "largest initial renderer allocation freed (64KiB residual allowance)")
        print("renderer fault: largest allocation=\(allocationBytes(true)), residual=\(allocationBytes(false)) bytes")
        resetAllocations()
    }

    func testWindowDisplayIDReachesNativeLink() async throws {
        let binding = try probe("kido_cv_display_binding", (@convention(c) () -> UInt64).self)
        let before = binding() >> 32
        let (pane, window) = try makePane(windowed: true)
        defer { pane.dispose(); window?.contentView = nil; window?.close() }
        let id = try XCTUnwrap(window?.screen?.displayID)
        try await wait("the window display reaches CoreVideo") { binding() >> 32 > before && UInt32(truncatingIfNeeded: binding()) == id }
    }

    func testOutputAndHiddenDiscardRecovery() async throws {
        let rendererThread = try probe("kido_renderer_thread", (@convention(c) (Bool) -> UInt64).self)
        _ = rendererThread(true)
        let (pane, window) = try makePane(windowed: true)
        defer { pane.dispose(); window?.contentView = nil; window?.close() }
        try await drainAnimation(runtime)
        var frames = 0
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 }
        let renderer = rendererThread(false)
        XCTAssertNotEqual(renderer, 0)
        let activeCPU = try rendererCPU(only: [renderer])
        XCTAssertEqual(activeCPU.count, 1, "sampling this pane's renderer thread")
        try await flow([pane])
        try await drainAnimation(runtime)
        XCTAssertGreaterThan(frames, 0, "ordinary output installs IOSurfaces without token requests")
        XCTAssertGreaterThan(try rendererCPU(only: [renderer]).cpu - activeCPU.cpu, 0.003, "active renderer CPU exceeds idle tolerance")
        for enabled in [false, true] {
            try reload("window-vsync = \(enabled)\n")
            let before = frames
            try await flow([pane])
            try await drainAnimation(runtime)
            XCTAssertGreaterThan(frames, before)
        }
        pane.isHidden = true
        let discarded = expectation(description: "hidden final frame discarded")
        pane.visualFrame { XCTAssertEqual($0, GHOSTTY_RENDER_PRESENTATION_DISCARDED); discarded.fulfill() }
        await fulfillment(of: [discarded], timeout: 5)
        pane.isHidden = false
        let recovered = expectation(description: "realization recovery")
        pane.visualFrame { XCTAssertEqual($0, GHOSTTY_RENDER_PRESENTATION_PRESENTED); recovered.fulfill() }
        await fulfillment(of: [recovered], timeout: 5)
        observation.invalidate()
    }

    func testAnimatedShaderKeepsKittyDeadlines() async throws {
        let shader = config.appendingPathExtension("glsl")
        try "void mainImage(out vec4 color, in vec2 position) { color = vec4(texture(iChannel0, position / iResolution.xy).rgb * 0.9 + vec3(0.05 + 0.05 * sin(iTime)), 1.0); }".write(to: shader, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: shader) }
        try reload("custom-shader = \(shader.path)\ncustom-shader-animation = always\n")
        let (pane, _) = try makePane()
        defer { pane.dispose() }
        try await drainAnimation(runtime)
        let packets = ["a=T,i=1,f=24,s=1,v=1,c=8,r=4,q=2;/wAA", "a=f,i=1,f=24,s=1,v=1,z=400,q=2;AAD/", "a=a,i=1,r=1,z=400,s=3,v=1"]
        XCTAssertTrue(pane.feed(Data(("\u{1b}[?25l" + packets.map { "\u{1b}_G\($0)\u{1b}\\" }.joined()).utf8)))
        try await drainAnimation(runtime)
        var frames = 0
        var changes: [(time: Double, colour: Int)] = []
        let layer = try XCTUnwrap(pane.subviews.first?.layer)
        let observation = observeFrames(layer) {
            frames += 1
            let surface = unsafeBitCast(layer.contents! as AnyObject, to: IOSurfaceRef.self)
            XCTAssertEqual(IOSurfaceGetBytesPerElement(surface), 4)
            guard IOSurfaceLock(surface, .readOnly, nil) == 0 else { XCTFail("lock image contents"); return }
            defer { _ = IOSurfaceUnlock(surface, .readOnly, nil) }
            let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            var red = 0
            var blue = 0
            for y in stride(from: 0, to: IOSurfaceGetHeight(surface), by: 8) {
                for x in stride(from: 0, to: IOSurfaceGetWidth(surface), by: 8) {
                    let offset = y * IOSurfaceGetBytesPerRow(surface) + x * 4
                    if Int(bytes[offset + 2]) - Int(bytes[offset]) > 100 { red += 1 }
                    if Int(bytes[offset]) - Int(bytes[offset + 2]) > 100 { blue += 1 }
                }
            }
            if red + blue > 0 {
                let colour = red > blue ? 1 : -1
                if changes.last?.colour != colour { changes.append((CACurrentMediaTime(), colour)) }
            }
        }
        defer { observation.invalidate() }
        try await wait("animated shader retains Kitty changes") { changes.count >= 4 }
        XCTAssertGreaterThan(frames, 12, "shader continues drawing between sparse Kitty updates")
        for interval in zip(changes.dropFirst(2), changes.dropFirst()).map({ $0.0.time - $0.1.time }) {
            XCTAssertEqual(interval, 0.4, accuracy: 0.18)
        }
    }

    func testIdleFocusedPaneWithoutCursorBlinkDoesNotBlink() async throws {
        let (pane, _) = try makePane()
        defer { pane.dispose() }
        ghostty_surface_set_focus(pane.surface, true)
        XCTAssertTrue(pane.feed(Data("\u{1b}[?25hhonk\r\n".utf8)))
        try await drainAnimation(runtime)
        var frames = 0
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 }
        defer { observation.invalidate() }
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(frames, 0, "blink off installs no frame over two blink intervals")
    }

    func testScrollerBurstUsesOneFadeDeadlineAndFlipsTheKnob() async throws {
        let delay = PaneScroller.fadeDelay
        PaneScroller.fadeDelay = 0.05
        defer { PaneScroller.fadeDelay = delay }
        let scroller = PaneScroller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 12, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroller
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        scroller.update(history: 1000, rows: 40, offset: 1000, alternate: false)
        let bottom = try knobRows(scroller)
        XCTAssertNil(scroller.layer?.contents, "the knob layer needs no backing store")
        XCTAssertFalse(bottom.isEmpty, "the flipped scroller renders its knob")
        XCTAssertGreaterThan(bottom.min() ?? 0, 360, "the live bottom is at the bottom of the flipped view")
        scroller.update(history: 1000, rows: 40, offset: 0, alternate: false)
        let top = try knobRows(scroller)
        XCTAssertFalse(top.isEmpty)
        XCTAssertLessThan(top.max() ?? 400, 40, "the oldest history is at the top of the flipped view")
        for step in 0..<200 {
            scroller.update(history: 1000, rows: 40, offset: 100 + Double(step) / 10, alternate: false)
            scroller.reveal()
        }
        XCTAssertEqual(scroller.visualFadeArmings, 1, "a scroll burst arms one fade deadline, not one timer per event")
        let knob = try XCTUnwrap(scroller.layer?.sublayers?.first)
        XCTAssertEqual(knob.frame.origin.y, 47.0824, accuracy: 0.001, "the burst leaves the knob at the latest geometry")
        XCTAssertEqual(scroller.alphaValue, 1)
        try await wait("the fade starts after the burst") { scroller.alphaValue == 0 }
        scroller.reveal()
        XCTAssertEqual(scroller.alphaValue, 1, "a reveal during the fade restores the scroller")
        scroller.update(history: 1000, rows: 40, offset: 500, alternate: true)
        XCTAssertEqual(knob.frame.origin.y, 47.0824, accuracy: 0.001, "a hidden scroller does not commit its knob")
        scroller.update(history: 1000, rows: 40, offset: 500, alternate: false)
        XCTAssertEqual(knob.frame.origin.y, 190, accuracy: 0.001, "the shown scroller commits the current knob")
    }

    private func knobRows(_ scroller: PaneScroller) throws -> [Int] {
        let width = Int(scroller.bounds.width), height = Int(scroller.bounds.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if scroller.isFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        scroller.layer!.render(in: context)
        let image = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        return (0..<height).filter { y in
            (0..<width).contains { x in (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 }
        }
    }

    func testScrollbarActionSkipsRefreshWhileAppOwnsTarget() async throws {
        let (pane, _) = try makePane()
        defer { pane.dispose() }
        let output = (0..<300).map { "line \($0)\r\n" }.joined()
        XCTAssertTrue(pane.feed(Data(output.utf8)))
        try await drain(runtime)
        pane.requestScroll(10)
        try await wait("the app owns the scroll target") { pane.scrollTarget != nil }
        try await drain(runtime)
        let owned = pane.visualScrollerRefreshes
        try await scrollbar(pane)
        XCTAssertEqual(pane.visualScrollerRefreshes, owned,
                       "the app tick does not refresh a scroller whose target the app owns")
        pane.clearScrollTarget()
        XCTAssertNil(pane.scrollTarget)
        try await drain(runtime)
        let released = pane.visualScrollerRefreshes
        try await scrollbar(pane)
        XCTAssertGreaterThan(pane.visualScrollerRefreshes, released,
                             "the app tick still refreshes the scroller when the app owns no target")
    }

    private func scrollbar(_ pane: PaneView) async throws {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = pane.surface
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SCROLLBAR
        XCTAssertTrue(GhosttyRuntime.action(ghostty_surface_app(pane.surface)!, target, action))
        await mainQueueFence()
        await mainQueueFence()
    }

    func testThirtyTwoOffscreenSurfacesStayIdleAfterChurn() async throws {
        let rendererThread = try probe("kido_renderer_thread", (@convention(c) (Bool) -> UInt64).self)
        var fixtures: [(pane: PaneView, renderer: UInt64)] = []
        var frames = 0
        var observations: [NSKeyValueObservation] = []
        for index in 0..<40 {
            _ = rendererThread(true)
            let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: UInt32(index)), font: 13) { _ in })
            observations.append(observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 })
            pane.resize(cols: 20, rows: 5)
            XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
            XCTAssertTrue(pane.feed(Data("\u{1b}[?25lchurn \(index)\r\n".utf8)))
            fixtures.append((pane, rendererThread(false)))
            if fixtures.count > 32 { fixtures.removeFirst().pane.dispose() }
        }
        try await drainAnimation(runtime)
        var panes = fixtures.map(\.pane)
        let ids = Set(fixtures.map(\.renderer))
        XCTAssertEqual(ids.count, 32)
        XCTAssertFalse(ids.contains(0))
        let activeCPU = try rendererCPU(only: ids)
        XCTAssertEqual(activeCPU.count, panes.count)
        let activeFrames = frames
        try await flow(panes)
        try await drainAnimation(runtime)
        XCTAssertGreaterThan(frames, activeFrames)
        XCTAssertGreaterThan(try rendererCPU(only: ids).cpu - activeCPU.cpu, 0.003, "active renderer CPU exceeds idle tolerance")
        // Ghostty's compression delay is 250ms.
        try await Task.sleep(for: .milliseconds(500))
        let idleFrames = frames
        try await assertIdleCPU(ids)
        XCTAssertEqual(frames, idleFrames)
        observations.forEach { $0.invalidate() }
        for pane in panes { pane.dispose() }
        panes.removeAll()
        fixtures.removeAll()
        await mainQueueFence()
    }
}

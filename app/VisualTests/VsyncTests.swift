import AppKit
import Darwin
import GhosttyKit
import IOSurface
import TmuxControl
import XCTest
@testable import Kido

private final class VsyncGate: @unchecked Sendable {
    let context: UnsafeMutableRawPointer
    let armed = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private(set) var timedOut = false
    init(_ context: UnsafeMutableRawPointer) { self.context = context }
    func invoke() {
        if armed.wait(timeout: .now()) == .success {
            entered.signal()
            timedOut = release.wait(timeout: .now() + 5) == .timedOut
        }
        VsyncDriver.request(context)
    }
}

@MainActor final class VsyncTests: VisualTestCase {
    private var runtime: GhosttyRuntime!
    private var config: URL!
    private var board: NSPasteboard!

    override func setUp() async throws {
        try await super.setUp()
        config = URL(fileURLWithPath: "/tmp/kido-vsync-\(UUID().uuidString).conf")
        try "cursor-style-blink = false\ncustom-shader-animation = false\nwindow-vsync = true\n".write(to: config, atomically: true, encoding: .utf8)
        board = NSPasteboard(name: .init("kido-vsync-\(UUID().uuidString)"))
        runtime = try XCTUnwrap(GhosttyRuntime(configFile: config.path, pasteboard: board))
        PaneView.renderOffscreen = true
        XCTAssertEqual(try cvAllocations(), 0)
    }

    override func tearDown() async throws {
        runtime = nil
        board?.releaseGlobally()
        PaneView.renderOffscreen = false
        try? FileManager.default.removeItem(at: config)
        XCTAssertEqual(try cvAllocations(), 0)
    }

    private func cvAllocations() throws -> UInt {
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kido_cv_allocations"))
        return unsafeBitCast(symbol, to: (@convention(c) () -> UInt).self)()
    }

    private func mainQueueFence() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
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
        ghostty_config_load_string(changed, text, UInt(text.utf8.count), "/vsync-test")
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

    func testDemandBeforeAttachAndCloseBeforeQueuedApply() async throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var driver: VsyncDriver? = VsyncDriver(view: view)
        weak let weakDriver = driver
        let context = Unmanaged.passRetained(driver!)
        var options = ghostty_surface_config_new()
        options.platform_tag = GHOSTTY_PLATFORM_MACOS
        options.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        options.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
        let gate = VsyncGate(context.toOpaque())
        options.vsync_request_cb = { Unmanaged<VsyncGate>.fromOpaque($0!).takeUnretainedValue().invoke() }
        options.vsync_userdata = Unmanaged.passUnretained(gate).toOpaque()
        var callbacks = ghostty_runtime_config_s()
        callbacks.wakeup_cb = { _ in }
        callbacks.action_cb = { _, _, _ in false }
        callbacks.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        callbacks.confirm_read_clipboard_cb = { _, _, _, _ in }
        callbacks.write_clipboard_cb = { _, _, _, _, _ in }
        let config = try XCTUnwrap(ghostty_config_clone(runtime.config))
        let initial = "cursor-style-blink = true\nfont-size = 6\n"
        ghostty_config_load_string(config, initial, UInt(initial.utf8.count), "/vsync-test")
        ghostty_config_finalize(config)
        defer { ghostty_config_free(config) }
        let app = try XCTUnwrap(ghostty_app_new(&callbacks, config))
        defer { ghostty_app_free(app) }
        var failed: VsyncDriver? = VsyncDriver(view: view)
        weak let weakFailed = failed
        let failedContext = Unmanaged.passRetained(failed!)
        var invalid = options
        invalid.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: nil))
        invalid.vsync_request_cb = { VsyncDriver.request($0) }
        invalid.vsync_userdata = failedContext.toOpaque()
        XCTAssertNil(ghostty_surface_new(app, &invalid))
        let faultSymbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kido_io_spawn_fault"))
        let fault = unsafeBitCast(faultSymbol, to: (@convention(c) (Bool) -> UInt).self)
        invalid.platform = options.platform
        invalid.scale_factor = 0.25
        let allocationSymbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kido_renderer_allocation_bytes"))
        let allocationBytes = unsafeBitCast(allocationSymbol, to: (@convention(c) (Bool) -> UInt).self)
        let resetSymbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kido_renderer_allocation_reset"))
        let resetAllocations = unsafeBitCast(resetSymbol, to: (@convention(c) () -> Void).self)
        let threadsBeforeFailure = try rendererCPU().count
        let failures = fault(true)
        let rejected = ghostty_surface_new(app, &invalid)
        XCTAssertEqual(fault(false), failures + 1, "IO spawn failed after a live named renderer was started")
        XCTAssertNil(rejected)
        XCTAssertEqual(try rendererCPU().count, threadsBeforeFailure, "failed constructor joins renderer before returning")
        if let rejected { ghostty_surface_free(rejected) }
        failed!.close()
        failedContext.release()
        failed = nil
        await mainQueueFence()
        XCTAssertNil(weakFailed)
        XCTAssertGreaterThan(allocationBytes(true), 65536, "renderer performed allocating initial work before IO spawn failed")
        try await wait("renderer allocations released after failed constructor") { allocationBytes(false) <= 65536 }
        XCTAssertLessThanOrEqual(allocationBytes(false), 65536, "largest initial renderer allocation freed (64KiB residual allowance)")
        print("renderer fault: largest allocation=\(allocationBytes(true)), residual=\(allocationBytes(false)) bytes")
        resetAllocations()
        let surface = try XCTUnwrap(ghostty_surface_new(app, &options))
        ghostty_surface_set_focus(surface, false)
        let output = "pending before attach\r\n"
        ghostty_surface_process_output(surface, output, UInt(output.utf8.count))
        VsyncDriver.request(context.toOpaque())
        await mainQueueFence()
        try await wait("pre-attach renderer demand") { ghostty_surface_take_vsync_demand(surface) }
        XCTAssertEqual(driver?.jobs, 0, "early job must not consume before attach")
        XCTAssertTrue(ghostty_surface_take_vsync_demand(surface), "early job retains actual demand")
        driver!.attach(surface)
        XCTAssertGreaterThan(driver!.jobs, 0, "attach unconditionally replays demand")
        XCTAssertTrue(ghostty_surface_take_vsync_demand(surface), "attach preserves demanded work while unavailable")
        ghostty_surface_vsync_tick(surface)
        try await wait("replayed tick settles renderer demand") { !ghostty_surface_take_vsync_demand(surface) }
        XCTAssertFalse(ghostty_surface_take_vsync_demand(surface), "replayed tick reaches renderer and settles retained demand")
        XCTAssertFalse(driver!.hasLink, "unordered NSViews are not tick-capable")
        gate.armed.signal()
        ghostty_surface_set_focus(surface, true)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success, "real renderer callback entered")
        VsyncDriver.request(context.toOpaque())
        driver!.close()
        driver!.close()
        let jobs = driver!.jobs
        ghostty_surface_set_vsync_state(surface, GHOSTTY_VSYNC_AVAILABLE)
        XCTAssertFalse(ghostty_surface_take_vsync_demand(surface), "closed cannot reopen")
        gate.release.signal()
        let joinStart = Date()
        ghostty_surface_free(surface)
        XCTAssertLessThan(Date().timeIntervalSince(joinStart), 5)
        XCTAssertFalse(gate.timedOut)
        context.release()
        driver = nil
        await mainQueueFence()
        XCTAssertNil(weakDriver, "queued job cannot resurrect or retain driver after drain")
        XCTAssertGreaterThan(jobs, 0)
    }

    func testUnavailableOutputHiddenDiscardRecovery() async throws {
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { _ in })
        let window = NSWindow(contentRect: pane.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        try await drain(runtime)
        var frames = 0
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 }
        let activeCPU = try rendererCPU()
        XCTAssertGreaterThan(activeCPU.count, 0, "sampling actual named renderer threads")
        try await flow([pane])
        try await drain(runtime)
        XCTAssertGreaterThan(frames, 0, "ordinary unavailable output installs IOSurfaces without token requests")
        XCTAssertGreaterThan(try rendererCPU().cpu - activeCPU.cpu, 0.003, "active renderer CPU exceeds idle tolerance")
        for enabled in [false, true] {
            try reload("window-vsync = \(enabled)\n")
            let before = frames
            try await flow([pane])
            try await drain(runtime)
            XCTAssertGreaterThan(frames, before)
            if !enabled { XCTAssertFalse(ghostty_surface_take_vsync_demand(pane.surface)) }
            XCTAssertEqual(try cvAllocations(), 0)
        }
        pane.isHidden = true
        let discarded = expectation(description: "hidden final frame discarded")
        pane.visualFrame { XCTAssertFalse($0); discarded.fulfill() }
        await fulfillment(of: [discarded], timeout: 5)
        pane.isHidden = false
        let recovered = expectation(description: "realization recovery")
        pane.visualFrame { XCTAssertTrue($0); recovered.fulfill() }
        await fulfillment(of: [recovered], timeout: 5)
        observation.invalidate()
        XCTAssertEqual(try cvAllocations(), 0)
        pane.dispose()
        pane.dispose()
        window.contentView = nil
        window.close()
    }

    func testAnimatedShaderManualHostTicksAndFallback() async throws {
        let shader = config.appendingPathExtension("glsl")
        try "void mainImage(out vec4 color, in vec2 position) { color = vec4(texture(iChannel0, position / iResolution.xy).rgb * 0.9 + vec3(0.05 + 0.05 * sin(iTime)), 1.0); }".write(to: shader, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: shader) }
        try reload("custom-shader = \(shader.path)\ncustom-shader-animation = always\n")
        let threadSymbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kido_renderer_thread"))
        let rendererThread = unsafeBitCast(threadSymbol, to: (@convention(c) (Bool) -> UInt64).self)
        _ = rendererThread(true)
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { _ in })
        defer { pane.dispose() }
        ghostty_surface_set_vsync_state(pane.surface, GHOSTTY_VSYNC_AVAILABLE)
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        try await drain(runtime)
        let renderer = rendererThread(false)
        XCTAssertNotEqual(renderer, 0)
        XCTAssertEqual(try rendererCPU(only: [renderer]).count, 1)
        let packets = ["a=T,i=1,f=24,s=1,v=1,c=8,r=4,q=2;/wAA", "a=f,i=1,f=24,s=1,v=1,z=400,q=2;AAD/", "a=a,i=1,r=1,z=400,s=3,v=1"]
        XCTAssertTrue(pane.feed(Data(("\u{1b}[?25l" + packets.map { "\u{1b}_G\($0)\u{1b}\\" }.joined()).utf8)))
        try await drain(runtime)
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
        ghostty_surface_vsync_tick(pane.surface)
        try await wait("manual host shader draws") { frames > 0 }
        let initial = frames
        let ticks = 12
        for _ in 0..<ticks {
            ghostty_surface_vsync_tick(pane.surface)
            try await Task.sleep(for: .milliseconds(100))
        }
        await mainQueueFence()
        XCTAssertEqual(frames - initial, ticks, "animated shader installs follow manual ticks, not a second draw timer")
        XCTAssertGreaterThanOrEqual(changes.count, 3, "Kitty changes while available shader draws only on host ticks")
        for interval in zip(changes.dropFirst(), changes).map({ $0.0.time - $0.1.time }) {
            XCTAssertEqual(interval, 0.4, accuracy: 0.18)
        }
        XCTAssertTrue(pane.feed(Data("\u{1b}_Ga=a,i=1,s=1\u{1b}\\".utf8)))
        try await drain(runtime)
        let gapFrames = frames
        let gapCPU = try rendererCPU(only: [renderer]).cpu
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(frames, gapFrames, "available without host ticks does not draw")
        XCTAssertLessThanOrEqual(try rendererCPU(only: [renderer]).cpu - gapCPU, 0.00005, "no redundant shader timer (50us renderer CPU tolerance over 3s)")
        ghostty_surface_set_vsync_state(pane.surface, GHOSTTY_VSYNC_UNAVAILABLE)
        let fallback = frames
        try await wait("visible unavailable shader fallback frames") { frames - fallback > 3 }
        XCTAssertGreaterThan(frames - fallback, 3, "visible unavailable surface retains timer animation fallback")
        ghostty_surface_set_vsync_state(pane.surface, GHOSTTY_VSYNC_AVAILABLE)
        XCTAssertTrue(ghostty_surface_take_vsync_demand(pane.surface))
        try await drain(runtime)
        let regained = frames
        let regainedCPU = try rendererCPU(only: [renderer]).cpu
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(frames, regained, "availability regain removes fallback draws between host ticks")
        XCTAssertLessThanOrEqual(try rendererCPU(only: [renderer]).cpu - regainedCPU, 0.00005)
        pane.isHidden = true
        ghostty_surface_set_occlusion(pane.surface, false)
        XCTAssertFalse(pane.visualVsync!.hasLink)
        ghostty_surface_set_vsync_state(pane.surface, GHOSTTY_VSYNC_UNAVAILABLE)
        _ = ghostty_surface_set_renderer_realized(pane.surface, false)
        try await drain(runtime)
        let hidden = frames
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(frames, hidden, "hidden unavailable shader has no frames")
    }

    func testSparseKittyUpdatesWithoutHostTicks() async throws {
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 0), font: 13) { _ in })
        defer { pane.dispose() }
        pane.resize(cols: 80, rows: 24)
        XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
        try await drain(runtime)
        var times: [Double] = []
        let observation = observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { times.append(CACurrentMediaTime()) }
        defer { observation.invalidate() }
        let packets = ["a=T,i=1,f=24,s=1,v=1,q=2;/wAA", "a=f,i=1,f=24,s=1,v=1,z=400,q=2;AAD/", "a=a,i=1,r=1,z=400,s=3,v=1"]
        XCTAssertTrue(pane.feed(Data(("\u{1b}[?25l" + packets.map { "\u{1b}_G\($0)\u{1b}\\" }.joined()).utf8)))
        try await drain(runtime)
        times.removeAll()
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThanOrEqual(times.count, 4, "sparse Kitty updates continue without output or host ticks")
        XCTAssertLessThanOrEqual(times.count, 6, "Kitty uses sparse update deadlines, not a continuous draw timer")
        for interval in zip(times.dropFirst(), times).map({ $0.0 - $0.1 }) {
            XCTAssertEqual(interval, 0.4, accuracy: 0.12)
        }
        XCTAssertEqual(pane.visualVsync?.ticks, 0)
        XCTAssertFalse(pane.visualVsync!.hasLink)
    }

    func testThirtyTwoOffscreenSurfacesAndChurnNeverAllocateCV() async throws {
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kido_renderer_thread"))
        let rendererThread = unsafeBitCast(symbol, to: (@convention(c) (Bool) -> UInt64).self)
        var fixtures: [(pane: PaneView, renderer: UInt64)] = []
        var weakDrivers: [() -> VsyncDriver?] = []
        var frames = 0
        var observations: [NSKeyValueObservation] = []
        for index in 0..<40 {
            _ = rendererThread(true)
            let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: UInt32(index)), font: 13) { _ in })
            observations.append(observeFrames(try XCTUnwrap(pane.subviews.first?.layer)) { frames += 1 })
            pane.resize(cols: 20, rows: 5)
            XCTAssertTrue(pane.commitSnapshot(epoch: pane.historyEpoch))
            XCTAssertTrue(pane.feed(Data("\u{1b}[?25lchurn \(index)\r\n".utf8)))
            let driver = try XCTUnwrap(pane.visualVsync)
            weakDrivers.append({ [weak driver] in driver })
            fixtures.append((pane, rendererThread(false)))
            if fixtures.count > 32 { fixtures.removeFirst().pane.dispose() }
        }
        try await drain(runtime)
        var panes = fixtures.map(\.pane)
        let ids = Set(fixtures.map(\.renderer))
        XCTAssertEqual(ids.count, 32)
        XCTAssertFalse(ids.contains(0))
        let activeCPU = try rendererCPU(only: ids)
        XCTAssertEqual(activeCPU.count, panes.count)
        let activeFrames = frames
        try await flow(panes)
        try await drain(runtime)
        XCTAssertGreaterThan(frames, activeFrames)
        XCTAssertGreaterThan(try rendererCPU(only: ids).cpu - activeCPU.cpu, 0.003)
        XCTAssertTrue(panes.allSatisfy { $0.visualVsync?.hasLink == false })
        let ticks = panes.map { $0.visualVsync!.ticks }
        let creates = panes.map { $0.visualVsync!.creates }
        let idleFrames = frames
        try await assertIdleCPU(ids)
        XCTAssertEqual(frames, idleFrames)
        XCTAssertEqual(panes.map { $0.visualVsync!.ticks }, ticks)
        XCTAssertEqual(panes.map { $0.visualVsync!.creates }, creates)
        XCTAssertTrue(panes.allSatisfy { $0.visualVsync?.hasLink == false })
        observations.forEach { $0.invalidate() }
        for pane in panes { pane.dispose() }
        panes.removeAll()
        fixtures.removeAll()
        await mainQueueFence()
        XCTAssertTrue(weakDrivers.allSatisfy { $0() == nil })
        XCTAssertEqual(try cvAllocations(), 0)
    }
}

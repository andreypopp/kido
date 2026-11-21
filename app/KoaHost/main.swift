import AppKit
import WebKit
import GhosttyKit
import KoModel
import PaneGeometry
import SnapshotTesting

@MainActor final class HostCanvas: NSView {
    let pane: PaneView
    let browser: WKWebView
    override var isFlipped: Bool { true }
    init(pane: PaneView, browser: WKWebView) {
        self.pane = pane
        self.browser = browser
        super.init(frame: .zero)
        addSubview(pane)
        addSubview(browser)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let id = PaneID(number: 1)
        var model = KoSchema.Window(cols: 1, floats: [], focus: id, id: WindowID(number: 1), name: "host", rows: 1,
                                    tree: .leaf(.init(cols: 1, pane: id, rows: 1)), vars: [:])
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let initial = PaneLayout(root: Layout(model).root, bounds: bounds, cell: pane.cell, pixel: pixel)
        model.cols = Int(initial.client.width)
        model.rows = Int(initial.client.height)
        model.tree = .leaf(.init(cols: model.cols, pane: id, rows: model.rows))
        let root = Layout(model).root
        let placement = PaneLayout(root: root, bounds: bounds, cell: pane.cell, pixel: pixel).tiled(root.geometry, alternate: false)
        pane.renderInsets = placement.insets
        pane.frame = placement.content
        browser.frame = WebviewPaneView.contentFrame(placement.content, chrome: placement.chrome, stripeTop: nil)
    }
}

@MainActor final class HostNavigation: NSObject, WKNavigationDelegate {
    var documents = 0
    var failure: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { documents += 1 }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
}

@MainActor final class HostRunner {
    let checkout: URL
    let baselines: URL
    let record: Bool
    let guest: URL?
    let selected: [KoaFixture: KoaSelection]
    var window: NSWindow!
    var runtime: GhosttyRuntime!
    var pane: PaneView!
    var browser: WKWebView!
    var child: Child?
    var navigation = HostNavigation()
    var serverURL: URL?
    var addressBytes = Data()
    var failures: [String] = []
    var stateCount = 0
    var equal = 0
    var different = 0
    var missing = 0
    var maximumDelta: Int?
    var board: NSPasteboard?
    var config: URL?

    init(checkout: URL, baselines: URL, record: Bool, guest: URL?, only: String) throws {
        self.checkout = checkout
        self.baselines = baselines
        self.record = record
        self.guest = guest
        var selected: [KoaFixture: KoaSelection] = [:]
        for item in only.split(whereSeparator: \.isWhitespace) {
            let parts = item.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let fixture = try requireValue(KoaFixture(rawValue: String(parts[0])), "Unknown fixture: \(parts[0])")
            if parts.count == 1 { selected[fixture] = .all }
            else {
                let name = String(parts[1])
                try require(!name.isEmpty, "Capture name is empty")
                switch selected[fixture] {
                case .all?: break
                case .captures(var names)?: names.insert(name); selected[fixture] = .captures(names)
                case nil: selected[fixture] = .captures([name])
                }
            }
        }
        self.selected = selected
    }

    func start(module: String, key: String, assets: URL, width: CGFloat, height: CGFloat) async throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("kido-host-\(getpid()).yaml")
        self.config = config
        try KoaContext.visualConfig.write(to: config, atomically: true, encoding: .utf8)
        let board = NSPasteboard(name: .init("kido-host-\(getpid())"))
        self.board = board
        runtime = try requireValue(GhosttyRuntime(configFile: config.path, pasteboard: board), "Ghostty runtime could not start")
        PaneView.renderOffscreen = true
        pane = try requireValue(PaneView(runtime: runtime, pane: PaneID(number: 1), font: 13), "Font metrics could not start")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.writingToolsBehavior = .none
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let initial = WebviewTheme.script(pane) + ";" + (WebviewPaneView.visualInitialScript ?? "")
        configuration.userContentController.addUserScript(WKUserScript(source: initial, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        browser = WKWebView(frame: .zero, configuration: configuration)
        browser.setValue(false, forKey: "drawsBackground")
        browser.allowsLinkPreview = false
        browser.underPageBackgroundColor = pane.paperColor
        navigation = HostNavigation()
        browser.navigationDelegate = navigation
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .displayP3
        window.contentView = HostCanvas(pane: pane, browser: browser)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        serverURL = nil
        addressBytes.removeAll()
        let output = Pipe()
        output.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self else { return }
                self.addressBytes.append(data)
                guard let end = self.addressBytes.firstIndex(of: 10) else { return }
                file.readabilityHandler = nil
                struct Address: Decodable { let url: URL }
                do { self.serverURL = try JSONDecoder().decode(Address.self, from: self.addressBytes.prefix(upTo: end)).url }
                catch { self.navigation.failure = error }
                self.addressBytes.removeAll()
            }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TZ"] = KoaContext.timeZone
        environment["PATH"] = [checkout.appendingPathComponent("koa/node_modules/.bin").path, "/opt/homebrew/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        child = try Child("/usr/bin/env", ["node", checkout.appendingPathComponent("koa/testdata/replay.ts").path, "--browser", "--headless", module, key, assets.path], env: environment, cwd: checkout.path, stdout: output)
        let deadline = Date().addingTimeInterval(15)
        while serverURL == nil && navigation.failure == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        if let failure = navigation.failure { throw failure }
        let url = try requireValue(serverURL, "Replay did not publish its URL: \(child?.stderr ?? "")")
        browser.load(URLRequest(url: url))
    }

    func updateTheme() {
        browser.appearance = NSAppearance(named: runtime.background.isDark ? .darkAqua : .aqua)
        browser.underPageBackgroundColor = pane.paperColor
        browser.evaluateJavaScript(WebviewTheme.script(pane) + ";window.dispatchEvent(new Event('ko-theme'))", completionHandler: nil)
    }

    func darken(_ appearance: NSAppearance.Name) async throws {
        var changed = false
        runtime.onConfigChange = { changed = true }
        window.appearance = NSAppearance(named: appearance)
        NSApp.appearance = NSAppearance(named: appearance)
        let deadline = Date().addingTimeInterval(5)
        while !changed && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try require(changed, "Appearance configuration did not change")
        ghostty_surface_set_color_scheme(pane.surface, runtime.colorScheme)
    }

    func close() async {
        child?.stop()
        await child?.finished()
        child = nil
        browser?.stopLoading()
        window?.contentView = nil
        window?.close()
        browser = nil
        pane = nil
        runtime = nil
        window = nil
        board?.releaseGlobally()
        board = nil
        if let config { try? FileManager.default.removeItem(at: config) }
    }

    func verify(_ image: NSImage, name: String, owner: String, fixture: KoaFixture) throws {
        try require(!window.isVisible && !window.isKeyWindow && !window.isMainWindow && !NSApp.isActive, "Headless window became visible or active")
        stateCount += 1
        if let failure = verifySnapshot(of: image, as: .pixels, named: name, record: record, snapshotDirectory: baselines.path, file: #filePath, testName: owner), !record || !failure.hasPrefix("Record mode is on.") {
            failures.append("\(fixture.rawValue)/\(name): \(failure)")
        }
        if let guest {
            let file = String(owner.prefix { $0 != "(" }) + "." + name + ".png"
            if let reference = NSImage(contentsOf: guest.appendingPathComponent(file)),
               let old = reference.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(imagePixels),
               let new = image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(imagePixels) {
                if old.width == new.width && old.height == new.height {
                    let delta = old.channels == new.channels ? 0 : zip(old.channels, new.channels).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
                    maximumDelta = maximumDelta.map { max($0, delta) } ?? delta
                    if delta <= 1 { equal += 1 } else { different += 1 }
                    print("GUEST \(fixture.rawValue)/\(name) \(delta <= 1 ? "equal" : "different") max_delta=\(delta)")
                } else {
                    different += 1
                    print("GUEST \(fixture.rawValue)/\(name) dimensions host=\(new.width)x\(new.height) guest=\(old.width)x\(old.height)")
                }
            } else { missing += 1; print("GUEST \(fixture.rawValue)/\(name) missing") }
        }
        print("CAPTURE \(fixture.rawValue)/\(name)")
    }

    func run() async throws {
        let began = Date()
        var pageFixtures = 0
        var nativeFixtures = 0
        for fixture in KoaFixture.allCases {
            switch fixture.capability {
            case .native(let reason): nativeFixtures += 1; print("SKIP \(fixture.rawValue): \(reason)"); continue
            case .logic:
                guard selected[fixture] != nil else { print("SKIP \(fixture.rawValue): no snapshot state"); continue }
                pageFixtures += 1
            case .page: pageFixtures += 1
            }
            if !selected.isEmpty && selected[fixture] == nil { continue }
            let backend = KoaBackend(
                checkout: checkout,
                diagnostic: { print($0) },
                start: { try await self.start(module: $0, key: $1, assets: $2, width: $3, height: $4) },
                window: { self.window }, pane: { self.pane }, browser: { self.browser }, terminal: { nil },
                prepare: {}, documents: { self.navigation.documents }, updateTheme: { self.updateTheme() },
                darken: { try await self.darken($0) },
                split: { _, _ in throw KoaFailure("Native split is VM-only") },
                nativeSnapshot: { _, _, _ in throw KoaFailure("Native snapshot is VM-only") },
                verify: { try self.verify($0, name: $1, owner: $2, fixture: fixture) }
            )
            let driver = KoaDriver(backend: backend, fixture: fixture, selection: selected[fixture] ?? .all)
            do {
                try await driver.run()
                if case .captures(let names) = driver.selection {
                    try require(names.isSubset(of: driver.captured), "Unknown capture selection: \(names.subtracting(driver.captured))")
                }
            } catch { failures.append("\(fixture.rawValue): \(error)") }
            do { try await driver.finish() } catch { failures.append("\(fixture.rawValue) replay: \(error)") }
            await close()
        }
        print("HOST fixtures=\(pageFixtures) vm_only=\(nativeFixtures) captures=\(stateCount) seconds=\(String(format: "%.3f", Date().timeIntervalSince(began)))")
        if guest != nil { print("GUEST equal=\(equal) different=\(different) missing=\(missing) max_delta=\(maximumDelta.map(String.init) ?? "none")") }
        if !failures.isEmpty { throw KoaFailure(failures.joined(separator: "\n")) }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
var observed: Set<pid_t> = []
var activations = 0
let activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { activations += 1 }
}
let watcher = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
    MainActor.assumeIsolated { if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { observed.insert(pid) } }
}
setenv("GHOSTTY_RESOURCES_DIR", Bundle.main.resourceURL!.appendingPathComponent("ghostty").path, 1)
Task { @MainActor in
    var failure: Error?
    do {
        try require(CommandLine.arguments.count == 3, "usage: KoaHost <checkout> <baseline-dir>")
        let environment = ProcessInfo.processInfo.environment
        let runner = try HostRunner(checkout: URL(fileURLWithPath: CommandLine.arguments[1]), baselines: URL(fileURLWithPath: CommandLine.arguments[2]), record: environment["KO_SNAPSHOT_RECORD"] == "1", guest: environment["KO_SNAPSHOT_GUEST"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }, only: environment["KO_SNAPSHOT_ONLY"] ?? "")
        try await runner.run()
    } catch { failure = error }
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    watcher.invalidate()
    NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    let after = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let focusOK = before != nil && before == after && observed.allSatisfy { $0 == before } && activations == 0 && !application.isActive
    print("FOCUS unchanged=\(focusOK) before=\(String(describing: before)) after=\(String(describing: after)) sampled=\(observed.sorted()) activations=\(activations) active=\(application.isActive)")
    if !focusOK { failure = KoaFailure("Frontmost application changed during headless snapshots") }
    if let failure { FileHandle.standardError.write(Data("\(failure)\n".utf8)); exit(1) }
    exit(0)
}
application.run()

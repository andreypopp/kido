import AppKit
import WebKit

struct KoaFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt
    var description: String { "\(file):\(line): \(message)" }
    init(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        self.message = message
        self.file = file
        self.line = line
    }
}

func requireValue<T>(_ value: T?, _ message: String = "Required value is missing", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw KoaFailure(message, file: file, line: line) }
    return value
}
func require(_ condition: Bool, _ message: String = "Condition failed", file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition { throw KoaFailure(message, file: file, line: line) }
}
func requireEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try require(actual == expected, "\(message): \(actual) != \(expected)", file: file, line: line)
}
func requireEqual(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try require(abs(actual - expected) <= accuracy, "\(message): \(actual) != \(expected) ±\(accuracy)", file: file, line: line)
}
func requireFalse(_ actual: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try require(!actual, message, file: file, line: line)
}
func requireLess<T: Comparable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try require(actual < expected, "\(message): \(actual) >= \(expected)", file: file, line: line)
}
func requireLessEqual<T: Comparable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try require(actual <= expected, "\(message): \(actual) > \(expected)", file: file, line: line)
}
func requireGreaterEqual<T: Comparable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
    try require(actual >= expected, "\(message): \(actual) < \(expected)", file: file, line: line)
}


let koaIdle = "!document.querySelector('#field').inert&&document.querySelector('#items [aria-label=working]')===null"
let koaWorking = "document.querySelector('#items [aria-label=working]')!==null"

enum Theme: String { case light, dark }

@MainActor final class Navigation: NSObject, WKNavigationDelegate {
    var documents = 0
    var failure: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { documents += 1 }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
}

struct ThemePayload: Decodable {
    struct Cell: Decodable { let width: Double; let height: Double }
    let pane: String
    let theme: [String: String]
    let cell: Cell
}

@MainActor class KoaContext {
    static let timeZone = "America/Los_Angeles"
    static let localeScript = "for(const method of ['toLocaleTimeString','toLocaleDateString']){const native=Date.prototype[method];Date.prototype[method]=function(locale,options){return native.call(this,locale,{...options,timeZone:'\(timeZone)'})}};Date.prototype.toDateString=function(){return this.toLocaleDateString('en-US')};"
    let checkoutRoot: URL
    let fixture: KoaFixture
    let selection: KoaSelection
    let pixels: Pixels
    var name: String { fixture.method }
    var window: NSWindow!
    var browser: WKWebView?
    var navigation = Navigation()
    var captured: Set<String> = []
    var paintRetry: ((String) async throws -> Void)?
    private var cleanup: [@MainActor () async throws -> Void] = []
    private var replay: Process?
    private var output: Pipe?
    private var errors: Pipe?
    private var address = Data()
    private var stderr = Data()
    private var serverURL: URL?
    init(checkout: URL, fixture: KoaFixture, selection: KoaSelection, pixels: Pixels) {
        checkoutRoot = checkout
        self.fixture = fixture
        self.selection = selection
        self.pixels = pixels
    }
    func addTeardownBlock(_ block: @escaping @MainActor () async throws -> Void) { cleanup.append(block) }
    func finish() async throws {
        var failure: Error?
        for block in cleanup.reversed() { do { try await block() } catch { failure = failure ?? error } }
        cleanup.removeAll()
        do { try await close() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
    private func themeScript(_ theme: Theme) throws -> String {
        let bytes = try Data(contentsOf: checkoutRoot.appendingPathComponent("koa/testdata/theme-\(theme.rawValue).json"))
        _ = try JSONDecoder().decode(ThemePayload.self, from: bytes)
        let json = try requireValue(String(data: bytes, encoding: .utf8))
        return "(()=>{window.ko=\(json);const apply=()=>{for(const [k,v] of Object.entries(ko.theme))document.documentElement.style.setProperty(k,v)};if(document.documentElement)apply();else{const observer=new MutationObserver(()=>{if(document.documentElement){apply();observer.disconnect()}});observer.observe(document,{childList:true,subtree:true})}})()"
    }
    func setTheme(_ theme: Theme) async throws {
        let web = try requireValue(browser)
        web.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        _ = try await webviewJS(web, "(()=>{" + themeScript(theme) + ";window.dispatchEvent(new Event('ko-theme'));return true})()")
    }
    func resize(_ viewport: NSSize) { window.setContentSize(viewport) }
    func start(module: String, key: String, assets: URL, viewport: NSSize, initialScripts: [String]) async throws {
        do {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.writingToolsBehavior = .none
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            for script in [try themeScript(.light)] + initialScripts {
                configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            }
            let web = WKWebView(frame: NSRect(origin: .zero, size: viewport), configuration: configuration)
            browser = web
            web.autoresizingMask = [.width, .height]
            web.setValue(false, forKey: "drawsBackground")
            web.allowsLinkPreview = false
            web.appearance = NSAppearance(named: .aqua)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: viewport), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.colorSpace = .displayP3
            window.contentView = NSView(frame: NSRect(origin: .zero, size: viewport))
            window.contentView?.addSubview(web)
            web.navigationDelegate = navigation
            let output = Pipe(), errors = Pipe()
            self.output = output
            self.errors = errors
            output.fileHandleForReading.readabilityHandler = { [weak self] file in
                let bytes = file.availableData
                if bytes.isEmpty { file.readabilityHandler = nil; return }
                Task { @MainActor in
                    guard let self, self.serverURL == nil else { return }
                    self.address.append(bytes)
                    if let end = self.address.firstIndex(of: 10) {
                        struct Address: Decodable { let url: URL }
                        do { self.serverURL = try JSONDecoder().decode(Address.self, from: self.address.prefix(upTo: end)).url }
                        catch { self.navigation.failure = error }
                    } else if self.address.count > 65536 { self.navigation.failure = KoaFailure("Replay URL line is too long") }
                }
            }
            errors.fileHandleForReading.readabilityHandler = { [weak self] file in
                let bytes = file.availableData
                if bytes.isEmpty { file.readabilityHandler = nil; return }
                Task { @MainActor in
                    self?.stderr.append(bytes)
                    if let self, self.stderr.count > 65536 { self.stderr = self.stderr.suffix(65536) }
                }
            }
            let process = Process()
            replay = process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", checkoutRoot.appendingPathComponent("koa/testdata/replay.ts").path, "--browser", "--headless", module, key, assets.path]
            var environment = ProcessInfo.processInfo.environment
            environment["TZ"] = Self.timeZone
            environment["PATH"] = [checkoutRoot.appendingPathComponent("koa/node_modules/.bin").path, "/opt/homebrew/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            process.environment = environment
            process.currentDirectoryURL = checkoutRoot
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            try await wait("replay URL", within: 15) { self.serverURL != nil || self.navigation.failure != nil || !process.isRunning }
            if let failure = navigation.failure { throw failure }
            try require(process.isRunning, "Replay exited early: " + String(decoding: stderr, as: UTF8.self))
            web.load(URLRequest(url: try requireValue(serverURL, "Replay did not publish its URL")))
            try await wait("page navigation", within: 15) { self.navigation.documents > 0 || self.navigation.failure != nil || !process.isRunning }
            if let failure = navigation.failure { throw failure }
            try require(process.isRunning, "Replay exited during navigation")
        } catch {
            do { try await close() }
            catch let cleanup { throw KoaFailure("Startup failed: \(error); cleanup failed: \(cleanup)") }
            throw error
        }
    }
    func close() async throws {
        browser?.stopLoading()
        window?.contentView = nil
        window?.close()
        browser = nil
        window = nil
        defer {
            output?.fileHandleForReading.readabilityHandler = nil
            errors?.fileHandleForReading.readabilityHandler = nil
        }
        if let replay, replay.isRunning {
            replay.terminate()
            try await wait("replay termination for pid \(replay.processIdentifier)", within: 5) { !replay.isRunning }
            replay.waitUntilExit()
        }
        replay = nil
    }
    func webviewJS(_ web: WKWebView, _ script: String, within seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        do { return try await KoaCapture.js(web, script, within: seconds) }
        catch { throw KoaFailure(String(describing: error), file: file, line: line) }
    }
    func webviewUntil(_ web: WKWebView, _ condition: String, within seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await webviewJS(web, "new Promise((resolve,reject)=>{const observer=new MutationObserver(check);const timer=setTimeout(()=>{clean();reject(Error('Webview condition deadline: '+\(String(reflecting: condition))+' | field='+document.querySelector('#prompt .cm-placeholder')?.textContent+' | items='+(document.querySelector('#items')?.textContent||'').slice(-400)))},\(seconds * 1000));function clean(){observer.disconnect();clearTimeout(timer);removeEventListener('resize',check);clearInterval(poll)}function check(){if(\(condition)){clean();resolve(true)}}observer.observe(document.documentElement,{attributes:true,childList:true,characterData:true,subtree:true});addEventListener('resize',check);const poll=setInterval(check,100);check()})", within: seconds, file: file, line: line)
    }
    func wait(_ label: String, within seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line, _ predicate: @escaping @MainActor () -> Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var ended = false
            @MainActor func check() {
                if ended { return }
                if predicate() { ended = true; continuation.resume() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { check() } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if !ended { ended = true; continuation.resume(throwing: KoaFailure("Deadline: " + label, file: file, line: line)) }
            }
            check()
        }
    }

    func webviewPageSnapshot(_ capture: String, crop: String? = nil, padding: NSEdgeInsets = .init(), testName: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let web = try requireValue(browser, file: file, line: line)
        let image = try await KoaCapture.snapshot(web, crop: crop, padding: padding, paintRetry: paintRetry, file: file, line: line)
        if case .captures(let names) = selection, !names.contains(capture) { return }
        try require(!window.isVisible && !window.isKeyWindow && !window.isMainWindow && !NSApp.isActive, "Headless window became visible or active")
        try pixels.verify(image, capture: capture, owner: testName, fixture: fixture)
        captured.insert(capture)
    }
}

import AppKit
import WebKit
import KoClientKit
import KoModel
#if !KOA_HOST
@testable import Kido
#endif

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

@MainActor func koaContentSize(window: NSWindow, width: CGFloat, height: CGFloat) {
    let chrome = window.frame.height - window.contentLayoutRect.height
    window.setContentSize(NSSize(width: width, height: height + chrome))
}

@MainActor struct KoaBackend {
    let checkout: URL
    let diagnostic: (String) -> Void
    let start: (String, String, URL, CGFloat, CGFloat) async throws -> Void
    let window: () -> NSWindow
    let pane: () -> PaneView?
    let browser: () -> WKWebView?
    let terminal: () -> WindowView?
    let prepare: () -> Void
    let documents: () -> Int
    func loaded() -> Bool { documents() > 0 }
    let updateTheme: () -> Void
    let darken: (NSAppearance.Name) async throws -> Void
    let split: (Int, KoSchema.Axis) async throws -> Void
    let nativeSnapshot: (PaneView, String, String) async throws -> Void
    let verify: (NSImage, String, String) throws -> Void
}

@MainActor class KoaContext {
    static let timeZone = "America/Los_Angeles"
    static let visualConfig = "app: {font: {size: 13}}\n"
    static let localeScript = "for(const method of ['toLocaleTimeString','toLocaleDateString']){const native=Date.prototype[method];Date.prototype[method]=function(locale,options){return native.call(this,locale,{...options,timeZone:'\(timeZone)'})}};Date.prototype.toDateString=function(){return this.toLocaleDateString('en-US')};"

    let backend: KoaBackend
    let fixture: KoaFixture
    var name: String { fixture.method }
    let selection: KoaSelection
    var captured: Set<String> = []
    var paintRetry: ((String) async throws -> Void)?
    private var cleanup: [@MainActor () async throws -> Void] = []
    init(backend: KoaBackend, fixture: KoaFixture, selection: KoaSelection = .all) {
        self.backend = backend
        self.fixture = fixture
        self.selection = selection
    }
    var window: NSWindow { backend.window() }
    var terminal: WindowView? { backend.terminal() }
    var checkoutRoot: URL { backend.checkout }
    func addTeardownBlock(_ block: @escaping @MainActor () async throws -> Void) { cleanup.append(block) }
    func finish() async throws {
        var failure: Error?
        for block in cleanup.reversed() { do { try await block() } catch { failure = failure ?? error } }
        cleanup.removeAll()
        if let failure { throw failure }
    }
    func darken(_ appearance: NSAppearance.Name = .darkAqua) async throws { try await backend.darken(appearance) }
    func split(_ pane: Int, _ axis: KoSchema.Axis) async throws { try await backend.split(pane, axis) }
    func webviewSnapshot(_ pane: PaneView, _ name: String, testName: String) async throws {
        try await backend.nativeSnapshot(pane, name, testName)
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
        let web = try requireValue(backend.browser(), file: file, line: line)
        let image: NSImage
        do { image = try await KoaCapture.snapshot(web, crop: crop, padding: padding, paintRetry: paintRetry, file: file, line: line) }
        catch let failure as KoaFailure { throw failure }
        catch { throw KoaFailure(String(describing: error), file: file, line: line) }
        if case .captures(let names) = selection, !names.contains(capture) { return }
        try backend.verify(image, capture, testName)
        captured.insert(capture)
    }
}

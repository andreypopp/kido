import AppKit
import KoClientKit
import WebKit
import KoModel
import SidebarFeed

@MainActor private final class WebviewBridge: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    weak var owner: WebviewPaneView?
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        if let owner { owner.webView(webView, start: task) }
        else { task.didFailWithError(URLError(.cancelled)) }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { owner?.webView(webView, stop: task) }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(controller, didReceive: message)
    }
}

private final class WebviewBrowser: WKWebView {
    // Remove this override when the installed WebKit has https://bugs.webkit.org/show_bug.cgi?id=327446 fixed.
    @objc var allowsWritingToolsAffordance: Bool { false }
}

final class WebviewPaneView: NSView, WKNavigationDelegate, WKUIDelegate {
    private static var rules: WKContentRuleList?
    private static var ruleWaiters: [(WKContentRuleList?) -> Void] = []
    weak var pane: PaneView?
    private weak var client: KoClient?
    let browser: WKWebView
    private let bridge: WebviewBridge
    private let unavailable = NSTextField(wrappingLabelWithString: "The program is not serving")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private struct PendingDocument {
        let navigation: WKNavigation
        let generation: String
    }
    private enum Document { case waiting, loading(URL, PendingDocument?), loaded(WKNavigation), failed(String) }
    private enum DocumentError: CustomNSError {
        case http(Int)
        static var errorDomain: String { "KidoWebview" }
        var errorCode: Int { switch self { case .http(let status): status } }
        var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: "HTTP \(errorCode)."] }
    }
    private var document = Document.waiting { didSet { renderDocument() } }
    private var page: String?
    private var serving = false
    private var ready = false
    private var stopped = false
    private var tasks: [ObjectIdentifier: Fetch] = [:]
    private var pending: [ObjectIdentifier] = []
    private var sockets: [Int: KoWebviewSocket] = [:]
    enum ComposerAction: Equatable {
        case focus, quote, prompt(record: String), promptQuote(record: String)
    }
    private(set) var composerAction: ComposerAction?
    private var generation = UUID().uuidString
    private var pendingDocument: PendingDocument? {
        if case .loading(_, let pending) = document { pending } else { nil }
    }
    private var ownsFocus: Bool {
        pane?.webviewFocused == true || window?.firstResponder === self || window?.firstResponder === retry
    }
    private var theme = ""
    private enum Reshow { case shown, unhidden, covered(DispatchWorkItem) }
    private var reshow = Reshow.shown
    private static let coverLimit = 0.5
    #if KIDO_VISUAL
    var visualFocus: ((Snapshot.Position) -> Void)?
    var visualAttended: Bool?
    var visualUncovered: ((Bool) -> Void)?
    var visualPreview: ((PreviewSource, NSRect) -> Void)?
    var visualPreviewLimit = Upload.fileLimit
    var visualFeedScript: String?
    var visualFeedPath: String?
    private(set) var visualFeedBytes = 0
    private(set) var visualRejectedNavigations = 0
    private(set) var visualDocuments = 0
    #endif

    private final class Preview {
        struct File { let name: String; var data = Data() }
        let url: URL
        let rect: NSRect
        var file: File?
        init(url: URL, rect: NSRect) { self.url = url; self.rect = rect }
    }
    private final class Fetch {
        enum Target { case page(any WKURLSchemeTask), preview(Preview) }
        let target: Target
        var transfer: KoWebviewFetch?
        init(_ target: Target) { self.target = target }
        var request: URLRequest {
            switch target {
            case .page(let task):
                var request = task.request
                for name in (request.allHTTPHeaderFields ?? [:]).keys where name.lowercased().hasPrefix("kido-") { request.setValue(nil, forHTTPHeaderField: name) }
                return request
            case .preview(let preview): return URLRequest(url: preview.url)
            }
        }
    }

    init(pane: PaneView, client: KoClient) {
        self.pane = pane
        self.client = client
        let bridge = WebviewBridge()
        self.bridge = bridge
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.writingToolsBehavior = .none
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.setURLSchemeHandler(bridge, forURLScheme: "ko")
        config.userContentController.add(bridge, contentWorld: .page, name: "koSocket")
        config.userContentController.add(bridge, contentWorld: .page, name: "koPreview")
        config.userContentController.add(bridge, contentWorld: .page, name: "koFocus")
        config.userContentController.add(bridge, contentWorld: .page, name: "koComposer")
        browser = WebviewBrowser(frame: .zero, configuration: config)
        super.init(frame: .zero)
        // WebKit's base background overwrites the layer colour before the page paints.
        browser.setValue(false, forKey: "drawsBackground")
        bridge.owner = self
        wantsLayer = true
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.allowsLinkPreview = false
        addSubview(browser)
        unavailable.alignment = .center
        unavailable.isHidden = true
        addSubview(unavailable)
        retry.target = self
        retry.action = #selector(retryDocument)
        retry.isHidden = true
        addSubview(retry)
        theme = themeScript()
        installScripts()
        updateTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(updateTheme), name: NSColor.systemColorsDidChangeNotification, object: nil)
        if let rules = Self.rules {
            config.userContentController.add(rules)
            ready = true
        } else {
            Self.ruleWaiters.append { [weak self] list in
                guard let self, !stopped else { return }
                guard let list else {
                    document = .failed("The page could not start.")
                    return
                }
                config.userContentController.add(list)
                ready = true
                load()
            }
            guard Self.ruleWaiters.count == 1 else { return }
            let rules = "[" + ["http", "https", "ws", "wss", "file", "data", "blob"].map { scheme in
                let document = ["data", "blob"].contains(scheme) ? #", "resource-type":["document"]"# : ""
                return #"{"trigger":{"url-filter":"^"# + scheme + #":"# + "\"" + document + #"},"action":{"type":"block"}}"#
            }.joined(separator: ",") + "]"
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ko-webview", encodedContentRuleList: rules) { list, _ in
                Self.rules = list
                let waiting = Self.ruleWaiters
                Self.ruleWaiters = []
                waiting.forEach { $0(list) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var nextResponder: NSResponder? {
        get { if let pane { pane } else { super.nextResponder } }
        set { super.nextResponder = newValue }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        switch document {
        case .loading, .loaded: return window?.makeFirstResponder(browser) == true
        case .waiting, .failed: return super.becomeFirstResponder()
        }
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        if case .shown = reshow { reshow = .unhidden }
        needsLayout = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        uncover()
    }

    private func uncover(signalled: Bool = false) {
        if case .covered(let timeout) = reshow {
            timeout.cancel()
            #if KIDO_VISUAL
            visualUncovered?(signalled)
            #endif
        }
        reshow = .shown
        browser.alphaValue = 1
    }

    override func layout() {
        super.layout()
        let resized = browser.frame.size != bounds.size
        browser.frame = bounds
        switch reshow {
        case .shown: break
        case .unhidden, .covered:
            if serving, resized { cover() }
            else if case .unhidden = reshow { reshow = .shown }
        }
        unavailable.frame = NSRect(x: 16, y: bounds.midY - 40, width: max(0, bounds.width - 32), height: 56)
        retry.sizeToFit()
        retry.frame.origin = NSPoint(x: bounds.midX - retry.frame.width / 2, y: bounds.midY + 20)
    }

    private func cover() {
        if case .covered(let previous) = reshow { previous.cancel() }
        let timeout = DispatchWorkItem { [weak self] in self?.uncover() }
        reshow = .covered(timeout)
        browser.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coverLimit, execute: timeout)
        let script = "const deadline = Date.now() + limit; const matches = () => Math.abs(innerWidth - width) <= 1 && Math.abs(innerHeight - height) <= 1; while (!matches() && Date.now() < deadline) await new Promise(done => setTimeout(done, 16)); if (!matches()) return false; await new Promise(done => { requestAnimationFrame(() => requestAnimationFrame(done)); setTimeout(done, 50) }); return true"
        let size = browser.safeAreaRect.size
        browser.callAsyncJavaScript(script, arguments: ["width": size.width, "height": size.height, "limit": Self.coverLimit * 1000], in: nil, in: .page) { [weak self] result in
            guard let self, case .covered(let current) = reshow, current === timeout, case .success(let matched) = result, matched as? Bool == true else { return }
            uncover(signalled: true)
        }
    }

    func update(path: String, serving: Bool) {
        let changed = page != path || self.serving != serving
        let transferFocus = self.serving != serving && ownsFocus
        page = path
        self.serving = serving
        if transferFocus && !serving { window?.makeFirstResponder(self) }
        if changed {
            document = .waiting
            browser.stopLoading()
            load()
        }
        if transferFocus && serving { _ = becomeFirstResponder() }
    }

    private func load() {
        guard ready, !stopped, serving, let pane, let page,
              let url = URL(string: "ko://\(pane.pane)\(page)") else { return }
        browser.load(URLRequest(url: url))
    }

    @objc private func retryDocument() { load() }

    private func renderDocument() {
        let focused = ownsFocus
        switch document {
        case .waiting:
            unavailable.stringValue = "The program is not serving"
            unavailable.isHidden = false
            retry.isHidden = true
            browser.isHidden = true
        case .loading, .loaded:
            unavailable.isHidden = true
            retry.isHidden = true
            browser.isHidden = false
        case .failed(let message):
            unavailable.stringValue = message
            unavailable.isHidden = false
            retry.isHidden = false
            browser.isHidden = true
            if focused { window?.makeFirstResponder(retry) }
        }
        needsLayout = true
    }

    private func failDocument(_ message: String) {
        document = .failed(message)
        installScripts()
    }

    func close() {
        guard !stopped else { return }
        stopped = true
        uncover()
        NotificationCenter.default.removeObserver(self, name: NSColor.systemColorsDidChangeNotification, object: nil)
        browser.stopLoading()
        for fetch in tasks.values { fetch.transfer?.cancel() }
        tasks = [:]
        pending = []
        for socket in sockets.values { socket.cancel() }
        sockets = [:]
        bridge.owner = nil
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "koSocket", contentWorld: .page)
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "koPreview", contentWorld: .page)
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "koFocus", contentWorld: .page)
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "koComposer", contentWorld: .page)
        browser.navigationDelegate = nil
        browser.uiDelegate = nil
        browser.removeFromSuperview()
        removeFromSuperview()
    }

    private func allowed(_ url: URL?) -> Bool {
        guard let url, let pane else { return false }
        return url.scheme == "ko" && url.host == pane.pane.description && url.port == nil && url.user == nil && url.password == nil
    }

    private static let maxActiveFetches = 6
    private static let maxPendingFetches = 64

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard !stopped, allowed(task.request.url) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        guard pending.count < Self.maxPendingFetches else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        let id = ObjectIdentifier(task)
        tasks[id] = Fetch(.page(task))
        pending.append(id)
        drain()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        tasks.removeValue(forKey: id)?.transfer?.cancel()
        pending.removeAll { $0 == id }
        drain()
    }

    private func failPreview(_ reason: String) {
        (pane?.window?.delegate as? WindowOwner)?.notices.show("Kido could not preview the file", reason)
    }

    private func finish(_ fetch: Fetch, _ result: Result<Void, Error>) {
        let id: ObjectIdentifier
        switch fetch.target { case .page(let task): id = ObjectIdentifier(task); case .preview(let preview): id = ObjectIdentifier(preview) }
        guard tasks.removeValue(forKey: id) != nil else { return }
        fetch.transfer?.cancel()
        pending.removeAll { $0 == id }
        switch fetch.target {
        case .page(let task):
            switch result { case .success: task.didFinish(); case .failure(let error): task.didFailWithError(error) }
        case .preview(let preview):
            if case .success = result, let file = preview.file {
                #if KIDO_VISUAL
                if let visualPreview { visualPreview(.file(file.data, name: file.name), preview.rect); drain(); return }
                #endif
                ImagePreview.shared.show(.file(file.data, name: file.name), rect: preview.rect)
            } else if case .failure(let error) = result, (error as? URLError)?.code == .dataLengthExceedsMaximum {
                failPreview("The file is over 64 MB")
            } else { failPreview("The file could not be loaded.") }
        }
        drain()
    }

    private func drain() {
        var active = tasks.values.filter { $0.transfer != nil }.count
        var consumed = 0
        while active < Self.maxActiveFetches, consumed < pending.count {
            let id = pending[consumed]
            consumed += 1
            guard let fetch = tasks[id], let pane, let client else { continue }
            do {
                fetch.transfer = try KoWebviewFetch(client: client, pane: pane.pane, request: fetch.request, response: { [weak self, weak fetch] status, headers in
                    guard let self, let fetch, tasks[id] === fetch else { return }
                    switch fetch.target {
                    case .page(let task):
                        // WebKit gives navigation policy a URLResponse without the custom scheme's HTTP status.
                        if case .loading(let url, _) = document, task.request.url == url, !(200..<300).contains(status) {
                            finish(fetch, .failure(DocumentError.http(Int(status))))
                            return
                        }
                        task.didReceive(HTTPURLResponse(url: task.request.url!, statusCode: Int(status), httpVersion: "HTTP/1.1", headerFields: headers)!)
                    case .preview(let preview):
                        guard status == 200 else { finish(fetch, .failure(URLError(.badServerResponse))); return }
                        let disposition = headers.first { $0.key.lowercased() == "content-disposition" }?.value ?? ""
                        let name = disposition.range(of: "filename*=UTF-8''", options: .caseInsensitive).flatMap { String(disposition[$0.upperBound...].prefix { $0 != ";" }).removingPercentEncoding } ?? "preview"
                        preview.file = Preview.File(name: name)
                    }
                }, body: { [weak self, weak fetch] data in
                    guard let self, let fetch, tasks[id] === fetch else { return }
                    switch fetch.target {
                    case .page(let task):
                        task.didReceive(data)
                        #if KIDO_VISUAL
                        if task.request.url?.path == visualFeedPath { visualFeedBytes += data.count }
                        #endif
                    case .preview(let preview):
                        var limit = Upload.fileLimit
                        #if KIDO_VISUAL
                        limit = visualPreviewLimit
                        #endif
                        guard let count = preview.file?.data.count, data.count <= limit - count else { finish(fetch, .failure(URLError(.dataLengthExceedsMaximum))); return }
                        preview.file?.data.append(data)
                    }
                }, end: { [weak self, weak fetch] result in
                    guard let self, let fetch else { return }
                    finish(fetch, result)
                })
                active += 1
            } catch {
                tasks.removeValue(forKey: id)
                switch fetch.target {
                case .page(let task): task.didFailWithError(error)
                case .preview: failPreview("The file could not be loaded.")
                }
            }
        }
        pending.removeFirst(consumed)
    }

    #if KIDO_VISUAL
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard case .loaded(let active) = document, active === navigation else { return }
        visualDocuments += 1
    }
    #endif

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, serving, !stopped, case .loading(let url, nil) = document else { return }
        document = .loading(url, PendingDocument(navigation: navigation, generation: UUID().uuidString))
        for (id, fetch) in tasks {
            if case .page = fetch.target { continue }
            tasks.removeValue(forKey: id); pending.removeAll { $0 == id }; fetch.transfer?.cancel()
        }
        installScripts()
        drain()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let pendingDocument, pendingDocument.navigation === navigation else { return }
        generation = pendingDocument.generation
        composerAction = nil
        document = .loaded(pendingDocument.navigation)
        if ownsFocus { window?.makeFirstResponder(browser) }
        for socket in sockets.values { socket.cancel() }
        sockets = [:]
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        switch document {
        case .loading:
            guard pendingDocument?.navigation === navigation else { return }
        case .loaded(let active):
            guard active === navigation else { return }
        case .waiting, .failed: return
        }
        failDocument("The page could not be loaded. \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if allowed(action.request.url), action.targetFrame != nil, !action.shouldPerformDownload {
            if action.targetFrame?.isMainFrame == true, let url = action.request.url { document = .loading(url, nil) }
            decisionHandler(.allow)
        } else {
            #if KIDO_VISUAL
            visualRejectedNavigations += 1
            #endif
            // WebKit reports button 1 for a trusted left click and 0 for a script click.
            if action.navigationType == .linkActivated, action.buttonNumber == 1, let url = action.request.url {
                pane?.onURL(url.absoluteString)
            }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let accepted = allowed(response.response.url) && response.canShowMIMEType
        if !accepted, response.isForMainFrame {
            failDocument("The page could not be displayed.")
            #if KIDO_VISUAL
            visualRejectedNavigations += 1
            #endif
        }
        decisionHandler(accepted ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    enum FindAnswer: Equatable { case missing, failed, cancelled, answered(index: Int, count: Int, loading: Bool) }

    // A koa page finds in its model, mounts the match and collapses the selection at it; any other page has no hook.
    func prepareFind(_ text: String, backwards: Bool, done: @escaping (FindAnswer) -> Void) {
        let script = "return typeof window.__koFind === 'function' ? await window.__koFind(query, backwards) : null"
        browser.callAsyncJavaScript(script, arguments: ["query": text, "backwards": backwards], in: nil, in: .page) { result in
            switch result {
            case .failure: done(.failed)
            case .success(let value):
                guard let answer = value as? [String: Any] else { done(.missing); return }
                if answer["cancelled"] as? Bool == true { done(.cancelled); return }
                guard let index = answer["index"] as? Int, let count = answer["count"] as? Int, let loading = answer["loading"] as? Bool else { done(.failed); return }
                done(.answered(index: index, count: count, loading: loading))
            }
        }
    }

    func quoteSelection(prompt: @escaping (String, String?) -> Void) {
        let document = generation
        browser.evaluateJavaScript("window.__koQuoteSelection&&window.__koQuoteSelection()") { [weak self] result, _ in
            guard let self, !stopped, pendingDocument == nil, generation == document,
                  let value = result as? [String: String], let record = value["record"] else { return }
            prompt(record, value["quote"])
        }
    }

    func cancelFind() { browser.evaluateJavaScript("window.__koFindCancel&&window.__koFindCancel()", completionHandler: nil) }

    func find(_ text: String, backwards: Bool = false, done: @escaping (Bool) -> Void) {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        browser.find(text, configuration: config) { done($0.matchFound) }
    }

    private func installScripts() {
        let controller = browser.configuration.userContentController
        controller.removeAllUserScripts()
        #if KIDO_VISUAL
        controller.addUserScript(WKUserScript(source: "window.__koNativeWebSocket=window.WebSocket", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if let visualFeedScript { controller.addUserScript(WKUserScript(source: visualFeedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)) }
        #endif
        controller.addUserScript(WKUserScript(source: Self.socketScript.replacingOccurrences(of: "__KO_DOCUMENT__", with: pendingDocument?.generation ?? generation), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: theme, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    @objc func updateTheme() {
        guard let pane else { return }
        browser.appearance = NSAppearance(named: pane.runtime.background.isDark ? .darkAqua : .aqua)
        browser.underPageBackgroundColor = pane.paperColor
        layer?.backgroundColor = pane.paperColor.cgColor
        unavailable.textColor = pane.runtime.foreground
        browser.isInspectable = pane.runtime.values.webview.inspector
        let next = themeScript()
        guard next != theme else { return }
        theme = next
        installScripts()
        browser.evaluateJavaScript(next + ";window.dispatchEvent(new Event('ko-theme'))", completionHandler: nil)
    }

    static func contentFrame(_ pane: CGRect, chrome: CGRect, stripeTop: CGFloat?) -> CGRect {
        var interior = chrome.insetBy(dx: 1, dy: 1)
        if let stripeTop {
            interior.origin.y = max(interior.minY, stripeTop + PaneChrome.stripeBand)
            interior.size.height = max(0, chrome.maxY - 1 - interior.minY)
        }
        return pane.intersection(interior)
    }

    private func themeScript() -> String {
        pane.map(WebviewTheme.script) ?? ""
    }

    private func attended(_ window: NSWindow) -> Bool {
        #if KIDO_VISUAL
        if let visualAttended { return visualAttended }
        #endif
        return window.isKeyWindow && window.firstResponder === browser
    }

    private func focusPane(_ data: [String: Any]) {
        guard pendingDocument == nil, let raw = data["pane"] as? String, let id = PaneID(ko: raw),
              let window, attended(window),
              let owner = window.delegate as? WindowOwner else { return }
        guard let target = owner.projection.placements[id]?.position else { owner.jumpWhenPlaced(id); return }
        #if KIDO_VISUAL
        if let visualFocus { visualFocus(target); return }
        #endif
        owner.perform(.jump(target))
    }

    private func preview(_ data: [String: Any]) {
        guard pendingDocument == nil, let raw = data["url"] as? String, let url = URL(string: raw), allowed(url),
              let numbers = data["rect"] as? [String: NSNumber], ["x", "y", "width", "height"].allSatisfy({ numbers[$0].map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true }),
              let x = numbers["x"]?.doubleValue, let y = numbers["y"]?.doubleValue, let width = numbers["width"]?.doubleValue, let height = numbers["height"]?.doubleValue,
              [x, y, width, height].allSatisfy({ $0.isFinite }), width >= 0, height >= 0,
              let window, window.isKeyWindow, window.firstResponder === browser,
              !tasks.values.contains(where: { if case .preview = $0.target { true } else { false } }),
              pending.count < Self.maxPendingFetches else { return }
        let screen = window.convertToScreen(convert(NSRect(x: x, y: y, width: width, height: height), to: nil))
        let preview = Preview(url: url, rect: screen), id = ObjectIdentifier(preview)
        tasks[id] = Fetch(.preview(preview)); pending.append(id); drain()
    }

    private enum SocketAction: String { case open, send, close, buffer, abort }

    private func dispatch(_ id: Int, generation: String, _ event: [String: Any]) {
        guard generation == self.generation, !stopped else { return }
        let data = try! JSONSerialization.data(withJSONObject: event)
        let json = String(data: data, encoding: .utf8)!
        browser.evaluateJavaScript("window.__koSocketEvent('\(generation)',\(id),\(json))", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame, allowed(message.frameInfo.request.url),
              let data = message.body as? [String: Any], data["document"] as? String == generation else { return }
        if message.name == "koPreview" { preview(data); return }
        if message.name == "koFocus" { focusPane(data); return }
        if message.name == "koComposer" {
            guard pendingDocument == nil, let value = data["state"] as? [String: String], let type = value["type"] else { return }
            switch type {
            case "focus": composerAction = .focus
            case "quote": composerAction = .quote
            case "prompt": if let record = value["record"] { composerAction = .prompt(record: record) }
            case "prompt_quote": if let record = value["record"] { composerAction = .promptQuote(record: record) }
            default: break
            }
            return
        }
        guard message.name == "koSocket", let id = data["id"] as? Int, id >= 0, let rawAction = data["action"] as? String, let action = SocketAction(rawValue: rawAction) else { return }
        let generation = generation
        switch action {
        case .open:
            guard sockets[id] == nil, sockets.count < 16, let raw = data["url"] as? String,
                  let url = URL(string: raw), allowed(url), let client, let pane else {
                dispatch(id, generation: generation, ["type": "close", "code": 1006, "reason": "Refused", "clean": false]); return
            }
            do {
                sockets[id] = try KoWebviewSocket(client: client, pane: pane.pane, url: url, opened: { [weak self] in
                    self?.dispatch(id, generation: generation, ["type": "open"])
                }, message: { [weak self] body, binary in
                    self?.dispatch(id, generation: generation, ["type": "message", "data": body.base64EncodedString(), "binary": binary])
                }, ended: { [weak self] code, reason, clean in
                    guard let self, generation == self.generation else { return }
                    sockets.removeValue(forKey: id)
                    dispatch(id, generation: generation, ["type": "close", "code": Int(code), "reason": reason, "clean": clean])
                })
            } catch {
                dispatch(id, generation: generation, ["type": "close", "code": 1006, "reason": "Connection failed", "clean": false])
            }
        case .send:
            guard let socket = sockets[id], let raw = data["data"] as? String,
                  let body = Data(base64Encoded: raw), body.count <= 65536,
                  let binary = data["binary"] as? Bool else { return }
            do {
                try socket.send(body, binary: binary)
                dispatch(id, generation: generation, ["type": "buffer", "amount": socket.bufferedAmount, "sent": body.count, "ack": true])
            } catch {
                socket.cancel()
                sockets.removeValue(forKey: id)
                dispatch(id, generation: generation, ["type": "close", "code": 1006, "reason": "Connection failed", "clean": false])
            }
        case .close:
            guard let socket = sockets[id], let code = data["code"] as? UInt16,
                  let reason = data["reason"] as? String else { return }
            do {
                try socket.close(code: code, reason: reason)
            } catch {
                socket.cancel()
                sockets.removeValue(forKey: id)
                dispatch(id, generation: generation, ["type": "close", "code": 1006, "reason": "Connection failed", "clean": false])
            }
        case .abort:
            sockets.removeValue(forKey: id)?.cancel()
        case .buffer:
            guard let socket = sockets[id] else { return }
            dispatch(id, generation: generation, ["type": "buffer", "amount": socket.bufferedAmount, "sent": 0])
        }
    }

    private static let socketScript = #"""
    (()=>{
      const bridge=window.webkit.messageHandlers.koSocket, sockets=new Map();let serial=0;
      const documentID='__KO_DOCUMENT__',MAX_PENDING_BYTES=1048576,MAX_PENDING_SENDS=256;
      window.__koFocus=(pane)=>window.webkit.messageHandlers.koFocus.postMessage({document:documentID,pane:String(pane)});
      window.__koComposer=(state)=>window.webkit.messageHandlers.koComposer.postMessage({document:documentID,state});
      window.__koPreview=(url,rect)=>window.webkit.messageHandlers.koPreview.postMessage({document:documentID,url,rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});
      const post=(s,action,args={})=>bridge.postMessage({document:documentID,id:s._id,action,...args});
      class Socket extends EventTarget {
        static CONNECTING=0;static OPEN=1;static CLOSING=2;static CLOSED=3;
        CONNECTING=0;OPEN=1;CLOSING=2;CLOSED=3;
        constructor(raw,protocols=[]){
          super();const url=new URL(raw,location.href);
          if(url.protocol!=='ko:'||url.host!==location.host||url.username||url.password||url.hash)throw new DOMException('Only this pane is allowed','SecurityError');
          if(protocols.length>0)throw new DOMException('Subprotocols are not supported','SyntaxError');
          this._id=++serial;this._url=url.href;this._state=0;this._pending=0;this._nativeBuffer=0;this._binaryType='blob';this._queue=[];this._pendingSends=0;this._draining=false;this._closing=null;
          sockets.set(this._id,this);post(this,'open',{url:url.href});
        }
        get url(){return this._url}get readyState(){return this._state}get protocol(){return ''}get extensions(){return ''}
        get bufferedAmount(){if(this._state===1)post(this,'buffer');return this._pending+this._nativeBuffer}
        get binaryType(){return this._binaryType}set binaryType(v){if(v==='blob'||v==='arraybuffer')this._binaryType=v}
        send(value){
          if(this._state===0)throw new DOMException('Connecting','InvalidStateError');if(this._state!==1)return;
          const binary=value instanceof Blob||value instanceof ArrayBuffer||ArrayBuffer.isView(value);let bytes;
          if(typeof value==='string')bytes=new TextEncoder().encode(value);
          else if(value instanceof Blob)bytes=value;
          else if(value instanceof ArrayBuffer)bytes=new Uint8Array(value);
          else if(ArrayBuffer.isView(value))bytes=new Uint8Array(value.buffer,value.byteOffset,value.byteLength);
          else bytes=new TextEncoder().encode(String(value));
          const size=bytes instanceof Blob?bytes.size:bytes.byteLength;
          if(size>65536){this._state=2;this._closing={code:1009,reason:'Message too large'};this._drain();return}
          if(this._pending+size>MAX_PENDING_BYTES||this._pendingSends>=MAX_PENDING_SENDS){this._abort();return}
          this._pending+=size;this._pendingSends++;this._queue.push({bytes:binary&&!(bytes instanceof Blob)?bytes.slice():bytes,binary});this._drain();
        }
        close(code=1000,reason=''){
          reason=String(reason);if(code!==1000&&(code<3000||code>4999))throw new DOMException('Invalid close code','InvalidAccessError');
          if(new TextEncoder().encode(reason).length>123)throw new DOMException('Reason too long','SyntaxError');
          if(this._state>=2)return;this._state=2;this._closing={code,reason};this._drain();
        }
        _finish(code,reason,clean){if(this._state===3)return;this._state=3;this._queue=[];this._pending=0;this._pendingSends=0;this._nativeBuffer=0;sockets.delete(this._id);if(!clean)this._emit(new Event('error'));this._emit(new CloseEvent('close',{code,reason,wasClean:clean}))}
        _abort(){if(this._state===3)return;post(this,'abort');this._finish(1006,'Send queue full',false)}
        async _drain(){
          if(this._draining)return;this._draining=true;
          try{
            while(this._queue.length&&this._state!==3){
              let {bytes,binary}=this._queue.shift();
              if(bytes instanceof Blob)bytes=new Uint8Array(await bytes.arrayBuffer());
              if(this._state===3)return;
              let text='';for(let offset=0;offset<bytes.length;offset+=8192)text+=String.fromCharCode(...bytes.subarray(offset,offset+8192));
              post(this,'send',{data:btoa(text),binary});
            }
            if(this._state===2&&this._closing){post(this,'close',this._closing);this._closing=null}
          }catch{this._abort()}finally{this._draining=false}
        }
        _emit(event){this.dispatchEvent(event);const handler=this['on'+event.type];if(typeof handler==='function')handler.call(this,event)}
      }
      for(const name of ['open','message','close','error'])Socket.prototype['on'+name]=null;
      window.__koSocketEvent=(generation,id,e)=>{if(generation!==documentID)return;const s=sockets.get(id);if(!s)return;
        if(e.type==='open'){if(s._state===0){s._state=1;s._emit(new Event('open'))}}
        else if(e.type==='message'){const bytes=Uint8Array.from(atob(e.data),c=>c.charCodeAt(0));const data=e.binary?(s.binaryType==='blob'?new Blob([bytes]):bytes.buffer):new TextDecoder().decode(bytes);s._emit(new MessageEvent('message',{data,origin:location.origin}))}
        else if(e.type==='buffer'){if(e.ack)s._pendingSends=Math.max(0,s._pendingSends-1);s._pending=Math.max(0,s._pending-e.sent);s._nativeBuffer=e.amount}
        else if(e.type==='error')s._emit(new Event('error'));
        else if(e.type==='close')s._finish(e.code,e.reason,e.clean);
      };window.WebSocket=Socket;
    })();
    """#
}

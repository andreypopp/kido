import AppKit
import WebKit
import KoModel

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

final class WebviewPaneView: NSView, WKNavigationDelegate, WKUIDelegate {
    private static var rules: WKContentRuleList?
    private static var ruleWaiters: [(WKContentRuleList?) -> Void] = []
    weak var pane: PaneView?
    private weak var client: KoClient?
    let browser: WKWebView
    private let bridge: WebviewBridge
    private let unavailable = NSTextField(labelWithString: "The program is not serving")
    private var page: String?
    private var serving = false
    private var ready = false
    private var stopped = false
    private var tasks: [ObjectIdentifier: Fetch] = [:]
    private var pending: [ObjectIdentifier] = []
    private var sockets: [Int: KoWebviewSocket] = [:]
    private var generation = UUID().uuidString
    private var pendingDocument: (navigation: WKNavigation, generation: String)?
    private var theme = ""
    #if KIDO_VISUAL
    var visualFeedScript: String?
    var visualFeedPath: String?
    private(set) var visualFeedBytes = 0
    private(set) var visualRejectedNavigations = 0
    private(set) var visualDocuments = 0
    #endif

    private final class Fetch {
        let task: any WKURLSchemeTask
        var transfer: KoWebviewFetch?
        init(_ task: any WKURLSchemeTask) { self.task = task }
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
        browser = WKWebView(frame: .zero, configuration: config)
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
                    unavailable.stringValue = "webview could not start"
                    unavailable.isHidden = false
                    browser.isHidden = true
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
    override func becomeFirstResponder() -> Bool { serving ? window?.makeFirstResponder(browser) == true : super.becomeFirstResponder() }
    override func layout() {
        super.layout()
        browser.frame = bounds
        unavailable.frame = NSRect(x: 8, y: bounds.midY - 12, width: max(0, bounds.width - 16), height: 24)
    }

    func update(path: String, serving: Bool) {
        let changed = page != path || self.serving != serving
        let transferFocus = self.serving != serving && pane?.webviewFocused == true
        page = path
        self.serving = serving
        if transferFocus && !serving { window?.makeFirstResponder(self) }
        unavailable.isHidden = serving
        browser.isHidden = !serving
        if transferFocus && serving { window?.makeFirstResponder(browser) }
        if changed { load() }
    }

    private func load() {
        guard ready, !stopped, serving, let pane, let page,
              let url = URL(string: "ko://\(pane.pane)\(page)") else { return }
        browser.load(URLRequest(url: url))
    }

    func close() {
        guard !stopped else { return }
        stopped = true
        NotificationCenter.default.removeObserver(self, name: NSColor.systemColorsDidChangeNotification, object: nil)
        browser.stopLoading()
        for fetch in tasks.values { fetch.transfer?.cancel() }
        tasks = [:]
        pending = []
        for socket in sockets.values { socket.cancel() }
        sockets = [:]
        bridge.owner = nil
        browser.configuration.userContentController.removeScriptMessageHandler(forName: "koSocket", contentWorld: .page)
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
        tasks[id] = Fetch(task)
        pending.append(id)
        drain()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        tasks.removeValue(forKey: id)?.transfer?.cancel()
        pending.removeAll { $0 == id }
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
                fetch.transfer = try KoWebviewFetch(client: client, pane: pane.pane, request: fetch.task.request, response: { [weak fetch] status, headers in
                    guard let fetch else { return }
                    let response = HTTPURLResponse(url: fetch.task.request.url!, statusCode: Int(status), httpVersion: "HTTP/1.1", headerFields: headers)!
                    fetch.task.didReceive(response)
                }, body: { [weak self, weak fetch] data in
                    fetch?.task.didReceive(data)
                    #if KIDO_VISUAL
                    if let self, let path = visualFeedPath, fetch?.task.request.url?.path == path { visualFeedBytes += data.count }
                    #endif
                }, end: { [weak self, weak fetch] result in
                    guard let self, let fetch else { return }
                    switch result {
                    case .success: fetch.task.didFinish()
                    case .failure(let error): fetch.task.didFailWithError(error)
                    }
                    tasks.removeValue(forKey: ObjectIdentifier(fetch.task))
                    drain()
                })
                active += 1
            } catch {
                fetch.task.didFailWithError(error)
                tasks.removeValue(forKey: id)
            }
        }
        pending.removeFirst(consumed)
    }

    #if KIDO_VISUAL
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { visualDocuments += 1 }
    #endif

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        pendingDocument = (navigation, UUID().uuidString)
        installScripts()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let pendingDocument, pendingDocument.navigation === navigation else { return }
        generation = pendingDocument.generation
        self.pendingDocument = nil
        for socket in sockets.values { socket.cancel() }
        sockets = [:]
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard pendingDocument?.navigation === navigation else { return }
        pendingDocument = nil
        installScripts()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if allowed(action.request.url), action.targetFrame != nil, !action.shouldPerformDownload {
            decisionHandler(.allow)
        } else {
            #if KIDO_VISUAL
            visualRejectedNavigations += 1
            #endif
            if action.navigationType == .linkActivated, pane?.runtime.values.webview.links == .open,
               let url = action.request.url, ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let accepted = allowed(response.response.url) && response.canShowMIMEType
        if !accepted, response.isForMainFrame {
            pendingDocument = nil
            installScripts()
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
    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

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

    private func themeScript() -> String {
        guard let pane else { return "" }
        let runtime = pane.runtime
        func rgb(_ color: NSColor) -> String {
            let value = color.usingColorSpace(.sRGB)!
            let components = "\(Int(value.redComponent * 255)),\(Int(value.greenComponent * 255)),\(Int(value.blueComponent * 255))"
            return value.alphaComponent == 1 ? "rgb(\(components))" : "rgba(\(components),\(value.alphaComponent))"
        }
        let colors = runtime.webviewColors
        let family = (runtime.values.font.family ?? GhosttyRuntime.systemFontFamily)
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var properties = ["--ko-focus": rgb(Chrome.focusStroke), "--ko-bg": rgb(pane.paperColor), "--ko-fg": rgb(runtime.foreground), "--ko-cursor": rgb(colors.cursor),
                          "--ko-selection-bg": rgb(colors.selectionBackground), "--ko-selection-fg": rgb(colors.selectionForeground),
                          "--ko-font-family": "\"\(family)\", monospace",
                          "--ko-font-size": "\(pane.font)px", "--ko-cell-width": "\(pane.cell.width)px", "--ko-cell-height": "\(pane.cell.height)px",
                          "--ko-appearance": runtime.background.isDark ? "dark" : "light"]
        for (index, color) in colors.palette.enumerated() { properties["--ko-color-\(index)"] = rgb(color) }
        let value: [String: Any] = ["pane": pane.pane.description, "theme": properties, "cell": ["width": pane.cell.width, "height": pane.cell.height]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
        return "(()=>{const ko=\(json);window.ko=ko;const apply=()=>{for(const [k,v] of Object.entries(ko.theme))document.documentElement.style.setProperty(k,v)};if(document.documentElement)apply();else {const observer=new MutationObserver(()=>{if(document.documentElement){apply();observer.disconnect()}});observer.observe(document,{childList:true,subtree:true})}})()"
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
              let data = message.body as? [String: Any], data["document"] as? String == generation,
              let id = data["id"] as? Int, id >= 0, let rawAction = data["action"] as? String, let action = SocketAction(rawValue: rawAction) else { return }
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

import AppKit
import KoClientKit
import KoModel
import Network
import WebKit
import XCTest
@testable import Kido

@MainActor final class WebviewPaneTests: KoTestCase {
    func testHTTPFailureCanRetry() throws { try documentFailure(.http) }
    func testTransportFailureCanRetry() throws { try documentFailure(.transport) }

    private func javascript(_ browser: WKWebView, _ script: String) throws -> Any {
        let completed = expectation(description: "JavaScript completes")
        var result: Result<Any, Error>?
        browser.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer in
            result = answer
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func documentFailure(_ failure: DocumentServer.Reply) throws {
        let dir = try stateDir(), socket = dir + "/document.sock"
        let toy = try DocumentServer(path: socket, reply: failure)
        try toy.start()
        defer { toy.stop() }
        _ = try serverWithPane("'\(tools.ko)' webview enter; exec '\(tools.ko)' webview serve --socket '\(socket)'", at: dir)
        let client = try connect(dir, hello: KoHello(webview: true)) { _ in }
        wait("the bridge serves") { (try? client.model())?.pane(PaneID(number: 1))?.webview?.serving == true }
        let board = NSPasteboard(name: .init("webview-error-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let runtime = try XCTUnwrap(GhosttyRuntime(pasteboard: board))
        let pane = try XCTUnwrap(PaneView(runtime: runtime, pane: PaneID(number: 1), font: 0))
        let view = WebviewPaneView(pane: pane, client: client)
        defer { view.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }
        view.update(path: "/", serving: true)
        let message = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
        wait("the failed document shows its native error") { !message.isHidden && message.stringValue != "The program is not serving" }
        XCTAssertGreaterThan(toy.requests, 0)
        XCTAssertTrue(view.browser.isHidden)
        XCTAssertTrue(message.stringValue.contains(failure == .http ? "502" : "could not"), message.stringValue)
        let retry = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
        XCTAssertFalse(retry.isHidden)
        toy.reply = .success
        window.makeFirstResponder(retry)
        retry.performClick(nil)
        wait("Retry loads a fresh GET") { toy.requests == 2 && !view.browser.isLoading && !view.browser.isHidden }
        XCTAssertTrue(message.isHidden)
        XCTAssertTrue(retry.isHidden)
        XCTAssertTrue(window.firstResponder === view.browser)
        XCTAssertEqual(try javascript(view.browser, "return document.body.textContent") as? String, "Ready")
        if failure == .http {
            toy.reply = .http
            XCTAssertEqual(try javascript(view.browser, "return (await fetch(location.href)).status") as? Int, 502)
            XCTAssertTrue(message.isHidden)
            view.browser.evaluateJavaScript("location.reload()", completionHandler: nil)
            wait("a script reload shows its native error") { !message.isHidden }
            XCTAssertTrue(message.stringValue.contains("502"), message.stringValue)
            toy.reply = .success
            let beforeRetry = toy.requests
            retry.performClick(nil)
            wait("Retry after script reload") { toy.requests > beforeRetry && !view.browser.isLoading && !view.browser.isHidden }

            window.makeFirstResponder(view)
            view.update(path: "/", serving: false)
            XCTAssertTrue(window.firstResponder === view)
            view.update(path: "/", serving: true)
            wait("a new serving document takes focus") { !view.browser.isLoading && window.firstResponder === view.browser }

            toy.reply = .held
            view.update(path: "/held", serving: true)
            wait("navigation A waits for its response") { toy.heldCount == 1 }
            toy.reply = .http
            view.update(path: "/failure", serving: true)
            wait("navigation B shows its own HTTP error") { !message.isHidden && message.stringValue.contains("502") }
            XCTAssertTrue(view.browser.isHidden)
            XCTAssertFalse(retry.isHidden)

            toy.release()
            toy.reply = .held
            view.update(path: "/focus", serving: true)
            wait("the focus test document waits") { toy.heldCount == 1 }
            let elsewhere = NSButton(title: "Elsewhere", target: nil, action: nil)
            content.addSubview(elsewhere)
            window.makeFirstResponder(elsewhere)
            toy.release()
            wait("the document loads without taking focus back") { !view.browser.isLoading && !view.browser.isHidden }
            XCTAssertTrue(window.firstResponder === elsewhere)
            XCTAssertEqual(try javascript(view.browser, "return document.body.textContent") as? String, "Ready")
        }
    }
}

private final class DocumentServer: @unchecked Sendable {
    enum Reply { case http, transport, success, held }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "webview-document-test")
    private var response: Reply
    private var count = 0
    private var connections: [NWConnection] = []
    private var held: [NWConnection] = []
    private var startResult: Result<Void, Error>?
    var reply: Reply { get { queue.sync { response } } set { queue.sync { response = newValue } } }
    var requests: Int { queue.sync { count } }
    var heldCount: Int { queue.sync { held.count } }
    init(path: String, reply: Reply) throws {
        response = reply
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: parameters)
    }
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: startResult = .success(())
            case .failed(let error): startResult = .failure(error)
            default: return
            }
            listener.stateUpdateHandler = nil
            ready.signal()
        }
        listener.newConnectionHandler = { [self] connection in
            connections.append(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] _, _, _, _ in
                count += 1
                respond(connection, response)
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { listener.cancel(); throw URLError(.timedOut) }
        guard let result = queue.sync(execute: { startResult }) else { throw URLError(.cannotConnectToHost) }
        try result.get()
    }
    private func respond(_ connection: NWConnection, _ reply: Reply) {
        switch reply {
        case .held: held.append(connection)
        case .http, .transport, .success:
            let status = reply == .http ? "502 Bad Gateway" : "200 OK"
            let body = reply == .http ? "{\"kind\":\"io\"}" : reply == .transport ? "<body>Partial" : "<body>Ready</body>"
            let length = body.utf8.count + (reply == .transport ? 100 : 0)
            let bytes = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n\(body)".utf8)
            connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func release() { queue.sync { for connection in held { respond(connection, .success) }; held = [] } }
    func stop() { queue.sync { listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel(); connections.forEach { $0.cancel() }; connections = []; held = [] } }
}

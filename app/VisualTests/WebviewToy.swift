import Foundation
import Network
import CryptoKit

final class WebviewToy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "webview-toy")
    private var connections: [NWConnection] = []
    private var starting: CheckedContinuation<Void, Error>?
    private var delayed: [NWConnection] = []
    private var documents: [NWConnection] = []
    var heldDocumentCount: Int { queue.sync { documents.count } }
    func releaseDocuments() {
        queue.sync {
            let body = Data(Self.page.utf8)
            for connection in documents {
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
            documents = []
        }
    }
    private var previewRequests: [String] = []
    private var heldPreviews: [NWConnection] = []
    var previews: [String] { queue.sync { previewRequests } }
    func releasePreviews() { queue.sync { for connection in heldPreviews { previewReply(connection, path: "held") }; heldPreviews = [] } }
    private func previewReply(_ connection: NWConnection, path: String) {
        let body = Data((path.contains("big") ? String(repeating: "x", count: 32) : "preview").utf8), status = path.contains("missing") ? "404 Not Found" : "200 OK"
        connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Disposition: inline; filename*=UTF-8''folder%2Fsource.swift\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    private var opened = Set<ObjectIdentifier>()
    private var messages = 0
    var messageCount: Int { queue.sync { messages } }
    private var stashStream: NWConnection?
    private var encodedHead = ""
    var encodedRequest: String { queue.sync { encodedHead } }
    func writeStash() {
        queue.sync {
            stashStream?.send(content: Self.chunk(String(repeating: "x", count: 4096)), completion: .contentProcessed { _ in })
        }
    }
    func finishStash() {
        queue.sync {
            stashStream?.send(content: Self.chunk(""), completion: .contentProcessed { _ in })
        }
    }
    private var slots: [(id: Int, connection: NWConnection?)] = []
    private var releasedSlots = Set<Int>()
    var acceptedSlots: [Int] { queue.sync { slots.map(\.id) } }
    var waitingSlots: Int { queue.sync { slots.filter { $0.connection != nil }.count } }
    func releaseSlot(_ id: Int) {
        queue.sync {
            releasedSlots.insert(id)
            finishSlot(id)
        }
    }
    private func finishSlot(_ id: Int) {
        guard let index = slots.firstIndex(where: { $0.id == id }), let connection = slots[index].connection else { return }
        slots[index].connection = nil
        let body = Data(String(id).utf8)
        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    var delayedCount: Int { queue.sync { delayed.count } }
    var socketCount: Int { queue.sync { opened.count } }
    let path: String

    init(path: String) throws {
        self.path = path
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            starting = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let pending = starting else { return }
                switch state {
                case .ready:
                    starting = nil
                    pending.resume()
                case .failed(let error):
                    starting = nil
                    pending.resume(throwing: error)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 5) { [self] in
                guard let pending = starting else { return }
                starting = nil
                listener.cancel()
                pending.resume(throwing: URLError(.timedOut))
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connections.append(connection)
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    if case .cancelled = state, let connection {
                        self?.opened.remove(ObjectIdentifier(connection))
                        connection.stateUpdateHandler = nil
                    }
                }
                connection.start(queue: queue)
                head(connection, Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections = []
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func head(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
            guard let self else { return }
            var data = previous
            if let bytes { data.append(bytes) }
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil && data.count < 65536 { head(connection, data) }
                else { connection.cancel() }
                return
            }
            let text = String(decoding: data[..<end.upperBound], as: UTF8.self)
            if let path = text.split(separator: " ").dropFirst().first, path.hasPrefix("/images/") || path.hasPrefix("/attachments/") || path.hasPrefix("/steps/") || path == "/files/held" {
                previewRequests.append(String(path))
                if path.contains("held") { heldPreviews.append(connection) } else { previewReply(connection, path: String(path)) }
                return
            }
            if text.hasPrefix("GET /held ") { documents.append(connection); return }
            if text.hasPrefix("GET /encoded ") {
                encodedHead = text
                let body = Data(base64Encoded: "H4sIAAAAAAAA/0vNS85PSU1RKE7OSM1NVUjKT6kEAHcGrlsTAAAA")!
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if text.hasPrefix("GET /truncated ") {
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\npartial".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if text.hasPrefix("GET /metadata ") {
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\nConnection: X-Private\r\nX-Private: hidden\r\nProxy-Custom: hidden\r\nX-Public: kept\r\n\r\n6\r\nfinite\r\n0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if text.hasPrefix("GET /stash ") {
                stashStream = connection
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + Self.chunk(String(repeating: "x", count: 4096)), completion: .contentProcessed { _ in })
                return
            }
            if text.hasPrefix("GET /sse ") {
                let body = "data: {\"record\":1}\n\n"
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8) + Self.chunk(body), completion: .contentProcessed { _ in })
                return
            }
            if text.hasPrefix("GET /events ") {
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                return
            }
            if let path = text.split(separator: " ").dropFirst().first, path.hasPrefix("/slot/"), let id = Int(path.dropFirst(6)) {
                slots.append((id, connection))
                if releasedSlots.contains(id) { finishSlot(id) }
                return
            }
            if text.hasPrefix("POST /body ") {
                let length = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })?.split(separator: ":", maxSplits: 1).last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
                body(connection, Data(data[end.upperBound...]), length)
                return
            }
            if let key = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") })?.split(separator: ":", maxSplits: 1).last {
                if text.hasPrefix("GET /delayed ") { delayed.append(connection); return }
                opened.insert(ObjectIdentifier(connection))
                let input = key.trimmingCharacters(in: .whitespaces) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                let accept = Data(Insecure.SHA1.hash(data: Data(input.utf8))).base64EncodedString()
                let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                let remainder = Data(data[end.upperBound...])
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                    if error == nil { self?.frame(connection, remainder) }
                })
            } else {
                let body = Data(Self.page.utf8)
                let type = text.hasPrefix("GET /download ") ? "application/octet-stream" : "text/html; charset=utf-8"
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private static func chunk(_ body: String) -> Data {
        Data("\(String(body.utf8.count, radix: 16))\r\n\(body)\r\n".utf8)
    }

    private func body(_ connection: NWConnection, _ data: Data, _ length: Int) {
        if data.count >= length {
            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8) + data
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
            guard let bytes, !complete, error == nil else { connection.cancel(); return }
            self?.body(connection, data + bytes, length)
        }
    }

    private func frame(_ connection: NWConnection, _ previous: Data) {
        if previous.count >= 2 {
            let bytes = Array(previous)
            let length = Int(bytes[1] & 127)
            guard length < 126, bytes[1] & 128 != 0 else { connection.cancel(); return }
            if previous.count >= length + 6 {
                if bytes[0] & 15 != 8 { messages += 1 }
                let payload = (0..<length).map { bytes[$0 + 6] ^ bytes[2 + $0 % 4] }
                let response = Data([bytes[0], UInt8(length)] + payload)
                connection.send(content: response, completion: .contentProcessed { [weak self] error in
                    if error == nil, bytes[0] & 15 != 8 { self?.frame(connection, Data(previous.dropFirst(length + 6))) }
                    else { connection.cancel() }
                })
                return
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
            guard let bytes, !complete, error == nil else { connection.cancel(); return }
            self?.frame(connection, previous + bytes)
        }
    }

    private static let page = #"""
    <!doctype html><html><meta charset="utf-8"><title>HTML pane</title>
    <style>
    :root{color-scheme:light dark}body{margin:0;padding:32px;background:var(--ko-bg);color:var(--ko-fg);font:15px -apple-system}
    h1{font-size:26px;margin:0 0 12px}p{line-height:1.5;opacity:.75}input{font:inherit;padding:8px;border:1px solid var(--ko-color-8);background:var(--ko-bg);color:var(--ko-fg)}
    .card{border:1px solid var(--ko-color-8);padding:24px;border-radius:8px;max-width:420px}code{font-family:var(--ko-font-family)}
    </style><body><div class="card"><h1>HTML pane</h1><p>A page from this pane's program.<br>The terminal stays below the page.</p><input id="input" placeholder="Type here"><p><code id="theme"></code></p></div>
    <script>
    const solid=new URLSearchParams(location.search).get('solid');
    if(solid){document.querySelector('.card').style.display='none';document.body.style.cssText='margin:0;padding:0;min-height:100vh;background:#'+solid}
    window.themeEvents=0;window.keys=[];window.ready=false;window.documentToken=Math.random();
    window.httpsPolicy=new Promise(resolve=>addEventListener('securitypolicyviolation',e=>{if(e.blockedURI.startsWith('https://example.invalid'))resolve(e.violatedDirective)}));
    window.initialActivation=navigator.userActivation.isActive;
    if(new URLSearchParams(location.search).has('gates')){
      window.clipboardRead=navigator.clipboard.readText().then(text=>({denied:false,text}),()=>({denied:true,text:null}));
      window.clipboardItemsRead=navigator.clipboard.read().then(items=>({denied:false,count:items.length}),()=>({denied:true,count:0}));
      window.clipboardWrite=navigator.clipboard.writeText('kido-webview-test').then(()=>false,()=>true);
      window.notificationPermission=Notification.requestPermission();
      window.workerDenied=navigator.serviceWorker.register('/worker.js').then(reg=>{reg.unregister();return false},()=>true);
      window.mediaDenied=navigator.mediaDevices?navigator.mediaDevices.getUserMedia({audio:true,video:true}).then(stream=>{stream.getTracks().forEach(t=>t.stop());return false},()=>true):Promise.resolve(true);
      window.geoDenied=new Promise(resolve=>navigator.geolocation.getCurrentPosition(()=>resolve(0),error=>resolve(error.code)));
    }
    const theme=()=>document.querySelector('#theme').textContent='Appearance: '+window.ko.theme['--ko-appearance'];theme();
    addEventListener('ko-theme',()=>{themeEvents++;theme()});addEventListener('keydown',e=>keys.push(e.key));
    window.echo=new Promise((resolve,reject)=>{const ws=new WebSocket('/echo');let step=0;ws.binaryType='arraybuffer';
      window.closedSocket=new Promise(done=>ws.onclose=e=>done([e.code,e.reason,e.wasClean]));
      ws.onopen=()=>ws.send('hello');ws.onmessage=async e=>{
        if(step===0){if(e.data!=='hello')return reject(Error('text'));step++;ws.send(new Uint8Array([0,1,255]))}
        else if(step===1){if(!(e.data instanceof ArrayBuffer)||new Uint8Array(e.data).join()!=='0,1,255')return reject(Error('arraybuffer'));step++;ws.binaryType='blob';ws.send(new Blob([new Uint8Array([7,8])]))}
        else{if(!(e.data instanceof Blob)||new Uint8Array(await e.data.arrayBuffer()).join()!=='7,8')return reject(Error('blob'));resolve('hello:binary:blob');ws.close(3001,'done')}};
      ws.onerror=()=>reject(Error('socket failed'))});
    window.sandbox=Promise.all([
      fetch('https://example.invalid/').then(()=>false,()=>true),
      fetch('ko://pane_999/').then(()=>false,()=>true)
    ]).then(blocked=>({https:blocked[0],otherFetch:blocked[1],
      popup:window.open('ko://'+location.host+'/')===null,
      otherSocket:(()=>{try{new WebSocket('ko://pane_999/');return false}catch{return true}})()}));
    Promise.all([echo,sandbox]).then(()=>ready=true,e=>{window.failure=String(e)});
    </script></body></html>
    """#
}

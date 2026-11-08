import Foundation
import Network
import CryptoKit

final class WebviewToy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "webview-toy")
    private var connections: [NWConnection] = []
    private var starting: CheckedContinuation<Void, Error>?
    private var delayed: [NWConnection] = []
    private var opened = Set<ObjectIdentifier>()
    private var eventStream: NWConnection?

    func writeLaterRecord() {
        queue.async { [self] in
            guard let eventStream else { return }
            eventStream.send(content: Self.chunk(96), completion: .contentProcessed { _ in })
        }
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
            if text.hasPrefix("GET /events ") {
                eventStream = connection
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                    if error == nil { self?.events(connection, 0) }
                })
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

    private static func chunk(_ index: Int) -> Data {
        let record = "{\"record\":\(index)}\n"
        return Data("\(String(record.utf8.count, radix: 16))\r\n\(record)\r\n".utf8)
    }

    private func events(_ connection: NWConnection, _ index: Int) {
        guard index < 96 else { return }
        let gap = [0, 2, 0, 7, 1][index % 5]
        queue.asyncAfter(deadline: .now() + .milliseconds(gap)) { [weak self] in
            connection.send(content: Self.chunk(index), completion: .contentProcessed { [weak self] error in
                if error == nil { self?.events(connection, index + 1) }
            })
        }
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

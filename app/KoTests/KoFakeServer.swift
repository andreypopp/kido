import Darwin
import CryptoKit
import Foundation

final class KoFakeServer: @unchecked Sendable {
    private let listener: Int32
    let socket: String

    init(directory: String, version: String?, refusal: String? = nil) throws {
        socket = directory + "/socket"
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { path in
            socket.utf8CString.withUnsafeBytes { path.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let fields = try version.map { try JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }
        let listener = listener
        Thread.detachNewThread {
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 { return }
                guard version != nil || refusal != nil else { continue }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var request = [UInt8](repeating: 0, count: 4096)
                let count = read(connection, &request, request.count)
                let lines = String(decoding: request.prefix(max(count, 0)), as: UTF8.self).components(separatedBy: "\r\n")
                let head = lines.joined(separator: "\r\n").lowercased()
                if let refusal {
                    guard head.hasPrefix("get /client ") else { close(connection); continue }
                    let key = lines.first { $0.lowercased().hasPrefix("sec-websocket-key:") }?.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) ?? ""
                    let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                    let upgrade = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                    _ = write(connection, upgrade, upgrade.utf8.count)
                    _ = read(connection, &request, request.count)
                    let body = try! JSONEncoder().encode(["type": "refused", "message": refusal])
                    precondition(body.count < 126)
                    let frame = Data([0x81, UInt8(body.count)]) + body
                    frame.withUnsafeBytes { _ = write(connection, $0.baseAddress, $0.count) }
                    close(connection)
                    continue
                }
                guard let version, var mismatch = fields else { close(connection); continue }
                let discovery = head.hasPrefix("get /version ") && !head.contains("\r\nko-protocol:") && !head.contains("\r\nko-vt:")
                let supplied = head.components(separatedBy: "\r\n").first { $0.hasPrefix("ko-protocol:") }?.dropFirst("ko-protocol:".count).trimmingCharacters(in: .whitespaces)
                let protocolMismatch = supplied?.split(separator: ".").first != mismatch["protocol"]?.split(separator: ".").first
                mismatch["kind"] = protocolMismatch ? "protocol_mismatch" : "vt_mismatch"
                mismatch["message"] = protocolMismatch ? "protocol major mismatch" : "terminal revision mismatch"
                let body = discovery ? version : String(decoding: (try? JSONEncoder().encode(mismatch)) ?? Data(), as: UTF8.self)
                let status = discovery ? "200 OK" : protocolMismatch ? "426 Upgrade Required" : "409 Conflict"
                let reply = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                _ = write(connection, reply, reply.utf8.count)
                close(connection)
            }
        }
    }

    func stop() {
        close(listener)
    }
}

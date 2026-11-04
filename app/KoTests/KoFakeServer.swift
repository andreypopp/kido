import Darwin
import Foundation

final class KoFakeServer: @unchecked Sendable {
    private let listener: Int32
    let socket: String

    init(directory: String, version: String?) throws {
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
                guard let version, var mismatch = fields else { continue }
                var request = [UInt8](repeating: 0, count: 4096)
                let count = read(connection, &request, request.count)
                let head = String(decoding: request.prefix(max(count, 0)), as: UTF8.self).lowercased()
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

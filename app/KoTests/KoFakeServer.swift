import Darwin
import Foundation

// A socket that answers GET /version with a fixed body and every other request with 426. Without
// a version it accepts connections and never answers.
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
        let listener = listener
        Thread.detachNewThread {
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 { return }
                guard let version else { continue }
                var request = [UInt8](repeating: 0, count: 4096)
                let count = read(connection, &request, request.count)
                let head = String(decoding: request.prefix(max(count, 0)), as: UTF8.self)
                let reply = head.hasPrefix("GET /version ")
                    ? "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(version.utf8.count)\r\n\r\n\(version)"
                    : "HTTP/1.1 426 Upgrade Required\r\nContent-Length: 0\r\n\r\n"
                _ = write(connection, reply, reply.utf8.count)
                close(connection)
            }
        }
    }

    func stop() {
        close(listener)
    }
}

import Foundation
import GhosttyKit
import KoClient

// Why a remote host is not connected, with the text of its banner.
enum RemoteFailure: Error {
    case ssh(Failure)
    case noKo(String)
    case noServer(String)
    case start(String)
    case refused(String)
    case badSocket(String)
    case mismatch(code: ko_code, server: KoVersion)

    func banner(_ host: String) -> (title: String, detail: String) {
        switch self {
        case .ssh(let failure): ("Kido could not reach \(host)", failure.message)
        case .noKo(let text): ("ko is not installed on \(host)", text)
        case .noServer(let text): ("No ko server is running on \(host)", text)
        case .start(let text): ("Could not start the ko server on \(host)", text)
        case .refused(let text): ("\(host) refuses unix-socket forwarding", text)
        case .badSocket(let text): ("Kido could not find the ko socket on \(host)", text)
        case .mismatch: ("Disconnected from \(host)", "")
        }
    }
}

extension SSH {
    private func sshFailing<T>(_ work: () async throws(Failure) -> T) async throws(RemoteFailure) -> T {
        do { return try await work() } catch { throw .ssh(error) }
    }

    private func passed(_ arguments: [String], drain: Drain) async throws(RemoteFailure) -> Child.Finished {
        let launch = launch(arguments)
        return try await sshFailing { () async throws(Failure) -> Child.Finished in try await Child.run(launch, deadline: 20, drain: drain) }
    }

    // The connect sequence of a remote host: the master, the remote socket, the forward, the agent link and the
    // version probe. Returns the resolved user@host and the local socket of the forward.
    func open(drain: Drain, onLoss: @escaping (Failure) -> Void) async throws(RemoteFailure) -> (identity: String, socket: String) {
        let identity = try await sshFailing { () async throws(Failure) -> String in try await start(drain: drain, onLoss: onLoss) }
        try await ensure(drain: drain)
        mark("query")
        publishAgent(drain: drain)
        let socket = directory + "/socket"
        let probe = await Task.detached { KoClient.probe(socket: socket, within: 20) }.value
        mark("probe")
        switch probe {
        case .compatible: return (identity, socket)
        case .mismatch(let code, let server): throw .mismatch(code: code, server: server)
        case .unreachable:
            let api = try await passed(["ko", "api", "--server", remoteDir ?? "", "/version"], drain: drain)
            let error = KoClient.unreachable(host: destination, remoteAnswers: api.status == 0)
            throw api.status == 0 ? .refused(error.detail) : .noServer(error.detail)
        }
    }

    func ensure(drain: Drain) async throws(RemoteFailure) {
        let query = try await passed(["ko", "server", "--print-socket", "--ensure"], drain: drain)
        switch KoClient.remoteSocket(host: destination, status: query.status, signaled: query.signaled, stdout: query.out, stderr: query.err) {
        case .success(let socket): remoteSocket = socket
        case .failure(let error) where error.code == KO_ERR_NOT_FOUND: throw .noKo(error.detail)
        case .failure(let error) where error.code == KO_ERR_IO: throw .ssh(Failure.ssh(error.detail))
        case .failure(let error):
            throw query.status != 0 ? .start(error.detail) : .badSocket(error.detail)
        }
        try await sshFailing { () async throws(Failure) -> Void in try await forward(drain: drain) }
    }
}

import Foundation

@MainActor final class PairingSession {
    enum State {
        case editing
        case submitting(ServerName)
        case waiting(ServerName)
        case retryable(PairingCode, DeviceName, String)
        case uncertain(ServerName)
        case rejected(String)
        case activationFailed(String)
        case complete
    }
    private(set) var state: State = .editing { didSet { changed?() } }
    var changed: (() -> Void)?
    var committed: (ServerName) -> Void = { _ in }
    enum ProbeResult { case ready, noServer, identity, serverCertificate(String) }
    enum ActivationResult: Equatable { case ready, timedOut, serverCertificate(String) }
    var probe: (ServerName, ServerIdentity, Duration) async -> ProbeResult = { _, _, _ in .noServer }
    var activated: (ServerName) -> Void = { _ in }

    static func activate(host: ServerName, identity: ServerIdentity,
                         probe: (ServerName, ServerIdentity, Duration) async -> ProbeResult,
                         now: () -> ContinuousClock.Instant = { .now },
                         wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> ActivationResult {
        let deadline = now().advanced(by: .seconds(30))
        while now() < deadline {
            let start = now()
            switch await probe(host, identity, min(.seconds(1), start.duration(to: deadline))) {
            case .ready: return .ready
            case .serverCertificate(let reason): return .serverCertificate(reason)
            case .noServer, .identity: break
            }
            let next = min(deadline, start.advanced(by: .seconds(1)))
            if now() < next { do { try await wait(now().duration(to: next)) } catch { return .timedOut } }
        }
        return .timedOut
    }
    private let store: IdentityStore
    let expectedHost: ServerName?
    private let claim: (Data) -> Bool
    private let release: (Data) -> Void
    private let enroll: (PairingCode, EnrollmentRequest, Data) async throws -> EnrollmentResult
    init(store: IdentityStore, expectedHost: ServerName?,
         claim: @escaping (Data) -> Bool, release: @escaping (Data) -> Void,
         enroll: @escaping (PairingCode, EnrollmentRequest, Data) async throws -> EnrollmentResult = { try await EnrollmentTransport.send(code: $0, request: $1, certificate: $2) }) {
        self.store = store; self.expectedHost = expectedHost; self.enroll = enroll
        self.claim = claim; self.release = release
    }

    var inert: Bool {
        switch state { case .submitting, .waiting, .uncertain, .activationFailed, .complete: true; default: false }
    }

    func submit(_ text: String, name: String) {
        guard !inert else { return }
        let code: PairingCode
        do { code = try PairingCode(text, expectedHost: expectedHost) }
        catch { state = .rejected("Not a pairing code"); return }
        let deviceName: DeviceName
        do { deviceName = try DeviceName(name.isEmpty ? Foundation.Host.current().localizedName ?? "Mac" : name) }
        catch { state = .rejected((error as? Failure)?.message ?? error.localizedDescription); return }
        prepare(code, deviceName)
    }

    func edited() {
        switch state { case .editing, .rejected, .retryable: state = .editing; default: break }
    }

    private func prepare(_ code: PairingCode, _ deviceName: DeviceName) {
        guard claim(code.tokenHash) else { state = .rejected("This code is used or expired. Run the pairing command again."); return }
        state = .submitting(code.host)
        Task {
            do {
                let store = store
                let prepared = try await Task.detached {
                    let identity = try store.create()
                    let signature = try identity.sign(enrollmentMessage(token: code.token, certificateDER: identity.certificate))
                    let request = try EnrollmentRequest(code: code, name: deviceName, certificate: identity.certificate, signature: signature)
                    return (request, identity)
                }.value
                await send(code, prepared.0, prepared.1, deviceName)
            } catch { release(code.tokenHash); state = .rejected((error as? Failure)?.message ?? error.localizedDescription) }
        }
    }

    func retrySend() {
        guard case .retryable(let code, let name, _) = state else { return }
        prepare(code, name)
    }

    private func send(_ code: PairingCode, _ request: EnrollmentRequest, _ identity: ServerIdentity, _ name: DeviceName) async {
        do {
            let result = try await enroll(code, request, identity.certificate)
            switch result {
            case .retryable(let message):
                release(code.tokenHash)
                state = .retryable(code, name, message)
            case .rejected(let status):
                state = .rejected(status == 403 ? "This code is used or expired. Run the pairing command again." : "The server refused this pairing. Run the pairing command again.")
            case .accepted, .uncertain:
                let store = store
                try await Task.detached { try store.commit(identity, for: code.host) }.value
                committed(code.host)
                if result == .uncertain { state = .uncertain(code.host) }
                else {
                    state = .waiting(code.host)
                    switch await Self.activate(host: code.host, identity: identity, probe: probe) {
                    case .ready: state = .complete; activated(code.host)
                    case .timedOut: state = .activationFailed("Could not reach \(code.host.value); try Connect.")
                    case .serverCertificate(let message): state = .activationFailed(message)
                    }
                }
            }
        } catch { state = .rejected((error as? Failure)?.message ?? error.localizedDescription) }
    }
}


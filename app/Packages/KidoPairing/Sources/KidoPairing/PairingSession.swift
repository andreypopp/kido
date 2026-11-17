import Foundation

@MainActor public final class PairingSession {
    public enum Rejection: Equatable, Sendable {
        case invalidCode, usedOrExpired, refused(status: Int), invalidDeviceName, failed(PairingFailure)
    }
    public enum ActivationFailure: Equatable, Sendable {
        case timedOut, serverCertificate(String)
    }
    public enum State {
        case editing
        case submitting(PairingCode)
        case waiting(PairingCode)
        case retryable(PairingCode, PairingName, String)
        case uncertain(PairingCode)
        case rejected(Rejection)
        case activationFailed(PairingCode, ActivationFailure)
        case complete
    }
    public private(set) var state: State = .editing { didSet { changed?() } }
    public var changed: (() -> Void)?
    public var committed: (ServerName) -> Void = { _ in }
    public enum ProbeResult { case ready, noServer, identity, serverCertificate(String) }
    enum ActivationResult: Equatable { case ready, failed(ActivationFailure) }
    public var probe: (ServerName, ServerIdentity, Duration) async -> ProbeResult = { _, _, _ in .noServer }
    public var activated: (ServerName) -> Void = { _ in }

    static func activate(host: ServerName, identity: ServerIdentity,
                         probe: (ServerName, ServerIdentity, Duration) async -> ProbeResult,
                         now: () -> ContinuousClock.Instant = { .now },
                         wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> ActivationResult {
        let deadline = now().advanced(by: .seconds(30))
        while now() < deadline {
            let start = now()
            switch await probe(host, identity, min(.seconds(1), start.duration(to: deadline))) {
            case .ready: return .ready
            case .serverCertificate(let reason): return .failed(.serverCertificate(reason))
            case .noServer, .identity: break
            }
            let next = min(deadline, start.advanced(by: .seconds(1)))
            if now() < next { do { try await wait(now().duration(to: next)) } catch { return .failed(.timedOut) } }
        }
        return .failed(.timedOut)
    }
    private let defaultDeviceName: String
    private let store: IdentityStore
    public let expectedHost: ServerName?
    private let claim: (Data) -> Bool
    private let release: (Data) -> Void
    private let enroll: (PairingCode, EnrollmentRequest, Data) async throws -> EnrollmentResult
    public convenience init(store: IdentityStore, expectedHost: ServerName?, defaultDeviceName: String,
                            claim: @escaping (Data) -> Bool, release: @escaping (Data) -> Void) {
        self.init(store: store, expectedHost: expectedHost, defaultDeviceName: defaultDeviceName,
                  claim: claim, release: release,
                  enroll: { try await EnrollmentTransport.send(code: $0, request: $1, certificate: $2) })
    }

    init(store: IdentityStore, expectedHost: ServerName?, defaultDeviceName: String,
         claim: @escaping (Data) -> Bool, release: @escaping (Data) -> Void,
         enroll: @escaping (PairingCode, EnrollmentRequest, Data) async throws -> EnrollmentResult) {
        self.defaultDeviceName = defaultDeviceName
        self.store = store; self.expectedHost = expectedHost; self.enroll = enroll
        self.claim = claim; self.release = release
    }

    public var inert: Bool {
        switch state { case .submitting, .waiting, .uncertain, .activationFailed, .complete: true; default: false }
    }

    public func submit(_ text: String, name: String) {
        guard !inert else { return }
        let code: PairingCode
        do { code = try PairingCode(text, expectedHost: expectedHost) }
        catch { state = .rejected(.invalidCode); return }
        let deviceName: PairingName
        do { deviceName = try PairingName(name.isEmpty ? defaultDeviceName : name) }
        catch { state = .rejected(.invalidDeviceName); return }
        prepare(code, deviceName)
    }

    public func edited() {
        switch state { case .editing, .rejected, .retryable: state = .editing; default: break }
    }

    private func prepare(_ code: PairingCode, _ deviceName: PairingName) {
        guard claim(code.tokenHash) else { state = .rejected(.usedOrExpired); return }
        state = .submitting(code)
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
            } catch { release(code.tokenHash); state = .rejected(.failed(error as? PairingFailure ?? PairingFailure(message: error.localizedDescription))) }
        }
    }

    public func retrySend() {
        guard case .retryable(let code, let name, _) = state else { return }
        prepare(code, name)
    }

    private func send(_ code: PairingCode, _ request: EnrollmentRequest, _ identity: ServerIdentity, _ name: PairingName) async {
        do {
            let result = try await enroll(code, request, identity.certificate)
            switch result {
            case .retryable(let message):
                release(code.tokenHash)
                state = .retryable(code, name, message)
            case .rejected(let status):
                state = .rejected(status == 403 ? .usedOrExpired : .refused(status: status))
            case .accepted, .uncertain:
                let store = store
                try await Task.detached { try store.commit(identity, for: code.host, name: code.name) }.value
                committed(code.host)
                if result == .uncertain { state = .uncertain(code) }
                else {
                    state = .waiting(code)
                    switch await Self.activate(host: code.host, identity: identity, probe: probe) {
                    case .ready: state = .complete; activated(code.host)
                    case .failed(let reason): state = .activationFailed(code, reason)
                    }
                }
            }
        } catch { state = .rejected(.failed(error as? PairingFailure ?? PairingFailure(message: error.localizedDescription))) }
    }
}


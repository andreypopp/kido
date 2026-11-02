import Foundation
import KoClient

enum KoEvent: Equatable {
    case welcome(client: String, instance: String, now: UInt64)
    case layout(revision: UInt64, sessions: Int, windows: Int, panes: Int)
    case failed(code: ko_code, message: String)
}

@MainActor final class KoConnection {
    private let sink: (KoEvent) -> Void
    private var handle: OpaquePointer?
    private var user: Unmanaged<KoConnection>?

    init(socket: String, sink: @escaping (KoEvent) -> Void) throws {
        self.sink = sink
        let user = Unmanaged.passRetained(self)
        let code = ko_client_connect(socket, .main, { user, event in
            let connection = Unmanaged<KoConnection>.fromOpaque(user!).takeUnretainedValue()
            let event = KoEvent(event!.pointee)
            MainActor.assumeIsolated { connection.sink(event) }
        }, user.toOpaque(), &handle)
        guard code == KO_OK else {
            user.release()
            throw KoError(code: code)
        }
        self.user = user
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        ko_client_close(handle)
        user?.release()
        user = nil
    }
}

struct KoError: Error, CustomStringConvertible {
    let code: ko_code
    var description: String { String(cString: ko_code_message(Int32(code.rawValue))) }
}

private extension KoEvent {
    init(_ event: ko_event) {
        switch Int(event.kind) {
        case KO_EVENT_WELCOME:
            let welcome = event.welcome
            self = .welcome(client: String(cString: welcome.client), instance: String(cString: welcome.instance), now: welcome.now)
        case KO_EVENT_LAYOUT:
            let layout = event.layout
            self = .layout(revision: layout.revision, sessions: Int(layout.sessions), windows: Int(layout.windows), panes: Int(layout.panes))
        default:
            let failure = event.failure
            self = .failed(code: failure.code, message: String(cString: failure.message))
        }
    }
}

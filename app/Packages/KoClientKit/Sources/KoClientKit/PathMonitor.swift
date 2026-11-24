import Foundation
import Network

/// Reports a change of the network path to every client that the app registers, through
/// `KoClient.pathChanged()`. The first update after `start()` is the baseline and reports nothing.
/// Each later update with a satisfied path reports, also when only an address changed. An
/// unsatisfied update reports nothing: the clients keep their connections and their own reconnect.
/// The monitor holds its clients weakly; a process needs one monitor. An iOS app also calls
/// `pathChanged()` on each client when it becomes active, because the path can change while the
/// app is suspended.
@MainActor public final class PathMonitor {
    private let monitor = NWPathMonitor()
    private let clients = NSHashTable<KoClient>.weakObjects()
    private var baseline = false
    private var lastWake: ContinuousClock.Instant?
    private let onHint: (String) -> Void

    public init(onHint: @escaping (String) -> Void = { _ in }) { self.onHint = onHint }

    public func wake() { wake(at: .now) }

    func wake(at now: ContinuousClock.Instant) {
        if let lastWake, now - lastWake < .seconds(2) { return }
        lastWake = now
        onHint("wake: network path hint sent")
        for client in clients.allObjects { client.pathChanged() }
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            MainActor.assumeIsolated { self?.update(satisfied: satisfied) }
        }
        monitor.start(queue: .main)
    }

    public func register(_ client: KoClient) { clients.add(client) }

    public func unregister(_ client: KoClient) { clients.remove(client) }

    func update(satisfied: Bool) {
        let first = !baseline
        baseline = true
        guard !first, satisfied else { return }
        onHint("NWPathMonitor: network path hint sent")
        for client in clients.allObjects { client.pathChanged() }
    }
}

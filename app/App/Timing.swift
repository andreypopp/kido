import Foundation
import KoModel

// KIDO_APP_TIMING=1: one JSON line on stderr for each measured event, for app/scripts/rtt.py.
enum Timing {
    static let enabled = ProcessInfo.processInfo.environment["KIDO_APP_TIMING"] == "1"
    private static let lock = NSLock()

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    static func emit(_ fields: [String: Any]) {
        guard enabled, let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) else { return }
        lock.withLock { FileHandle.standardError.write(data + Data("\n".utf8)) }
    }
}

#if KIDO_VISUAL || KIDO_STRESS
// KIDO_APP_RTT_REQUESTS=<file>: a file {"pane", "keys", "interval_ms"} that rtt.py renames into place makes the app
// type that many keys into the pane of the first remote window; each key's echo is timed by KoView.
@MainActor final class RTTDriver {
    private let path: String
    private let owner: () -> WindowOwner?
    private var timer: DispatchSourceTimer?
    private var sending: DispatchSourceTimer?

    init(path: String, owner: @escaping () -> WindowOwner?) {
        self.path = path
        self.owner = owner
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.poll() } }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard sending == nil, let data = FileManager.default.contents(atPath: path),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = request["pane"] as? String, let pane = PaneID(ko: name),
              let keys = request["keys"] as? Int, let interval = request["interval_ms"] as? Int,
              let view = owner()?.testSession?.pane(pane)?.koView else { return }
        try? FileManager.default.removeItem(atPath: path)
        var sent = 0
        let sender = DispatchSource.makeTimerSource(queue: .main)
        sender.schedule(deadline: .now(), repeating: .milliseconds(interval))
        sender.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                try? view.text(Data("k".utf8))
                sent += 1
                if sent >= keys {
                    self?.sending?.cancel()
                    self?.sending = nil
                }
            }
        }
        sender.resume()
        sending = sender
    }
}
#endif

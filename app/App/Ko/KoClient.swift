import Foundation
import GhosttyKit
import KoClient
import KoClientKit
import KoModel

extension KoSchema.Version {
    var major: Int? { `protocol`.split(separator: ".").first.flatMap { Int($0) } }
}

// The core's restore results and Ghostty's, matched by name. ko_restore_result is a closed C enum,
// so a new case stops the compile here; Ghostty's is an open one, so a new case traps.
private func koResult(_ result: ghostty_snapshot_restore_result_e) -> Int32 {
    switch result {
    case GHOSTTY_SNAPSHOT_RESTORE_OK: Int32(ko_restore_result.KO_RESTORE_OK.rawValue)
    case GHOSTTY_SNAPSHOT_RESTORE_REJECTED: Int32(ko_restore_result.KO_RESTORE_REJECTED.rawValue)
    case GHOSTTY_SNAPSHOT_RESTORE_HISTORY_INCOMPLETE: Int32(ko_restore_result.KO_RESTORE_HISTORY_INCOMPLETE.rawValue)
    default: preconditionFailure("unknown restore result \(result.rawValue)")
    }
}

private func ghosttyResult(_ result: ko_restore_result) -> ghostty_snapshot_restore_result_e {
    switch result {
    case .KO_RESTORE_OK: GHOSTTY_SNAPSHOT_RESTORE_OK
    case .KO_RESTORE_REJECTED: GHOSTTY_SNAPSHOT_RESTORE_REJECTED
    case .KO_RESTORE_HISTORY_INCOMPLETE: GHOSTTY_SNAPSHOT_RESTORE_HISTORY_INCOMPLETE
    }
}

enum KoViewEvent: Equatable {
    case restored(generation: UInt64, result: ghostty_snapshot_restore_result_e)
    case closed(code: ko_code, message: String)
    case link(code: ko_code, message: String)
}

// What a failure says to the user: the server's text when it gave one.
func failureText(_ error: Error) -> String {
    guard let error = error as? KoError else { return "\(error)" }
    return error.detail.isEmpty ? "\(error)" : error.detail
}

private func check(_ code: ko_code) throws {
    guard code == KO_OK else { throw KoError(code: code) }
}

extension KoClient {
    static func connect(socket: String, hello: KoHello = KoHello(), fetches: Int = 8, sink: @escaping (KoEvent) -> Void) throws -> KoClient {
        try KoClient(socket: socket, hello: hello, fetches: fetches) { event in
            switch event {
            case .viewRestored(let view, let generation, let result):
                KoView.of(view).sink(.restored(generation: generation, result: ghosttyResult(result)))
            case .viewClosed(let view, let code, let message):
                KoView.of(view).sink(.closed(code: code, message: message))
            case .viewLink(let view, let code, let message):
                KoView.of(view).sink(.link(code: code, message: message))
            default:
                sink(event)
            }
        }
    }

    nonisolated static func defaultDir() -> String {
        do {
            return try defaultDirectory()
        } catch {
            fatalError("Kido cannot resolve ko's server directory: \(error)")
        }
    }

    @discardableResult func select<Kind>(_ kind: Int, _ id: ID<Kind>) throws -> UInt64 {
        let request = try selectRequest(kind, id)
        note("selection sent kind=\(kind) id=\(id)")
        return request
    }

    @discardableResult func switchOver(_ over: Int, _ direction: Int) throws -> UInt64 {
        let request = try switchRequest(over, direction)
        note("selection switch sent over=\(over) direction=\(direction)")
        return request
    }

    func openView(pane: PaneID, history: Bool = true, surface: ghostty_surface_t, hooks: KoViewHooks = KoViewHooks(), sink: @escaping @MainActor (KoViewEvent) -> Void) throws -> KoView {
        var limits = ko_limits()
        try check(withHandle { ko_client_limits($0, &limits) })
        let scrollback: KoScrollback = limits.scrollback.kind == KO_SCROLLBACK_DISABLED ? .disabled
            : .bounded(bytes: limits.scrollback.max_bytes == 0 ? nil : UInt(limits.scrollback.max_bytes), lines: limits.scrollback.max_lines == 0 ? nil : UInt(limits.scrollback.max_lines))
        let view = KoView(surface: surface, scrollback: scrollback, hooks: hooks, sink: sink)
        view.label = pane.description
        let user = Unmanaged.passRetained(view)
        let code = (try? withHandle { ko_view_open($0, pane.description, history, KoView.restoreCallback, KoView.feedCallback, user.toOpaque(), &view.handle) }) ?? KO_ERR_CLOSED
        guard code == KO_OK else {
            user.release()
            throw KoError(code: code)
        }
        view.user = user
        return view
    }
}

private enum KoScrollback: Sendable {
    case disabled
    case bounded(bytes: UInt?, lines: UInt?)

    func apply(to surface: ghostty_surface_t) {
        switch self {
        case .disabled:
            ghostty_surface_set_scrollback_limits(surface, false, 0, 0)
        case .bounded(let bytes, let lines):
            ghostty_surface_set_scrollback_limits(surface, true, bytes ?? 0, lines ?? 0)
        }
    }
}

// The closures run on the decoder thread: `bytes` takes the pty output in place of the surface's
// process_output; `afterFeed` runs after each feed and `afterRestore` after each restore. In test builds,
// continuationOverride replaces the server's limit and beforeRestore sees each snapshot.
struct KoViewHooks: Sendable {
    var bytes: (@Sendable (UnsafeRawBufferPointer) -> Void)?
    var afterFeed: (@Sendable (ko_feed) -> Void)?
    var afterRestore: (@Sendable (Int32) -> Void)?
    #if KIDO_VISUAL || KIDO_STRESS
    var beforeRestore: (@Sendable (ko_snapshot) -> Void)?
    var continuationOverride: Int?
    #endif
}

// One pane's view, feeding a Ghostty surface of the app's fork. The core calls the
// restore and the feed on the view's decoder thread, in the server's order, so the
// surface never takes bytes of an older snapshot after a newer restore.
final class KoView: @unchecked Sendable {
    nonisolated(unsafe) fileprivate(set) var handle: OpaquePointer?
    fileprivate var user: Unmanaged<KoView>?
    let surface: ghostty_surface_t
    @MainActor let sink: @MainActor (KoViewEvent) -> Void
    private let hooks: KoViewHooks
    private let scrollback: KoScrollback
    fileprivate var label = ""
    fileprivate let opened = ContinuousClock.now
    private let inputStamp = NSLock()
    private var inputAt: ContinuousClock.Instant?

    @MainActor fileprivate init(surface: ghostty_surface_t, scrollback: KoScrollback, hooks: KoViewHooks, sink: @escaping @MainActor (KoViewEvent) -> Void) {
        self.surface = surface
        self.hooks = hooks
        self.scrollback = scrollback
        self.sink = sink
    }

    @MainActor fileprivate static func of(_ pointer: UnsafeMutableRawPointer?) -> KoView {
        Unmanaged<KoView>.fromOpaque(pointer!).takeUnretainedValue()
    }

    // Not main-actor isolated: the core calls these on the view's decoder thread.
    fileprivate static let restoreCallback: ko_restore_fn = { user, snapshot in
        Unmanaged<KoView>.fromOpaque(user!).takeUnretainedValue().restore(snapshot!.pointee)
    }

    fileprivate static let feedCallback: ko_feed_fn = { user, feed in
        Unmanaged<KoView>.fromOpaque(user!).takeUnretainedValue().feed(feed!.pointee)
    }

    fileprivate func restore(_ snapshot: ko_snapshot) -> Int32 {
        var limit = snapshot.continuation_max_bytes
        #if KIDO_VISUAL || KIDO_STRESS
        hooks.beforeRestore?(snapshot)
        limit = hooks.continuationOverride ?? limit
        #endif
        let result = Timing.enabled ? timedRestore(snapshot, limit) : koResult(ghostty_surface_restore_snapshot(surface, snapshot.read, snapshot.reader, snapshot.history, limit))
        // Snapshot restore carries dimension-adjusted limits, not the server policy.
        scrollback.apply(to: surface)
        hooks.afterRestore?(result)
        return result
    }

    fileprivate func feed(_ item: ko_feed) {
        switch Int(item.kind) {
        case KO_FEED_BYTES:
            guard let data = item.data else { break }
            if Timing.enabled, let start = takeInputStamp() {
                Timing.emit(["t": "echo", "pane": label, "ms": Timing.milliseconds(since: start)])
            }
            if let bytes = hooks.bytes { bytes(UnsafeRawBufferPointer(start: data, count: item.len)) }
            else { ghostty_surface_process_output(surface, UnsafeRawPointer(data).assumingMemoryBound(to: CChar.self), UInt(item.len)) }
        case KO_FEED_RESIZE:
            _ = ghostty_surface_set_grid_size(surface, item.cols, item.rows, nil)
        default:
            break
        }
        hooks.afterFeed?(item)
    }

    private func takeInputStamp() -> ContinuousClock.Instant? {
        inputStamp.withLock { defer { inputAt = nil }; return inputAt }
    }

    // Counts what the restore reads; the core calls the reads on the decoder thread that runs the restore.
    private final class CountingReader {
        let read: ko_read_fn
        let reader: UnsafeMutableRawPointer?
        let opened: ContinuousClock.Instant
        var bytes = 0
        var first: Double?
        init(read: ko_read_fn, reader: UnsafeMutableRawPointer?, opened: ContinuousClock.Instant) { self.read = read; self.reader = reader; self.opened = opened }
    }

    private func timedRestore(_ snapshot: ko_snapshot, _ limit: Int) -> Int32 {
        let counting = CountingReader(read: snapshot.read!, reader: snapshot.reader, opened: opened)
        let result = koResult(ghostty_surface_restore_snapshot(surface, { context, buffer, capacity, count in
            let counting = Unmanaged<CountingReader>.fromOpaque(context!).takeUnretainedValue()
            let more = counting.read(counting.reader, buffer, capacity, count)
            if more, let count {
                counting.bytes += count.pointee
                if counting.first == nil { counting.first = Timing.milliseconds(since: counting.opened) }
            }
            return more
        }, Unmanaged.passUnretained(counting).toOpaque(), snapshot.history, limit))
        var fields: [String: Any] = ["t": "restore", "pane": label, "bytes": counting.bytes, "total_ms": Timing.milliseconds(since: opened)]
        if let first = counting.first { fields["ready_ms"] = first }
        Timing.emit(fields)
        return result
    }

    func text(_ data: Data) throws {
        if Timing.enabled { inputStamp.withLock { if inputAt == nil { inputAt = .now } } }
        try check(data.withUnsafeBytes { ko_view_input(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }

    func resync(history: Bool = true) throws {
        try check(ko_view_resync(handle, history))
    }

    // It waits for a running restore or feed: call it off the main queue, once.
    func close() {
        guard let handle else { return }
        self.handle = nil
        ko_view_close(handle)
        user?.release()
        user = nil
    }
}


import Foundation
import GhosttyKit
import KoClient

enum KoEvent: Equatable {
    case welcome(client: String, instance: String, now: UInt64, fresh: Bool)
    case layout(revision: UInt64, sessions: Int, windows: Int, panes: Int)
    case failed(code: ko_code, message: String)
    case model
    case selected(session: String?, window: String?, pane: String?)
    case alert(kind: Int, pane: String, title: String?, body: String?)
}

enum KoViewEvent: Equatable {
    case restored(generation: UInt64, result: ghostty_snapshot_restore_result_e)
    case closed(code: ko_code, message: String)
}

// The text of the failing call when the core gave one: for KO_ERR_CONFLICT the newer layout document.
struct KoError: Error, CustomStringConvertible {
    let code: ko_code
    var detail = ""
    var description: String {
        let base = String(cString: ko_code_message(Int32(code.rawValue)))
        return detail.isEmpty ? base : "\(base): \(detail)"
    }
}

private func check(_ code: ko_code) throws {
    guard code == KO_OK else { throw KoError(code: code) }
}

// Takes the bytes of a buffer that the core filled, and frees it.
private func owned(_ buffer: inout ko_buffer) -> Data {
    defer { ko_buffer_free(&buffer) }
    guard let data = buffer.data else { return Data() }
    return Data(bytes: data, count: buffer.len)
}

private func take(_ code: ko_code, _ buffer: inout ko_buffer) throws -> Data {
    let data = owned(&buffer)
    guard code == KO_OK else { throw KoError(code: code, detail: String(decoding: data, as: UTF8.self)) }
    return data
}

private func optional(_ pointer: UnsafePointer<CChar>?) -> String? { pointer.map { String(cString: $0) } }

@MainActor final class KoConnection {
    private let sink: (KoEvent) -> Void
    // Read by the blocking calls on any thread; written by close, which waits for them in the core.
    nonisolated(unsafe) fileprivate(set) var handle: OpaquePointer?
    private var user: Unmanaged<KoConnection>?

    init(socket: String, hello: ko_hello = ko_hello(cols: 80, rows: 24, focused: false, sizes_windows: false), sink: @escaping (KoEvent) -> Void) throws {
        self.sink = sink
        let user = Unmanaged.passRetained(self)
        let code = withUnsafePointer(to: hello) { hello in
            ko_client_connect(socket, .main, { user, event in
                let connection = Unmanaged<KoConnection>.fromOpaque(user!).takeUnretainedValue()
                let event = event!.pointee
                MainActor.assumeIsolated { connection.deliver(event) }
            }, user.toOpaque(), hello, &handle)
        }
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

    private func deliver(_ event: ko_event) {
        switch Int(event.kind) {
        case KO_EVENT_WELCOME:
            let welcome = event.welcome
            sink(.welcome(client: String(cString: welcome.client), instance: String(cString: welcome.instance), now: welcome.now, fresh: welcome.fresh))
        case KO_EVENT_LAYOUT:
            let layout = event.layout
            sink(.layout(revision: layout.revision, sessions: Int(layout.sessions), windows: Int(layout.windows), panes: Int(layout.panes)))
        case KO_EVENT_MODEL:
            sink(.model)
        case KO_EVENT_SELECTED:
            let selected = event.selected
            sink(.selected(session: optional(selected.session), window: optional(selected.window), pane: optional(selected.pane)))
        case KO_EVENT_ALERT:
            let alert = event.alert
            sink(.alert(kind: Int(alert.kind), pane: String(cString: alert.pane), title: optional(alert.title), body: optional(alert.body)))
        case KO_EVENT_VIEW_RESTORED:
            let restored = event.view_restored
            KoView.of(restored.view).sink(.restored(generation: restored.generation, result: ghostty_snapshot_restore_result_e(UInt32(restored.result.rawValue))))
        case KO_EVENT_VIEW_CLOSED:
            let closed = event.view_closed
            KoView.of(closed.view).sink(.closed(code: closed.code, message: String(cString: closed.message)))
        default:
            sink(.failed(code: event.failure.code, message: String(cString: event.failure.message)))
        }
    }

    // The model as the core's JSON document. A snapshot: read it again after an event.
    func model() throws -> [String: Any] {
        var buffer = ko_buffer()
        let data = try take(ko_client_model(handle, &buffer), &buffer)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func select(_ kind: Int, _ id: String) throws {
        try check(ko_client_select(handle, Int32(kind), id))
    }

    func size(cols: Int, rows: Int) throws {
        try check(ko_client_size(handle, UInt16(cols), UInt16(rows)))
    }

    func focus(_ focused: Bool) throws {
        try check(ko_client_focus(handle, focused))
    }

    func observe(_ panes: [String], attending: Bool) throws {
        let pointers: [UnsafePointer<CChar>?] = panes.map { UnsafePointer(strdup($0)) }
        defer { pointers.forEach { $0.map { free(UnsafeMutablePointer(mutating: $0)) } } }
        try check(pointers.withUnsafeBufferPointer { ko_client_observe(handle, $0.baseAddress, $0.count, attending) })
    }

    // These three block until the server answers, so they are not main-actor calls:
    // run them off the main queue. A close on another thread ends them with KO_ERR_CLOSED.
    // putLayout sends once; KO_ERR_CONFLICT carries the newer document in `detail`.
    nonisolated func putLayout(_ document: String) throws -> Data {
        var buffer = ko_buffer()
        let bytes = Array(document.utf8)
        return try take(ko_client_put_layout(handle, bytes, bytes.count, &buffer), &buffer)
    }

    nonisolated func runs(_ show: Int) throws -> Data {
        var buffer = ko_buffer()
        return try take(ko_client_runs(handle, Int32(show), &buffer), &buffer)
    }

    nonisolated func prompt(_ target: String, _ text: String) throws -> Data {
        var buffer = ko_buffer()
        let bytes = Array(text.utf8)
        return try take(ko_client_prompt(handle, target, bytes, bytes.count, &buffer), &buffer)
    }

    func openView(pane: String, history: Bool = true, surface: ghostty_surface_t, hooks: KoViewHooks = KoViewHooks(), sink: @escaping @MainActor (KoViewEvent) -> Void) throws -> KoView {
        let view = KoView(surface: surface, hooks: hooks, sink: sink)
        let user = Unmanaged.passRetained(view)
        let code = ko_view_open(handle, pane, history, KoView.restoreCallback, KoView.feedCallback, user.toOpaque(), &view.handle)
        guard code == KO_OK else {
            user.release()
            throw KoError(code: code)
        }
        view.user = user
        return view
    }
}

// For tests: continuationOverride replaces the server's limit; the closures run on
// the decoder thread around the restore and after each feed.
struct KoViewHooks: Sendable {
    var continuationOverride: Int?
    var beforeRestore: (@Sendable (ko_snapshot) -> Void)?
    var afterRestore: (@Sendable (Int32) -> Void)?
    var afterFeed: (@Sendable (ko_feed) -> Void)?
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

    @MainActor fileprivate init(surface: ghostty_surface_t, hooks: KoViewHooks, sink: @escaping @MainActor (KoViewEvent) -> Void) {
        self.surface = surface
        self.hooks = hooks
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
        hooks.beforeRestore?(snapshot)
        let limit = hooks.continuationOverride ?? snapshot.continuation_max_bytes
        let result = Int32(ghostty_surface_restore_snapshot(surface, snapshot.read, snapshot.reader, snapshot.history, limit).rawValue)
        hooks.afterRestore?(result)
        return result
    }

    fileprivate func feed(_ item: ko_feed) {
        switch Int(item.kind) {
        case KO_FEED_BYTES:
            if let data = item.data {
                ghostty_surface_process_output(surface, UnsafeRawPointer(data).assumingMemoryBound(to: CChar.self), UInt(item.len))
            }
        case KO_FEED_RESIZE:
            _ = ghostty_surface_set_grid_size(surface, item.cols, item.rows, nil)
        default:
            break
        }
        hooks.afterFeed?(item)
    }

    func text(_ data: Data) throws {
        var input = ko_input()
        input.kind = Int32(KO_INPUT_TEXT)
        let code = data.withUnsafeBytes { raw -> ko_code in
            input.text = ko_text_input(data: raw.bindMemory(to: UInt8.self).baseAddress, len: raw.count)
            return ko_view_input(handle, &input)
        }
        try check(code)
    }

    func resync(history: Bool = true) throws {
        try check(ko_view_resync(handle, history))
    }

    @MainActor func close() {
        guard let handle else { return }
        self.handle = nil
        ko_view_close(handle)
        user?.release()
        user = nil
    }
}

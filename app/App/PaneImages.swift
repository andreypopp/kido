import Foundation
import GhosttyKit
import KoClient
import KoClientKit
import os

extension ghostty_surface_t {
    var kittyPendingFrames: [ghostty_kitty_pending_frame_s] {
        var count = 0
        ghostty_surface_kitty_pending_frames(self, nil, 0, &count)
        while true {
            var frames = [ghostty_kitty_pending_frame_s](repeating: ghostty_kitty_pending_frame_s(), count: count)
            var total = 0
            frames.withUnsafeMutableBufferPointer { ghostty_surface_kitty_pending_frames(self, $0.baseAddress, $0.count, &total) }
            if total <= count { return Array(frames.prefix(total)) }
            count = total
        }
    }
}

// Completes the Kitty image frames that a pane's mirror holds pending: each is fetched from the server by the
// stamp that the mirror gave it and attached to the surface. The surface refuses a stale stamp.
final class PaneImages: @unchecked Sendable {
    typealias Fetch = @Sendable (_ image: UInt32, _ frame: UInt32, _ generation: UInt64, _ acceptShm: Bool) throws -> KoImage

    struct Key: Hashable {
        let screen: UInt32
        let image: UInt32
        let frame: UInt32
        let generation: UInt64
    }

    private struct State {
        var seen: UInt64 = 0
        var known: Set<Key> = []
        var rescan = false
        var attempts: [Key: Int] = [:]
        var gone: Set<Key> = []
        var stopped = false
        var bodies: [Key: Data] = [:]
        var order: [Key] = []
        var bodyBytes = 0
        var gaveUp = false
    }

    static let retryDelays: [TimeInterval] = [0.25, 1, 4]
    static let bodyBudget = 16 << 20

    private let surface: ghostty_surface_t
    private let local: Bool
    private let fetches: OperationQueue
    private let fetch: Fetch
    private let retryDelays: [TimeInterval]
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let attaching = NSLock()

    init(surface: ghostty_surface_t, local: Bool, fetches: OperationQueue, retryDelays: [TimeInterval] = PaneImages.retryDelays, fetch: @escaping Fetch) {
        self.retryDelays = retryDelays
        self.surface = surface
        self.local = local
        self.fetches = fetches
        self.fetch = fetch
    }

    func surfaceChanged() {
        let generation = ghostty_surface_kitty_pending_generation(surface)
        guard state.withLock({ state in
            defer { state.seen = generation }
            return state.seen != generation && !state.stopped
        }) else { return }
        walk()
    }

    // A fetch that gave up during an outage is retried after the next welcome.
    func retry() {
        guard state.withLock({ state in defer { state.gaveUp = false }; return state.gaveUp && !state.stopped }) else { return }
        walk()
    }

    func stop() {
        attaching.lock()
        state.withLock { $0.stopped = true; $0.bodies = [:]; $0.order = [] }
        attaching.unlock()
    }

    private func walk() {
        let keys = surface.kittyPendingFrames.map { Key(screen: $0.screen.rawValue, image: $0.image_id, frame: $0.frame, generation: $0.generation) }
        let fresh = state.withLock { state -> [Key] in
            state.gone.formIntersection(keys)
            var fresh: [Key] = []
            for key in keys where !state.gone.contains(key) {
                if state.known.insert(key).inserted { fresh.append(key) } else { state.rescan = true }
            }
            return fresh
        }
        fresh.forEach { enqueue($0) }
    }

    private func enqueue(_ key: Key) {
        fetches.addOperation { self.run(key) }
    }

    private func run(_ key: Key) {
        guard !state.withLock({ $0.stopped }) else { return }
        let result = Result { try obtain(key) }
        let transient: Bool
        switch result {
        case .success(let image):
            apply(image, key)
            transient = false
        case .failure(let error):
            transient = (error as? KoError)?.code != KO_ERR_NOT_FOUND
            if !transient { state.withLock { _ = $0.gone.insert(key) } }
        }
        let retry = state.withLock { state -> TimeInterval? in
            if transient, !state.stopped, case let attempt = state.attempts[key, default: 0], attempt < retryDelays.count {
                state.attempts[key] = attempt + 1
                return retryDelays[attempt]
            }
            if transient { state.gaveUp = true }
            state.known.remove(key)
            state.attempts[key] = nil
            return nil
        }
        if let retry {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + retry) { self.enqueue(key) }
            return
        }
        if state.withLock({ state in defer { state.rescan = false }; return state.rescan && !state.stopped }) { walk() }
    }

    private func obtain(_ key: Key) throws -> KoImage {
        if !local, let cached = state.withLock({ $0.bodies[key] }) { return .body(cached) }
        let image = try fetch(key.image, key.frame, key.generation, local)
        if !local, case .body(let data) = image { remember(key, data) }
        return image
    }

    private func remember(_ key: Key, _ data: Data) {
        guard data.count <= Self.bodyBudget else { return }
        state.withLock { state in
            if let old = state.bodies.removeValue(forKey: key) {
                state.bodyBytes -= old.count
                state.order.removeAll { $0 == key }
            }
            state.bodies[key] = data
            state.order.append(key)
            state.bodyBytes += data.count
            while state.bodyBytes > Self.bodyBudget, let oldest = state.order.first {
                state.order.removeFirst()
                state.bodyBytes -= state.bodies.removeValue(forKey: oldest)?.count ?? 0
            }
        }
    }

    private func apply(_ image: KoImage, _ key: Key) {
        attaching.lock()
        defer { attaching.unlock() }
        guard !state.withLock({ $0.stopped }) else { return }
        let screen = ghostty_kitty_screen_e(rawValue: key.screen)
        switch image {
        case .body(let data):
            _ = data.withUnsafeBytes { bytes in
                ghostty_surface_kitty_frame_attach(surface, screen, key.image, key.frame, key.generation, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        case .shm(let name, let length):
            guard let mapping = Self.map(name, length: length) else { return }
            if ghostty_surface_kitty_frame_adopt(surface, screen, key.image, key.frame, key.generation, mapping.base, mapping.length, 0, length) != GHOSTTY_SUCCESS {
                munmap(mapping.base, mapping.length)
            }
        }
    }

    private static func map(_ name: String, length: Int) -> (base: UnsafeMutableRawPointer, length: Int)? {
        let descriptor = kido_shm_open_readonly(name)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Int(info.st_size) >= length, length > 0 else { return nil }
        let base = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, descriptor, 0)
        guard let base, base != MAP_FAILED else { return nil }
        return (base, Int(info.st_size))
    }
}

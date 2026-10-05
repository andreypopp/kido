import Foundation

final class Drain: @unchecked Sendable {
    let ended = DispatchGroup()
    private let lock = NSLock()
    private var closed = false

    init() { ended.enter() }

    func enter() throws(Failure) {
        let accepted = lock.withLock {
            guard !closed else { return false }
            ended.enter()
            return true
        }
        guard accepted else { throw Failure(message: "Connection closed before child launch") }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            ended.leave()
        }
    }
}

import GhosttyKit
import KoClient
import KoModel
import XCTest
@testable import Kido

// A pane whose program uploads a three-frame animation as t=s (the pane's terminal takes the objects),
// and edits frame 1 when the pane's input says "edit". The mirror refuses t=s, so every frame is pending
// until PaneImages fetches it.
@MainActor final class KoImageTests: KoTestCase {
    private static let program = """
    import _posixshmem, base64, mmap, os, sys, time
    count = 0
    def up(control, pixels):
        global count
        count += 1
        name = "/ko-kt-%d-%d" % (os.getpid() % 100000, count)
        descriptor = _posixshmem.shm_open(name, os.O_CREAT | os.O_EXCL | os.O_RDWR, mode=0o600)
        os.ftruncate(descriptor, len(pixels))
        memory = mmap.mmap(descriptor, len(pixels))
        memory[:] = pixels
        memory.close()
        os.close(descriptor)
        sys.stdout.write("\\x1b_G%s,t=s,f=32,s=1,v=1,q=2;%s\\x1b\\\\" % (control, base64.b64encode(name.encode()).decode()))
        sys.stdout.flush()
        time.sleep(0.3)
    up("a=T,i=1,c=1,r=1", bytes([255, 0, 0, 255]))
    up("a=f,i=1,z=40", bytes([0, 255, 0, 255]))
    up("a=f,i=1,z=40", bytes([0, 0, 255, 255]))
    sys.stdout.write("\\x1b_Ga=a,i=1,s=3,v=1,q=2\\x1b\\\\")
    sys.stdout.flush()
    for line in sys.stdin:
        if line.strip() == "edit":
            up("a=f,i=1,r=1", bytes([9, 9, 9, 255]))
    time.sleep(3600)
    """

    private struct Mirror {
        let surface: KoSurface
        let view: KoView
        let images: PaneImages
        let armed: Latch
        let fetched: Counter
        let recorder: Recorder
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var failures: Int
        init(failing: Int = 0) { failures = failing }
        var count: Int { lock.withLock { value } }
        func heal() { lock.withLock { failures = 0 } }
        func attempt() -> Bool {
            lock.withLock {
                value += 1
                guard failures > 0 else { return true }
                failures -= 1
                return false
            }
        }
    }

    private func pane() throws -> (dir: String, connection: KoClient, pane: PaneID, cols: Int, rows: Int) {
        let folder = try stateDir()
        let script = folder + "/images.py"
        try Self.program.write(toFile: script, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        let dir = try serverWithWindows([1], argv: ["/usr/bin/python3", "-I", script])
        let connection = try connect(dir, Recorder())
        let window = try XCTUnwrap(try connection.model().layout.layout.windows.first)
        guard case .leaf(let leaf) = window.tree else { throw XCTSkip("not a single pane window") }
        return (dir, connection, leaf.pane, leaf.cols, leaf.rows)
    }

    // A view of the pane on a new surface. Until `armed`, nothing fetches: the state of a mirror without PaneImages.
    private func mirror(_ pane: (dir: String, connection: KoClient, pane: PaneID, cols: Int, rows: Int), local: Bool, armed: Bool = true, failing: Int = 0, retries: [TimeInterval]? = nil) throws -> Mirror {
        let surface = KoSurface(cols: pane.cols, rows: pane.rows)
        let connection = pane.connection, id = pane.pane
        let fetched = Counter(failing: failing)
        let images = PaneImages(surface: surface.surface, local: local, fetches: connection.imageFetches, retryDelays: retries ?? PaneImages.retryDelays) { image, frame, generation, acceptShm in
            guard fetched.attempt() else { throw KoError(code: KO_ERR_IO) }
            return try connection.image(pane: id, image: image, frame: frame, generation: generation, acceptShm: acceptShm)
        }
        let latch = Latch()
        if armed { latch.set() }
        var hooks = KoViewHooks()
        hooks.afterFeed = { _ in if latch.isSet { images.surfaceChanged() } }
        hooks.afterRestore = { _ in if latch.isSet { images.surfaceChanged() } }
        let recorder = Recorder()
        let view = try connection.openView(pane: id, surface: surface.surface, hooks: hooks) { recorder.view.append($0) }
        addTeardownBlock { @MainActor in
            images.stop()
            view.close()
        }
        wait("the first restore") { !recorder.restored.isEmpty }
        return Mirror(surface: surface, view: view, images: images, armed: latch, fetched: fetched, recorder: recorder)
    }

    func testAMirrorWithoutPaneImagesHoldsEveryUploadedFrameAsPendingAndTheFetchCompletesThem() throws {
        let pane = try pane()
        let mirror = try mirror(pane, local: true, armed: false)
        wait("the three frames of the upload") { mirror.surface.pendingFrames.count == 3 }
        XCTAssertEqual(mirror.surface.pendingFrames.map(\.frame).sorted(), [1, 2, 3], "nothing completes a pending frame: the animation never plays")
        XCTAssertEqual(mirror.fetched.count, 0)

        mirror.armed.set()
        mirror.images.surfaceChanged()
        wait("every frame fetched and attached") { mirror.surface.pendingFrames.isEmpty }
        XCTAssertEqual(mirror.fetched.count, 3)
        for frame in 1...3 { XCTAssertNotNil(mirror.surface.generation(image: 1, frame: UInt32(frame))) }
    }

    func testTheFramesComeBackAfterACopyModeResyncAndAReconnect() throws {
        let pane = try pane()
        let first = try mirror(pane, local: true)
        wait("three frames adopted") { first.surface.pendingFrames.isEmpty && first.fetched.count == 3 }

        try first.view.resync()
        wait("the snapshot's frames adopted again") { first.fetched.count == 6 && first.surface.pendingFrames.isEmpty }

        first.images.stop()
        first.view.close()
        let second = try mirror(pane, local: true)
        wait("a new view's frames adopted") { second.fetched.count == 3 && second.surface.pendingFrames.isEmpty }
    }

    func testARemoteMirrorTakesTheBodiesAndKeepsThemAcrossAResync() throws {
        let pane = try pane()
        let mirror = try mirror(pane, local: false)
        wait("three bodies attached") { mirror.fetched.count == 3 && mirror.surface.pendingFrames.isEmpty }

        try mirror.view.resync()
        wait("the resync restored") { mirror.recorder.restored.count == 2 }
        wait("the bodies attached again") { mirror.surface.pendingFrames.isEmpty }
        XCTAssertEqual(mirror.fetched.count, 3, "the resync did not download the animation again")
    }

    func testAnEditOfAFrameMovesItsStampAndTheMirrorFetchesItAgain() throws {
        let pane = try pane()
        let mirror = try mirror(pane, local: true)
        wait("three frames adopted") { mirror.fetched.count == 3 && mirror.surface.pendingFrames.isEmpty }
        let before = try XCTUnwrap(mirror.surface.generation(image: 1, frame: 1))

        try mirror.view.text(Data("edit\n".utf8))
        wait("frame 1 fetched again under its new stamp") {
            mirror.fetched.count == 4 && mirror.surface.pendingFrames.isEmpty && mirror.surface.generation(image: 1, frame: 1) != before
        }
    }

    func testAFetchThatFailsOnceIsTriedAgainWithoutNewOutput() throws {
        let pane = try pane()
        let mirror = try mirror(pane, local: true, failing: 1)
        wait("every frame completed after the retry", within: 10) { mirror.fetched.count == 4 && mirror.surface.pendingFrames.isEmpty }
    }

    func testAFetchThatFailedWithoutRetriesLeftCompletesWhenTheNextWelcomeRetries() throws {
        let pane = try pane()
        let mirror = try mirror(pane, local: false, failing: 1000, retries: [])
        wait("the failed attempts") { mirror.fetched.count >= 3 && mirror.surface.pendingFrames.count == 3 }

        mirror.fetched.heal()
        mirror.images.retry()
        wait("the frames completed by the retry") { mirror.surface.pendingFrames.isEmpty }
    }
}

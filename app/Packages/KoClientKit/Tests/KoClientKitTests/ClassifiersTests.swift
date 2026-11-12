import KoClientKit
import XCTest

final class ClassifiersTests: XCTestCase {
    func testTheClassifiersOfTheSshStepsReachTheKitThroughTheCore() {
        func classify(_ status: Int32, signaled: Bool = false, _ out: String = "", _ err: String = "") -> Result<String, KoError> {
            KoClient.remoteSocket(host: "devbox", status: status, signaled: signaled, stdout: out, stderr: err)
        }
        XCTAssertEqual(try? classify(0, "/home/u/.local/state/ko/socket\n").get(), "/home/u/.local/state/ko/socket")
        XCTAssertEqual(classify(127, "", "env: ko: No such file").failure?.code, KO_ERR_NOT_FOUND)
        XCTAssertEqual(classify(255, "", "Permission denied (publickey)").failure?.code, KO_ERR_IO)
        XCTAssertEqual(classify(0, "banner\n").failure?.code, KO_ERR_INVALID)
        XCTAssertEqual(classify(9, signaled: true).failure?.code, KO_ERR_INVALID)
        XCTAssertEqual(KoClient.unreachable(host: "devbox", remoteAnswers: true).code, KO_ERR_REFUSED)
        XCTAssertEqual(KoClient.unreachable(host: "devbox", remoteAnswers: false).detail, "the ko server on devbox did not answer through the forward; reconnect")
        guard case .unreachable(let code, _) = KoClient.probe(socket: "/tmp/ko-kr-none/socket", within: 1) else { return XCTFail("a probe of no socket") }
        XCTAssertEqual(code, KO_ERR_NO_SERVER)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

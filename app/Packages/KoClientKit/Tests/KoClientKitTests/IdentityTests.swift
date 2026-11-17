@testable import KoClientKit
import XCTest

final class IdentityTests: XCTestCase {
    func testSignTrampoline() {
        enum Failure: Error { case signing }
        for (sign, expected) in [
            ({ @Sendable (_: Data) throws -> Data in throw Failure.signing }, Data()),
            ({ @Sendable (_: Data) throws -> Data in Data(repeating: 1, count: 73) }, Data()),
            ({ @Sendable (message: Data) throws -> Data in message }, Data([1, 2, 3]))
        ] {
            let signer = IdentitySigner(KoIdentity(certificate: Data(), sign: sign))
            let message: [UInt8] = [1, 2, 3]
            var output = [UInt8](repeating: 0, count: 72)
            let count = message.withUnsafeBufferPointer { message in
                output.withUnsafeMutableBufferPointer { output in
                    identitySign(Unmanaged.passUnretained(signer).toOpaque(), message.baseAddress, message.count, output.baseAddress, output.count)
                }
            }
            XCTAssertEqual(count, expected.count)
            XCTAssertEqual(Data(output.prefix(count)), expected)
        }
    }
}

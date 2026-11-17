public struct PairingFailure: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

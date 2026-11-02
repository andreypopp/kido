import Foundation

public struct ProgramStatus: Decodable, Equatable, Sendable {
    public struct Record: Decodable, Equatable, Sendable {
        public enum State: String, UnknownString, Sendable { case idle, working, done, blocked, error, unknown }
        public enum Kind: String, UnknownString, Sendable { case permission, question, auth, unknown }
        public let id: String
        public let state: State
        public let app: String?
        public let kind: Kind?
        public let progress: Int?
        public let title: String?
        public let msg: String?
    }
    public let serial: Int
    public let records: [Record]
}

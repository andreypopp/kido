import Foundation
import TmuxControl

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

public struct Ask: Decodable, Equatable, Sendable {
    public let id: String
    public let session: String
    public let name: String
    public let text: String
    public let created: Date
    public let pane: TmuxControl.PaneID?
    public let ended: Bool
    public let revivable: Bool
    private enum CodingKeys: String, CodingKey { case id, session, name, text, created, pane, ended, revivable }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        session = try c.decode(String.self, forKey: .session)
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        let timestamp = try c.decode(String.self, forKey: .created)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: timestamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: timestamp) else {
            throw DecodingError.dataCorruptedError(forKey: .created, in: c, debugDescription: "invalid ask timestamp")
        }
        created = date
        pane = try c.decodeIfPresent(TmuxControl.PaneID.self, forKey: .pane)
        ended = try c.decode(Bool.self, forKey: .ended)
        revivable = try c.decode(Bool.self, forKey: .revivable)
    }
}

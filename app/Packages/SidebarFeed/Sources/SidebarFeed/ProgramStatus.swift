import Foundation
import KoModel

public struct ProgramStatus: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public enum State: String, Sendable { case idle, working, done, blocked, error }
        public let id: String
        public let started: Int?
        public let state: State
        public let app: String?
        public let kind: KoSchema.ProgramKind?
        public let progress: Int?
        public let title: String?
        public let msg: String?
        public init(id: String, started: Int?, state: State, app: String?, kind: KoSchema.ProgramKind?, progress: Int?, title: String?, msg: String?) {
            self.started = started
            self.id = id
            self.state = state
            self.app = app
            self.kind = kind
            self.progress = progress
            self.title = title
            self.msg = msg
        }
    }
    public let serial: Int
    public let records: [Record]
    public init(serial: Int, records: [Record]) {
        self.serial = serial
        self.records = records
    }
}

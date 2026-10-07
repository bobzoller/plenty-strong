import Foundation
import SwiftData

@Model final class JournalRecord {
    #Index<JournalRecord>([\.programID, \.revision])
    @Attribute(.unique) var eventID: String
    var programID: String
    var revision: Int
    var bytes: Data
    var contentHash: String
    init(eventID: String, programID: String, revision: Int, bytes: Data, hash: String) {
        self.eventID = eventID; self.programID = programID; self.revision = revision; self.bytes = bytes; self.contentHash = hash
    }
}
@Model final class ProgramHeadRecord {
    @Attribute(.unique) var programID: String
    var revision: Int
    var bytes: Data
    var headHash: String
    var datasetID: String
    init(programID: String, revision: Int, bytes: Data, headHash: String, datasetID: String) {
        self.programID = programID; self.revision = revision; self.bytes = bytes; self.headHash = headHash; self.datasetID = datasetID
    }
}
@Model final class RuleArchiveRecord {
    @Attribute(.unique) var contentHash: String
    var bytes: Data
    init(hash: String, bytes: Data) { self.contentHash = hash; self.bytes = bytes }
}
@Model final class ProfileArchiveRecord {
    @Attribute(.unique) var contentHash: String
    var bytes: Data
    init(hash: String, bytes: Data) { self.contentHash = hash; self.bytes = bytes }
}
@Model final class DraftRecord {
    #Index<DraftRecord>([\.programID])
    @Attribute(.unique) var id: UUID
    var programID: String
    var bytes: Data
    init(id: UUID, programID: String, bytes: Data) { self.id = id; self.programID = programID; self.bytes = bytes }
}
@Model final class OutboxRecord {
    #Index<OutboxRecord>([\.datasetID])
    @Attribute(.unique) var key: String
    var datasetID: String
    var accountScope: String?
    var payloadHash: String
    var acknowledged: Bool
    init(key: String, datasetID: String, payloadHash: String) {
        self.key = key; self.datasetID = datasetID; self.payloadHash = payloadHash; self.acknowledged = false
    }
}
@Model final class CloudCursorRecord {
    @Attribute(.unique) var accountScope: String
    var bytes: Data
    init(accountScope: String, bytes: Data) { self.accountScope = accountScope; self.bytes = bytes }
}
@Model final class QuarantineRecord {
    @Attribute(.unique) var id: String
    var bytes: Data
    var reason: String
    init(id: String, bytes: Data, reason: String) { self.id = id; self.bytes = bytes; self.reason = reason }
}
enum TrainingSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [JournalRecord.self, ProgramHeadRecord.self, RuleArchiveRecord.self, ProfileArchiveRecord.self,
         DraftRecord.self, OutboxRecord.self, CloudCursorRecord.self, QuarantineRecord.self]
    }
}

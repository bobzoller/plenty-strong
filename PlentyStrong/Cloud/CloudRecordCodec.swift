import CloudKit
import Foundation
import TrainingCore

enum CloudRecordKind: String, Codable, Sendable { case journal, archive
    var recordType: String { self == .journal ? "JournalV1" : "ArchiveV1" }
}
enum CloudRecordCodec {
    // Conservative archived Apple bound, not an experimentally verified quota.
    static let maximumAssetBytes = 50_000_000
    static let zonePrefix = "PlentyStrong-v1-"
    static func recordName(kind: CloudRecordKind, datasetID: UUID, identity: String) throws -> String {
        try BackupService.hash([kind.rawValue, datasetID.uuidString.lowercased(), identity])
    }
    static func canonicalBytes(_ bytes: Data) throws -> Data {
        try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: bytes))
    }
    static func zoneID(_ datasetID: UUID) -> CKRecordZone.ID {
        .init(zoneName: zonePrefix + datasetID.uuidString.lowercased(), ownerName: CKCurrentUserDefaultName)
    }
    static func recordID(_ pending: PendingCloudRecord) -> CKRecord.ID {
        .init(recordName: pending.recordID, zoneID: zoneID(pending.datasetID))
    }
    /// Every attempted send uses a NEW record without a change tag. The retained
    /// server fields are evidence; applying them to saves could permit overwrites.
    static func makeRecord(_ pending: PendingCloudRecord, assetURL: URL) throws -> CKRecord {
        guard pending.payload.count <= maximumAssetBytes,
              BackupService.hash(pending.payload) == pending.checksum,
              try canonicalBytes(pending.payload) == pending.payload,
              try recordName(kind: pending.kind, datasetID: pending.datasetID, identity: pending.identity) == pending.recordID else {
            throw BackupService.invalid("cloud_payload")
        }
        try pending.payload.write(to: assetURL, options: .atomic)
        let record = CKRecord(recordType: pending.kind.recordType, recordID: recordID(pending))
        record["payload"] = CKAsset(fileURL: assetURL)
        record["checksum"] = pending.checksum as CKRecordValue
        record["datasetID"] = pending.datasetID.uuidString.lowercased() as CKRecordValue
        record["identity"] = pending.identity as CKRecordValue
        record["formatVersion"] = 1 as CKRecordValue
        return record
    }
    static func systemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder); coder.finishEncoding()
        return coder.encodedData
    }
    static func observation(_ record: CKRecord) throws -> CloudObservation {
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw BackupService.invalid("cloud_asset_missing") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximumAssetBytes + 1
        guard size <= maximumAssetBytes else { throw BackupService.invalid("cloud_asset_oversize") }
        return CloudObservation(recordID: record.recordID.recordName, zoneName: record.recordID.zoneID.zoneName,
            recordType: record.recordType, claimedChecksum: record["checksum"] as? String,
            payload: try Data(contentsOf: url), systemFields: systemFields(record))
    }
    static func matches(_ observation: CloudObservation, pending: PendingCloudRecord) -> Bool {
        observation.recordID == pending.recordID && observation.zoneName == zoneID(pending.datasetID).zoneName &&
        observation.recordType == pending.kind.recordType && observation.claimedChecksum == pending.checksum &&
        BackupService.hash(observation.payload) == pending.checksum && observation.payload == pending.payload
    }
    static func isWorkout(_ command: JournalCommand) -> Bool {
        if case .workout = command { return true }; return false
    }
    /// Enumerates checksum-valid roots without asserting causal acceptance.
    /// A future command/schema can still expose its dataset/program root; it is
    /// retained and reported unsupported instead of silently vanishing.
    static func recoveryCandidates(_ observations: [CloudObservation]) -> [RecoveryCandidate] {
        struct Root {
            let dataset: UUID
            let program: UUID
            let supported: Bool
        }
        var roots: [Root] = []
        var workouts: [String: Set<String>] = [:]
        for observation in observations {
            guard observation.recordType == CloudRecordKind.journal.recordType,
                  observation.claimedChecksum == BackupService.hash(observation.payload),
                  (try? canonicalBytes(observation.payload)) == observation.payload,
                  let fields = (try? JSONSerialization.jsonObject(with: observation.payload)) as? [String: Any],
                  let datasetText = fields["datasetId"] as? String, let dataset = UUID(uuidString: datasetText),
                  let programText = fields["programId"] as? String, let program = UUID(uuidString: programText),
                  let eventID = fields["eventId"] as? String,
                  observation.zoneName == zoneID(dataset).zoneName,
                  (try? recordName(kind: .journal, datasetID: dataset, identity: eventID)) == observation.recordID else { continue }
            let envelope = try? JSONDecoder().decode(JournalEnvelope.self, from: observation.payload)
            let supported = [1, 2].contains(fields["schemaVersion"] as? Int ?? -1) && envelope != nil
            let parentAbsent = fields["parentEnvelopeHash"] == nil || fields["parentEnvelopeHash"] is NSNull
            if parentAbsent { roots.append(Root(dataset: dataset, program: program, supported: supported)) }
            if let envelope, supported, isWorkout(envelope.command),
               (try? BackupService.envelopeHash(envelope)) == envelope.envelopeHash {
                workouts[dataset.uuidString + program.uuidString, default: []].insert(eventID)
            }
        }
        var candidates: [RecoveryCandidate] = []
        for root in roots {
            let candidate = RecoveryCandidate(datasetID: root.dataset, programID: root.program,
                knownCompletedWorkoutCount: workouts[root.dataset.uuidString + root.program.uuidString]?.count ?? 0,
                status: root.supported ? .incomplete : .unsupported)
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }
        return candidates.sorted { ($0.datasetID.uuidString, $0.programID.uuidString, $0.status.rawValue) < ($1.datasetID.uuidString, $1.programID.uuidString, $1.status.rawValue) }
    }
}

import Foundation
import TrainingCore

/// Portable integrity descriptor. Account identity and record system fields are
/// deliberately absent; the raw training payload is retained exactly as received.
struct ArchivedRecord: Codable, Equatable, Sendable {
    let recordID: String
    let zoneName: String
    let recordType: String
    let claimedChecksum: String?
    let bytes: Data
    init(observation: CloudObservation) {
        recordID = observation.recordID; zoneName = observation.zoneName; recordType = observation.recordType
        claimedChecksum = observation.claimedChecksum; bytes = observation.payload
    }
    var key: String { get throws { try BackupService.hash(self) } }
}
struct RecoveryQuarantine: Codable, Equatable, Sendable {
    let record: ArchivedRecord
    let reason: String
    let programID: String?
}
/// Only the verifier constructs a batch. The writer still re-verifies the union
/// with current durable originals, so an earlier proof cannot race local Finish.
struct VerifiedCloudBatch: Sendable {
    let originals: [ArchivedRecord]
    let envelopes: [String: JournalEnvelope]
    let rules: [ArchivedObject]
    let profiles: [ArchivedObject]
    let waiting: [ArchivedRecord]
    let quarantined: [RecoveryQuarantine]
    let conflictingRecordIDs: Set<String>
    let heads: [String: [String]]
    fileprivate init(originals: [ArchivedRecord], envelopes: [String: JournalEnvelope], rules: [ArchivedObject],
                     profiles: [ArchivedObject], waiting: [ArchivedRecord], quarantined: [RecoveryQuarantine],
                     conflictingRecordIDs: Set<String>, heads: [String: [String]]) {
        self.originals = originals; self.envelopes = envelopes; self.rules = rules; self.profiles = profiles
        self.waiting = waiting; self.quarantined = quarantined; self.conflictingRecordIDs = conflictingRecordIDs; self.heads = heads
    }
}

struct RecoveryVerifier {
    func verify(_ records: [ArchivedRecord]) throws -> VerifiedCloudBatch {
        var supplied = records
        for record in records {
            if let archive = try? CausalOriginalArchive.validate(record) { supplied.append(archive.record) }
        }
        let originals = try Dictionary(supplied.map { (try $0.key, $0) }, uniquingKeysWith: { first, _ in first }).sorted { $0.key < $1.key }.map(\.value)
        var quarantine: [String: RecoveryQuarantine] = [:]
        var candidates: [String: (JournalEnvelope, ArchivedRecord)] = [:]
        var rules: [String: ArchivedObject] = [:], profiles: [String: ArchivedObject] = [:]
        var conflicts = Set<String>()
        let grouped = Dictionary(grouping: originals, by: \.recordID)
        for (id, variants) in grouped where Set(variants.map(\.bytes)).count > 1 { conflicts.insert(id) }
        func reject(_ record: ArchivedRecord, reason: String, program: String? = nil) throws {
            quarantine[try record.key] = RecoveryQuarantine(record: record, reason: reason, programID: program)
        }
        for record in originals {
            var program: String?
            do {
                guard record.bytes.count <= CloudRecordCodec.maximumAssetBytes,
                      record.claimedChecksum == BackupService.hash(record.bytes),
                      try CloudRecordCodec.canonicalBytes(record.bytes) == record.bytes,
                      record.zoneName.hasPrefix(CloudRecordCodec.zonePrefix),
                      let dataset = UUID(uuidString: String(record.zoneName.dropFirst(CloudRecordCodec.zonePrefix.count))),
                      record.zoneName == CloudRecordCodec.zoneID(dataset).zoneName else { throw BackupService.invalid("cloud_integrity") }
                let fields = try JSONSerialization.jsonObject(with: record.bytes) as? [String: Any]
                if record.recordType == CloudRecordKind.journal.recordType { program = fields?["programId"] as? String }
                if record.recordType == CloudRecordKind.archive.recordType {
                    let ruleArchive = fields?["hash"] is String
                    let id = try BackupService.archiveHash(record.bytes, key: ruleArchive ? "hash" : "contentHash")
                    guard record.recordID == (try CloudRecordCodec.recordName(kind: .archive, datasetID: dataset, identity: id)) else { throw BackupService.invalid("archive_identity") }
                    if fields?["archiveKind"] != nil { _ = try CausalOriginalArchive.validate(record) }
                    let archived = ArchivedObject(id: id, bytes: record.bytes, checksum: BackupService.hash(record.bytes))
                    if ruleArchive { _ = try BackupService.rules([archived], hash: id); rules[id] = archived }
                    else { try BackupService.validateStarterProfileRegistration(archived); profiles[id] = archived }
                } else {
                    guard record.recordType == CloudRecordKind.journal.recordType,
                          let identity = fields?["eventId"] as? String,
                          record.recordID == (try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: identity)),
                          fields?["datasetId"] as? String == dataset.uuidString.lowercased() else { throw BackupService.invalid("journal_identity") }
                    guard let schema = fields?["schemaVersion"] as? Int, [1, 2, 3, 4].contains(schema) else {
                        throw EngineError(code: "unsupported_version", field: "schemaVersion")
                    }
                    // Unknown discriminators are version boundaries. Missing or
                    // type-invalid fields of a known format are corrupt originals.
                    let command = fields?["command"] as? [String: Any]
                    if let kind = command?["kind"] as? String {
                        guard ["initialize", "workout", "reconfigure", "variantChange", "reschedule", "interruption", "resolveConflict", "activatePolicy", "changeStarterProgram"].contains(kind) else {
                            throw EngineError(code: "unsupported_version", field: "command.kind")
                        }
                        if let change = command?["change"] as? [String: Any], let changeKind = change["kind"] as? String {
                            let supported = kind == "reconfigure" ? ["goal", "minimumRir", "resetSetup", "safeResume", "reviewStrengthHandling"] :
                                kind == "variantChange" ? ["create", "select", "correctDescription", "createLoadingMode"] : nil
                            if let supported, !supported.contains(changeKind) { throw EngineError(code: "unsupported_version", field: "change.kind") }
                        }
                    }
                    let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: record.bytes)
                    guard try BackupService.bytes(envelope) == record.bytes,
                          envelope.envelopeHash == (try BackupService.envelopeHash(envelope)),
                          envelope.eventHash == (try BackupService.eventHash(envelope.command)),
                          UUID(uuidString: envelope.programID)?.uuidString.lowercased() == envelope.programID,
                          envelope.programID == envelope.returnedState.config.programID,
                          envelope.returnedState.schemaVersion == schema else { throw BackupService.invalid("envelope_hashes") }
                    guard BackupService.supportsRegisteredPolicy(envelope) else { throw EngineError(code: "unsupported_version", field: "policy") }
                    candidates[envelope.envelopeHash] = (envelope, record)
                }
            } catch {
                let reason = (error as? EngineError).map { ["unsupported_version", "unknown_ruleset"].contains($0.code) } == true ? "unsupported_version" : "invalid_record"
                try reject(record, reason: reason, program: program)
            }
        }
        // Different payloads with one global event/program identity are retained
        // even when they came from different datasets/zones.
        let eventGroups = Dictionary(grouping: candidates.values, by: { $0.0.eventID })
        for variants in eventGroups.values where variants.count > 1 {
            for (_, record) in variants { conflicts.insert(record.recordID) }
        }
        let programGroups = Dictionary(grouping: candidates.values, by: { $0.0.programID })
        for variants in programGroups.values where Set(variants.map { $0.0.datasetID }).count > 1 {
            for (_, record) in variants { conflicts.insert(record.recordID) }
        }
        var verified: [String: JournalEnvelope] = [:]
        var remaining = candidates
        var progressed = true
        while progressed {
            progressed = false
            for hash in remaining.keys.sorted() {
                let (envelope, record) = remaining[hash]!
                guard let archive = rules[envelope.rulesetHash], profiles[envelope.profileHash] != nil,
                      profiles[envelope.sourceProfileHash] != nil else { continue }
                if case let .resolveConflict(selection, _, archiveHashes, _) = envelope.command {
                    guard Set(archiveHashes).count == archiveHashes.count, !archiveHashes.isEmpty, archiveHashes.allSatisfy({ profiles[$0] != nil }),
                          selection.reviewedQuarantineChecksums.allSatisfy({ checksum in originals.contains { BackupService.hash($0.bytes) == checksum } }) else { continue }
                }
                if case let .activatePolicy(source, _, _, _) = envelope.command, rules[source] == nil { continue }
                let parents = Self.dependencies(envelope)
                guard parents.allSatisfy({ verified[$0] != nil }) else { continue }
                do {
                    let rule = try BackupService.rules([archive], hash: envelope.rulesetHash)
                    let config = envelope.returnedState.config
                    guard envelope.rulesetVersion == rule.version else { throw BackupService.invalid("rules_version") }
                    if [2,3,4].contains(envelope.schemaVersion) {
                        guard envelope.profileID == config.profileID, envelope.profileHash == config.profileHash,
                              envelope.sourceProfileID == config.sourceProfileID, envelope.sourceProfileHash == config.sourceProfileHash,
                              rule.profileID == envelope.profileID, rule.profileHash == envelope.profileHash else { throw BackupService.invalid("archive_references") }
                    }
                    let replayed: ConfigurationResult
                    if case let .initialize(config, first) = envelope.command {
                        guard envelope.parentEnvelopeHash == nil, envelope.inputStateHash == nil, envelope.inputRevision == -1,
                              config.programID == envelope.programID else { throw BackupService.invalid("root") }
                        let result = try initializeProgram(config: config, rules: rule, firstWorkout: first)
                        replayed = ConfigurationResult(state: result.state, workout: result.workout, decisions: [])
                    } else {
                        guard let parentHash = envelope.parentEnvelopeHash, let parent = verified[parentHash],
                              parent.datasetID == envelope.datasetID, parent.programID == envelope.programID,
                              envelope.inputRevision == parent.returnedState.revision,
                              envelope.inputStateHash == (try BackupService.hash(parent.returnedState)) else { throw BackupService.invalid("parent") }
                        if case let .resolveConflict(selection, heads, originalHashes, next) = envelope.command {
                            let sourceWrappers = try originalHashes.map { hash -> CausalOriginalArchive in
                                guard let archive = profiles[hash] else { throw BackupService.invalid("missing_original_archive") }
                                return try JSONDecoder().decode(CausalOriginalArchive.self, from: archive.bytes)
                            }
                            let causalHashes = try heads.reduce(into: Set<String>()) { hashes, head in
                                hashes.formUnion(try Self.ancestors(head, envelopes: verified))
                            }
                            guard selection.selectedHeadHash == parentHash,
                                  selection.reviewedQuarantineChecksums.allSatisfy({ checksum in sourceWrappers.contains { BackupService.hash($0.record.bytes) == checksum } }),
                                  try causalHashes.allSatisfy({ hash in
                                      guard let original = verified[hash], let dataset = UUID(uuidString: original.datasetID) else { return false }
                                      let bytes = try BackupService.bytes(original)
                                      let name = try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: original.eventID)
                                      return sourceWrappers.contains { wrapper in
                                          wrapper.archiveKind == "causal-original-v1" && wrapper.record.recordID == name &&
                                          wrapper.record.zoneName == CloudRecordCodec.zoneID(dataset).zoneName &&
                                          wrapper.record.recordType == CloudRecordKind.journal.recordType && wrapper.record.bytes == bytes &&
                                          wrapper.record.claimedChecksum == BackupService.hash(bytes)
                                      }
                                  }) else { throw BackupService.invalid("resolution_original_sources") }
                            let result = try resolveCloudBranches(Self.resolutionInput(envelopes: verified, heads: heads, selection: selection, next: next, rules: rule))
                            replayed = ConfigurationResult(state: result.state, workout: result.workout, decisions: result.decisions)
                        } else {
                            var prefix: [JournalEnvelope] = []
                            if case let .activatePolicy(source, destination, _, _) = envelope.command {
                                guard source == parent.rulesetHash, destination == envelope.rulesetHash else { throw BackupService.invalid("activation_rules") }
                                prefix = try Self.ancestors(parentHash, envelopes: verified).compactMap { verified[$0] }
                            }
                            if case .changeStarterProgram = envelope.command {
                                prefix = try Self.ancestors(parentHash, envelopes: verified).compactMap { verified[$0] }
                            }
                            replayed = try BackupService.transition(state: parent.returnedState, command: envelope.command, rules: rule, legacyHistory: prefix, archivedRules: Array(rules.values), archivedProfiles: Array(profiles.values))
                        }
                        guard replayed.state.revision == parent.returnedState.revision + 1 else { throw BackupService.invalid("revision") }
                    }
                    guard try BackupService.bytes(replayed.state) == BackupService.bytes(envelope.returnedState),
                          try BackupService.bytes(replayed.workout) == BackupService.bytes(envelope.returnedPrescription),
                          try BackupService.bytes(replayed.decisions) == BackupService.bytes(envelope.decisions),
                          try BackupService.bytes(replayed.state.activePrescription) == BackupService.bytes(replayed.workout) else { throw BackupService.invalid("replay_output") }
                    _ = try prepareWorkout(state: replayed.state, rules: rule)
                    verified[hash] = envelope
                } catch {
                    let unknown = (error as? EngineError).map { ["unsupported_version", "unknown_ruleset"].contains($0.code) } ?? false
                    try reject(record, reason: unknown ? "unsupported_version" : "replay_failed", program: envelope.programID)
                }
                remaining.removeValue(forKey: hash); progressed = true
            }
        }
        var heads: [String: Set<String>] = [:]
        for envelope in verified.values { heads[envelope.programID, default: []].insert(envelope.envelopeHash) }
        for envelope in verified.values {
            for parent in Self.dependencies(envelope) { heads[envelope.programID]?.remove(parent) }
        }
        for (hash, envelope) in verified where conflicts.contains(candidates[hash]!.1.recordID) {
            try reject(candidates[hash]!.1, reason: "identity_conflict", program: envelope.programID)
        }
        // Raw bytes may be unparseable or claim another program. Only a unique
        // fully replayed source with the exact actual descriptor can attribute
        // that quarantine to current program health; never guess from ordering.
        let sources = verified.keys.map { candidates[$0]! }
        for (key, problem) in quarantine {
            let programs = Set(sources.filter {
                $0.1.recordID == problem.record.recordID && $0.1.zoneName == problem.record.zoneName &&
                $0.1.recordType == problem.record.recordType
            }.map { $0.0.programID })
            if programs.count == 1, let program = programs.first {
                quarantine[key] = RecoveryQuarantine(record: problem.record, reason: problem.reason, programID: program)
            }
        }
        return VerifiedCloudBatch(originals: originals, envelopes: verified, rules: rules.values.sorted { $0.id < $1.id },
            profiles: profiles.values.sorted { $0.id < $1.id }, waiting: remaining.values.map(\.1).sorted { $0.recordID < $1.recordID },
            quarantined: quarantine.sorted { $0.key < $1.key }.map(\.value), conflictingRecordIDs: conflicts,
            heads: heads.mapValues { $0.sorted() })
    }
    static func dependencies(_ envelope: JournalEnvelope) -> [String] {
        var hashes = envelope.parentEnvelopeHash.map { [$0] } ?? []
        if case let .resolveConflict(_, preserved, _, _) = envelope.command { hashes += preserved }
        return Array(Set(hashes)).sorted()
    }
    static func ancestors(_ head: String, envelopes: [String: JournalEnvelope]) throws -> Set<String> {
        var seen = Set<String>(), pending = [head]
        while let hash = pending.popLast() {
            if seen.insert(hash).inserted {
                guard let envelope = envelopes[hash] else { throw BackupService.invalid("missing_branch_dependency") }
                pending += dependencies(envelope)
            }
        }
        return seen
    }
    static func hasMixedPolicyConflict(programID: String, envelopes: [String: JournalEnvelope], heads: [String]) throws -> Bool {
        guard heads.count > 1 else { return false }
        let states = heads.compactMap { envelopes[$0]?.returnedState }
        guard states.count == heads.count, states.allSatisfy({ $0.config.programID == programID }) else { throw BackupService.invalid("conflict_heads") }
        if Set(states.map { "\($0.schemaVersion):\($0.rulesetHash)" }).count > 1 { return true }
        let paths = try heads.map { try ancestors($0, envelopes: envelopes) }
        let common = paths.dropFirst().reduce(paths[0]) { $0.intersection($1) }
        guard let ancestor = common.compactMap({ envelopes[$0] }).sorted(by: {
            ($0.returnedState.revision, $0.envelopeHash) > ($1.returnedState.revision, $1.envelopeHash)
        }).first else { return true }
        return ancestor.returnedState.schemaVersion != states[0].schemaVersion || ancestor.rulesetHash != states[0].rulesetHash
    }
    static func resolutionInput(envelopes: [String: JournalEnvelope], heads: [String], selection: BranchSelection,
                                next: WorkoutSlot, rules: Ruleset) throws -> BranchResolutionInput {
        guard !heads.isEmpty, (heads.count >= 2 || !selection.reviewedQuarantineChecksums.isEmpty), Set(heads).count == heads.count else { throw BackupService.invalid("resolution_heads") }
        guard let program = envelopes[heads[0]]?.programID,
              try !hasMixedPolicyConflict(programID: program, envelopes: envelopes, heads: heads) else { throw EngineError(code: "mixed_policy_conflict", field: "branches") }
        let paths = try heads.map { try ancestors($0, envelopes: envelopes) }
        let common = paths.dropFirst().reduce(paths[0]) { $0.intersection($1) }
        guard let ancestor = common.compactMap({ envelopes[$0] }).sorted(by: {
            ($0.returnedState.revision, $0.envelopeHash) > ($1.returnedState.revision, $1.envelopeHash)
        }).first else { throw BackupService.invalid("no_common_ancestor") }
        let branches = try zip(heads, paths).map { hash, path -> VerifiedBranch in
            guard let envelope = envelopes[hash], envelope.programID == ancestor.programID,
                  envelope.datasetID == ancestor.datasetID else { throw BackupService.invalid("branch_identity") }
            let commands = path.subtracting(common).compactMap { envelopes[$0] }.sorted {
                ($0.returnedState.revision, $0.envelopeHash) < ($1.returnedState.revision, $1.envelopeHash)
            }.map(\.command)
            return VerifiedBranch(headHash: hash, state: envelope.returnedState, commands: commands)
        }
        return BranchResolutionInput(commonAncestor: ancestor.returnedState, competingHeadHashes: heads,
            branches: branches, selection: selection, rules: rules, next: next)
    }
}


struct CausalOriginalArchive: Codable, Equatable, Sendable {
    var archiveKind = "causal-original-v1"
    var contentHash: String
    var record: ArchivedRecord
    static func make(_ record: ArchivedRecord) throws -> ArchivedObject {
        var archive = CausalOriginalArchive(contentHash: "", record: record)
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: BackupService.bytes(archive)) else { throw BackupService.invalid("original_archive") }
        fields.removeValue(forKey: "contentHash")
        archive.contentHash = try CanonicalJSON.sha256(.object(fields))
        let object = try BackupService.object(archive, id: archive.contentHash)
        guard object.bytes.count <= CloudRecordCodec.maximumAssetBytes else { throw BackupService.invalid("original_archive_oversize") }
        return object
    }
    static func validate(_ record: ArchivedRecord) throws -> CausalOriginalArchive {
        let archive = try validatedHeader(record)
        // Only an independently valid embedded wrapper is recursive source
        // misuse. Arbitrary marker fields in raw invalid originals stay opaque.
        if (try? validatedHeader(archive.record)) != nil { throw BackupService.invalid("nested_original_archive") }
        return archive
    }
    private static func validatedHeader(_ record: ArchivedRecord) throws -> CausalOriginalArchive {
        guard record.recordType == CloudRecordKind.archive.recordType,
              record.bytes.count <= CloudRecordCodec.maximumAssetBytes,
              record.claimedChecksum == BackupService.hash(record.bytes),
              try CloudRecordCodec.canonicalBytes(record.bytes) == record.bytes else { throw BackupService.invalid("original_archive_transport") }
        let archive = try JSONDecoder().decode(Self.self, from: record.bytes)
        guard try BackupService.bytes(archive) == record.bytes,
              archive.archiveKind == "causal-original-v1", archive.record.zoneName == record.zoneName,
              let dataset = UUID(uuidString: String(record.zoneName.dropFirst(CloudRecordCodec.zonePrefix.count))),
              record.zoneName == CloudRecordCodec.zoneID(dataset).zoneName,
              try BackupService.archiveHash(record.bytes, key: "contentHash") == archive.contentHash,
              record.recordID == (try CloudRecordCodec.recordName(kind: .archive, datasetID: dataset, identity: archive.contentHash)) else { throw BackupService.invalid("original_archive_identity") }
        return archive
    }
}

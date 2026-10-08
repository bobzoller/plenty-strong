import CryptoKit
import Foundation
import TrainingCore

/// Portable validation works exclusively on supplied archives and original commands.
/// A checksum is transport integrity; acceptance also requires full deterministic replay.
enum BackupService {
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)))
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func hash<T: Encodable>(_ value: T) throws -> String { hash(try bytes(value)) }
    static func envelopeHash(_ envelope: JournalEnvelope) throws -> String {
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: bytes(envelope)) else { throw invalid("envelope") }
        fields.removeValue(forKey: "envelopeHash")
        return try CanonicalJSON.sha256(.object(fields))
    }
    static func invalid(_ field: String) -> EngineError { .init(code: "integrity_conflict", field: field) }
    static func object<T: Encodable>(_ value: T, id: String) throws -> ArchivedObject {
        let data = try bytes(value)
        return ArchivedObject(id: id, bytes: data, checksum: hash(data))
    }
    static func archiveHash(_ data: Data, key: String) throws -> String {
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: data),
              case .string(let supplied) = fields.removeValue(forKey: key),
              try CanonicalJSON.sha256(.object(fields)) == supplied else { throw invalid("archive") }
        return supplied
    }
    static func validateObjects(_ objects: [ArchivedObject]) throws {
        guard Set(objects.map(\.id)).count == objects.count,
              objects.allSatisfy({ !$0.id.isEmpty && hash($0.bytes) == $0.checksum }) else { throw invalid("objects") }
    }
    static func rules(_ archives: [ArchivedObject], hash: String) throws -> Ruleset {
        guard let archive = archives.first(where: { $0.id == hash }) else { throw invalid("missing_rules") }
        let rule = try JSONDecoder().decode(Ruleset.self, from: archive.bytes)
        guard ["general-fitness-swift1", "general-fitness-v0.2", "general-fitness-exact-v1"].contains(rule.version) else { throw EngineError(code: "unsupported_version", field: "rules") }
        try rule.validateIntegrity()
        guard rule.hash == hash else { throw invalid("rules_hash") }
        _ = try RulesetCatalog.resolve(version: rule.version, hash: rule.hash)
        guard try archiveHash(archive.bytes, key: "hash") == hash else { throw invalid("rules_hash") }
        return rule
    }
    struct Replay {
        var histories: [String: [JournalEnvelope]]
        var heads: [String: JournalEnvelope]
    }
    static func validate(_ document: BackupDocument) throws -> Replay {
        if document.formatVersion == 2 { return try validateGraph(document) }
        guard document.formatVersion == 1, document.recovery == nil else { throw EngineError(code: "unsupported_version", field: "formatVersion") }
        guard !document.datasetID.isEmpty else { throw invalid("dataset") }
        try [document.journal, document.rules, document.profiles, document.drafts].forEach(validateObjects)
        for archive in document.rules {
            guard try archiveHash(archive.bytes, key: "hash") == archive.id else { throw invalid("rules_hash") }
            _ = try rules([archive], hash: archive.id)
        }
        for archive in document.profiles {
            guard try archiveHash(archive.bytes, key: "contentHash") == archive.id else { throw invalid("profile_hash") }
        }
        let envelopes = try document.journal.map { item -> JournalEnvelope in
            let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: item.bytes)
            guard envelope.eventID == item.id, try bytes(envelope) == item.bytes else { throw invalid("canonical_envelope") }
            return envelope
        }.sorted { ($0.programID, $0.returnedState.revision) < ($1.programID, $1.returnedState.revision) }
        var histories: [String: [JournalEnvelope]] = [:]
        var heads: [String: JournalEnvelope] = [:]
        for envelope in envelopes {
            guard [2, 3].contains(envelope.schemaVersion), envelope.returnedState.schemaVersion == envelope.schemaVersion else {
                throw EngineError(code: "unsupported_version", field: "schemaVersion")
            }
            guard envelope.datasetID == document.datasetID,
                  envelope.programID == envelope.returnedState.config.programID,
                  envelope.envelopeHash == (try envelopeHash(envelope)),
                  envelope.eventHash == (try eventHash(envelope.command)),
                  document.profiles.contains(where: { $0.id == envelope.profileHash }),
                  document.profiles.contains(where: { $0.id == envelope.sourceProfileHash }) else { throw invalid("envelope_hashes") }
            let rule = try rules(document.rules, hash: envelope.rulesetHash)
            let config = envelope.returnedState.config
            guard envelope.rulesetVersion == rule.version, envelope.profileID == config.profileID,
                  envelope.profileHash == config.profileHash, envelope.sourceProfileID == config.sourceProfileID,
                  envelope.sourceProfileHash == config.sourceProfileHash,
                  rule.profileID == envelope.profileID, rule.profileHash == envelope.profileHash else { throw invalid("archive_references") }
            let parent = heads[envelope.programID]
            let replayed: ConfigurationResult
            if case let .initialize(config, first) = envelope.command {
                guard parent == nil, envelope.parentEnvelopeHash == nil, envelope.inputStateHash == nil,
                      envelope.inputRevision == -1, config.programID == envelope.programID else { throw invalid("root") }
                let initialized = try initializeProgram(config: config, rules: rule, firstWorkout: first)
                replayed = ConfigurationResult(state: initialized.state, workout: initialized.workout, decisions: [])
            } else {
                guard let parent, envelope.parentEnvelopeHash == parent.envelopeHash,
                      envelope.inputRevision == parent.returnedState.revision,
                      envelope.inputStateHash == (try hash(parent.returnedState)) else { throw invalid("parent") }
                if case let .activatePolicy(source, destination, _, _) = envelope.command {
                    guard source == parent.rulesetHash, destination == envelope.rulesetHash else { throw invalid("activation_rules") }
                    _ = try rules(document.rules, hash: source)
                }
                replayed = try transition(state: parent.returnedState, command: envelope.command, rules: rule, legacyHistory: histories[envelope.programID] ?? [])
                guard replayed.state.revision == parent.returnedState.revision + 1 else { throw invalid("revision") }
            }
            guard try bytes(replayed.state) == bytes(envelope.returnedState),
                  try bytes(replayed.workout) == bytes(envelope.returnedPrescription),
                  try bytes(replayed.decisions) == bytes(envelope.decisions),
                  try bytes(replayed.state.activePrescription) == bytes(replayed.workout) else { throw invalid("replay_output") }
            _ = try prepareWorkout(state: replayed.state, rules: rule)
            heads[envelope.programID] = envelope
            histories[envelope.programID, default: []].append(envelope)
        }
        guard document.heads == heads.mapValues(\.envelopeHash) else { throw invalid("terminal_head_manifest") }
        var draftPrograms = Set<String>()
        for item in document.drafts {
            let draft = try JSONDecoder().decode(WorkoutDraft.self, from: item.bytes)
            guard item.id == draft.id.uuidString.lowercased(), try bytes(draft) == item.bytes,
                  draftPrograms.insert(draft.programID).inserted,
                  let head = heads[draft.programID] else { throw invalid("draft") }
            try validateDraft(draft, state: head.returnedState, rules: rules(document.rules, hash: head.rulesetHash))
        }
        return Replay(histories: histories, heads: heads)
    }
    static func eventHash(_ command: JournalCommand) throws -> String {
        if case let .workout(event, _) = command { return try hash(event) }
        return try hash(command)
    }
    static func transition(state: ProgramState, command: JournalCommand, rules: Ruleset, legacyHistory: [JournalEnvelope] = []) throws -> ConfigurationResult {
        if case let .activatePolicy(source, destination, evidence, next) = command {
            guard state.schemaVersion == 2, source == state.rulesetHash, destination == rules.hash,
                  evidence == (try policyActivationEvidenceEventIDs(state: state, history: legacyHistory)) else { throw invalid("activation_evidence") }
            let sourceRules = try RulesetCatalog.resolve(version: state.rulesetVersion, hash: source)
            return try activateProgramPolicy(state: state, sourceRules: sourceRules, destinationRules: rules, legacyHistory: legacyHistory, nextWorkout: next)
        }
        _ = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
        guard state.rulesetVersion == rules.version, state.rulesetHash == rules.hash else { throw invalid("command_rules") }
        switch command {
        case .activatePolicy: throw invalid("activation")
        case .initialize: throw invalid("nonroot_initialize")
        case let .workout(event, next):
            guard rawVariantSnapshotsMatch(state: state, event: event) else { throw invalid("raw_observation_snapshot") }
            switch advanceProgram(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)) {
            case let .applied(state, workout, decisions): return ConfigurationResult(state: state, workout: workout, decisions: decisions)
            case let .rejected(_, errors): throw EngineError(code: errors.joined(separator: ","), field: "workout")
            case .noOp: throw invalid("duplicate_transition")
            }
        case let .reconfigure(change, next): return try reconfigureProgram(state: state, change: change, rules: rules, nextWorkout: next)
        case let .variantChange(change, next): return try changeMovementVariant(state: state, change: change, rules: rules, nextWorkout: next)
        case let .reschedule(slot): return try reschedulePendingWorkout(state: state, slot: slot, rules: rules)
        case let .interruption(date): return try prepareInterruptedReturn(state: state, asOf: date, rules: rules)
        case .resolveConflict: throw invalid("resolution_requires_graph")
        }
    }
    static func validateDraft(_ draft: WorkoutDraft, state: ProgramState, rules: Ruleset) throws {
        let displayed = try prepareWorkout(state: state, rules: rules, easierToday: draft.sessionMode == .easier)
        if state.schemaVersion == 3 {
            for log in draft.logs {
                guard let row = displayed.exercises.first(where: { $0.movementID == log.movementID }) else { throw invalid("draft_log") }
                try validateIndexedExactLog(log, prescription: row)
                // Ordinary editable/completed work requires a reason; explicit
                // nonqualifying stops retain pending raw data without one.
                let handled = draft.acknowledgedMovementIDs?.contains(log.movementID) == true
                if log.problem == .none && (log.status == .completed || !handled) {
                    for actual in log.actualSets {
                        if actual.reps < row.sets[actual.setIndex!].targetReps!, actual.missedGoalReason == nil {
                            throw invalid("draft_missed_goal_reason")
                        }
                    }
                }
            }
        }
        let acknowledged = draft.acknowledgedMovementIDs ?? []
        guard Set(acknowledged).count == acknowledged.count,
              Set(acknowledged).isSubset(of: Set(displayed.exercises.map(\.movementID))),
              draft.restDeadline.map({ $0.timeIntervalSince1970.isFinite && WorkoutDraft.supportedRestDeadlineRange.contains($0) }) ?? true else { throw invalid("draft_ui_metadata") }
        guard draft.programID == state.config.programID, draft.expectedRevision == state.revision,
              try bytes(draft.planned) == bytes(state.activePrescription), try bytes(draft.displayed) == bytes(displayed),
              draft.date == displayed.date, TimeZone(identifier: draft.timeZoneID) != nil,
              Set(draft.logs.map(\.movementID)).count == draft.logs.count,
              draft.logs.map(\.movementID) == displayed.exercises.map(\.movementID),
              draft.logs.allSatisfy({ log in
                  log.prescriptionID == displayed.id && log.baseMovementID == state.config.variants?[log.movementID]?.baseMovementID &&
                  log.modificationsSnapshot != nil && log.modificationsSnapshot!.utf8.elementsEqual(state.config.variants?[log.movementID]?.modifications.utf8 ?? "".utf8) &&
                  log.actualSets.allSatisfy { $0.reps >= 0 && ($0.leftReps ?? 0) >= 0 && ($0.rightReps ?? 0) >= 0 }
              }) else { throw invalid("draft_binding") }
    }
}


extension BackupService {
    static func recoveryRecords(_ document: BackupDocument) throws -> [ArchivedRecord] {
        let envelopes = try document.journal.map { try JSONDecoder().decode(JournalEnvelope.self, from: $0.bytes) }
        var output: [ArchivedRecord] = []
        let datasets = Set(envelopes.map(\.datasetID))
        for envelope in envelopes {
            guard let dataset = UUID(uuidString: envelope.datasetID) else { throw invalid("dataset") }
            output.append(ArchivedRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: envelope.eventID),
                zoneName: CloudRecordCodec.zoneID(dataset).zoneName, recordType: CloudRecordKind.journal.recordType,
                claimedChecksum: hash(try bytes(envelope)), payload: try bytes(envelope), systemFields: Data())))
        }
        for text in datasets.sorted() {
            let dataset = UUID(uuidString: text)!
            for archive in document.rules + document.profiles {
                // Frozen resources can be shared across datasets. Exact source
                // wrappers belong only to their original dataset/zone.
                if let source = try? JSONDecoder().decode(CausalOriginalArchive.self, from: archive.bytes),
                   source.record.zoneName != CloudRecordCodec.zoneID(dataset).zoneName { continue }
                let canonical = try CloudRecordCodec.canonicalBytes(archive.bytes)
                output.append(ArchivedRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .archive, datasetID: dataset, identity: archive.id),
                    zoneName: CloudRecordCodec.zoneID(dataset).zoneName, recordType: CloudRecordKind.archive.recordType,
                    claimedChecksum: hash(canonical), payload: canonical, systemFields: Data())))
            }
        }
        return output + (document.recovery?.originals ?? [])
    }
    static func graphManifest(_ batch: VerifiedCloudBatch, originals: [ArchivedRecord], quarantines: [PortableQuarantine], resolved: [String]) -> RecoveryGraph {
        RecoveryGraph(originals: originals, heads: batch.heads,
            rootDatasets: Dictionary(uniqueKeysWithValues: batch.envelopes.values.filter { $0.parentEnvelopeHash == nil }.map { ($0.envelopeHash, $0.datasetID) }),
            quarantines: quarantines, resolvedQuarantineKeys: resolved.sorted())
    }
    static func validateGraph(_ document: BackupDocument) throws -> Replay {
        guard let graph = document.recovery, graph.version == 1 else { throw invalid("graph_version") }
        try [document.journal, document.rules, document.profiles, document.drafts].forEach(validateObjects)
        for archive in document.rules {
            guard try archiveHash(archive.bytes, key: "hash") == archive.id else { throw invalid("rules_hash") }
            _ = try rules([archive], hash: archive.id)
        }
        for archive in document.profiles { guard try archiveHash(archive.bytes, key: "contentHash") == archive.id else { throw invalid("profile_hash") } }
        guard Set(graph.quarantines.map(\.id)).count == graph.quarantines.count,
              graph.quarantines.allSatisfy({ hash($0.bytes) == $0.id }) else { throw invalid("portable_quarantine") }
        let batch = try RecoveryVerifier().verify(recoveryRecords(document))
        let reviewed = Set(batch.envelopes.values.flatMap { envelope -> [String] in
            if case let .resolveConflict(selection, _, _, _) = envelope.command { return selection.reviewedQuarantineChecksums }; return []
        })
        guard Set(graph.resolvedQuarantineKeys).count == graph.resolvedQuarantineKeys.count, Set(graph.resolvedQuarantineKeys) == reviewed else { throw invalid("unverified_quarantine_resolution") }
        guard graph.heads == batch.heads,
              graph.rootDatasets == graphManifest(batch, originals: [], quarantines: [], resolved: []).rootDatasets else { throw invalid("graph_manifest") }
        var histories: [String: [JournalEnvelope]] = [:]
        for envelope in batch.envelopes.values { histories[envelope.programID, default: []].append(envelope) }
        for id in histories.keys { histories[id]!.sort { ($0.returnedState.revision, $0.envelopeHash) < ($1.returnedState.revision, $1.envelopeHash) } }
        var heads: [String: JournalEnvelope] = [:]
        for (program, hash) in document.heads {
            guard let envelope = batch.envelopes[hash], envelope.programID == program else { throw invalid("graph_projection") }
            heads[program] = envelope
        }
        for item in document.journal {
            let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: item.bytes)
            guard item.id == envelope.eventID, try bytes(envelope) == item.bytes,
                  batch.envelopes[envelope.envelopeHash] != nil else { throw invalid("unverified_journal") }
        }
        var programs = Set<String>()
        for item in document.drafts {
            let draft = try JSONDecoder().decode(WorkoutDraft.self, from: item.bytes)
            guard item.id == draft.id.uuidString.lowercased(), programs.insert(draft.programID).inserted,
                  let head = heads[draft.programID] else { throw invalid("draft") }
            try validateDraft(draft, state: head.returnedState, rules: rules(document.rules, hash: head.rulesetHash))
        }
        return Replay(histories: histories, heads: heads)
    }
}

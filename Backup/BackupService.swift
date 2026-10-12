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
        guard ["general-fitness-swift1", "general-fitness-v0.2", "general-fitness-exact-v1", "general-fitness-upper-exact-v2", "general-fitness-glute-exact-v1", "general-fitness-migrated-exact-v1"].contains(rule.version) else { throw EngineError(code: "unsupported_version", field: "rules") }
        if (rule.contractVersion ?? 1) >= 4 || ["general-fitness-upper-exact-v2", "general-fitness-glute-exact-v1"].contains(rule.version) {
            guard rule.hash == hash, (try? RulesetCatalog.resolve(version: rule.version, hash: hash)) != nil else {
                throw EngineError(code: "unsupported_version", field: "rules")
            }
        }
        try rule.validateIntegrity()
        guard rule.hash == hash else { throw invalid("rules_hash") }
        _ = try RulesetCatalog.resolve(version: rule.version, hash: rule.hash)
        guard try archiveHash(archive.bytes, key: "hash") == hash else { throw invalid("rules_hash") }
        return rule
    }
    static func validateStarterProfileRegistration(_ archive: ArchivedObject, migrationCache: MigrationAdmissionCache? = nil) throws {
        if migrationCache?.source(archive) != nil { return }
        let raw = try JSONSerialization.jsonObject(with: archive.bytes) as? [String: Any]
        if let kind = raw?["archiveKind"] as? String {
            switch kind {
            case "external-program-source-v1":
                let source = try JSONDecoder().decode(ExternalSourceArchive.self, from: archive.bytes)
                try validateExternalSourceArchive(source)
                guard source.contentHash == archive.id, try bytes(source) == archive.bytes else { throw invalid("external_source_archive") }
                migrationCache?.remember(source: source, bytes: archive.bytes)
            case "causal-original-v1":
                _ = try JSONDecoder().decode(CausalOriginalArchive.self, from: archive.bytes)
            default: throw EngineError(code: "unsupported_version", field: "archiveKind")
            }
            return
        }
        let fields = try JSONSerialization.jsonObject(with: archive.bytes) as? [String: Any]
        let profileID = fields?["profileId"] as? String
        if (fields?["schemaVersion"] as? Int ?? 1) >= 4 || profileID?.hasPrefix("starter-") == true {
            guard fields?["schemaVersion"] as? Int == 4,
                  (profileID == "starter-upper-v1" && archive.id == StarterProgramCatalog.upperProfileHash) ||
                    (profileID == "starter-glute-v1" && archive.id == StarterProgramCatalog.gluteProfileHash) else {
                throw EngineError(code: "unsupported_version", field: "profile")
            }
        }
    }
    static func supportsRegisteredPolicy(_ envelope: JournalEnvelope) -> Bool {
        guard let rules = try? RulesetCatalog.resolve(version: envelope.rulesetVersion, hash: envelope.rulesetHash),
              (try? ProgramPolicy.resolve(schemaVersion: envelope.schemaVersion, rules: rules)) != nil,
              envelope.returnedState.rulesetHash == envelope.rulesetHash,
              envelope.returnedState.schemaVersion == envelope.schemaVersion,
              rules.profileID == nil || (rules.profileID == envelope.profileID && rules.profileHash == envelope.profileHash),
              (try? TrainingCore.validate(config: envelope.returnedState.config, rules: rules)) != nil else { return false }
        if envelope.schemaVersion != 1 {
            let config = envelope.returnedState.config
            guard envelope.profileID == config.profileID, envelope.profileHash == config.profileHash,
                  envelope.sourceProfileID == config.sourceProfileID, envelope.sourceProfileHash == config.sourceProfileHash else { return false }
        }
        switch envelope.command {
        case .initialize: return [1, 2, 3, 4].contains(envelope.schemaVersion)
        case .migrateProgram: return envelope.schemaVersion == 5
        case .changeStarterProgram: return envelope.schemaVersion == 4
        case .activatePolicy: return envelope.schemaVersion == 3
        case .reconfigure(change: .reviewStrengthHandling, next: _),
             .variantChange(change: .createLoadingMode, next: _): return envelope.schemaVersion == 4
        default: return true
        }
    }
    static func starterDefinition(_ archives: [ArchivedObject], hash: String) throws -> StarterProgramDefinition {
        guard let archive = archives.first(where: { $0.id == hash }),
              try archiveHash(archive.bytes, key: "contentHash") == hash else { throw invalid("missing_starter_profile") }
        let definition = try JSONDecoder().decode(StarterProgramDefinition.self, from: archive.bytes)
        guard definition.contentHash == hash,
              [StarterProgramCatalog.upperProfileHash, StarterProgramCatalog.gluteProfileHash].contains(hash) else {
            throw invalid("starter_profile_pin")
        }
        // The pure switch admits the complete typed projection with its actual
        // program/choice/goal; no synthetic config or latest-profile lookup.
        return definition
    }
    struct Replay {
        var histories: [String: [JournalEnvelope]]
        var heads: [String: JournalEnvelope]
        var recoveryBatch: VerifiedCloudBatch? = nil
        var rulesByHash: [String: Ruleset] = [:]
    }
    static func validate(_ document: BackupDocument, migrationCache: MigrationAdmissionCache? = nil) throws -> Replay {
        if document.formatVersion == 2 { return try validateGraph(document, migrationCache: migrationCache) }
        guard document.formatVersion == 1, document.recovery == nil else { throw EngineError(code: "unsupported_version", field: "formatVersion") }
        guard !document.datasetID.isEmpty else { throw invalid("dataset") }
        try [document.journal, document.rules, document.profiles, document.drafts].forEach(validateObjects)
        // Admit each frozen archive once for this immutable document. Every event
        // still replays with its referenced policy. Repository contexts may retain
        // only byte-bound immutable source admission and root replay evidence.
        var admittedRules: [String: Ruleset] = [:]
        for archive in document.rules {
            guard try archiveHash(archive.bytes, key: "hash") == archive.id else { throw invalid("rules_hash") }
            admittedRules[archive.id] = try rules([archive], hash: archive.id)
        }
        func admittedRule(_ hash: String) throws -> Ruleset {
            guard let rule = admittedRules[hash] else { throw invalid("missing_rules") }
            return rule
        }
        for archive in document.profiles {
            if migrationCache?.source(archive) != nil { continue }
            guard try archiveHash(archive.bytes, key: "contentHash") == archive.id else { throw invalid("profile_hash") }
            try validateStarterProfileRegistration(archive, migrationCache: migrationCache)
        }
        let envelopes = try document.journal.map { item -> JournalEnvelope in
            let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: item.bytes)
            guard envelope.eventID == item.id, try bytes(envelope) == item.bytes else { throw invalid("canonical_envelope") }
            return envelope
        }.sorted { ($0.programID, $0.returnedState.revision) < ($1.programID, $1.returnedState.revision) }
        var histories: [String: [JournalEnvelope]] = [:]
        var heads: [String: JournalEnvelope] = [:]
        for envelope in envelopes {
            guard [2, 3, 4, 5].contains(envelope.schemaVersion), envelope.returnedState.schemaVersion == envelope.schemaVersion else {
                throw EngineError(code: "unsupported_version", field: "schemaVersion")
            }
            guard envelope.datasetID == document.datasetID,
                  envelope.programID == envelope.returnedState.config.programID,
                  envelope.envelopeHash == (try envelopeHash(envelope)),
                  envelope.eventHash == (try eventHash(envelope.command)),
                  document.profiles.contains(where: { $0.id == envelope.profileHash }),
                  document.profiles.contains(where: { $0.id == envelope.sourceProfileHash }) else { throw invalid("envelope_hashes") }
            let rule = try admittedRule(envelope.rulesetHash)
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
            } else if case .migrateProgram = envelope.command {
                guard parent == nil else { throw invalid("migration_root_parent") }
                replayed = try replayMigrationRoot(envelope, rules: rule, profiles: document.profiles, migrationCache: migrationCache, ruleArchiveBytes: document.rules.first { $0.id == rule.hash }?.bytes)
            } else {
                guard let parent, envelope.parentEnvelopeHash == parent.envelopeHash,
                      envelope.inputRevision == parent.returnedState.revision,
                      envelope.inputStateHash == (try hash(parent.returnedState)) else { throw invalid("parent") }
                if case let .activatePolicy(source, destination, _, _) = envelope.command {
                    guard source == parent.rulesetHash, destination == envelope.rulesetHash else { throw invalid("activation_rules") }
                    _ = try admittedRule(source)
                }
                replayed = try transition(state: parent.returnedState, command: envelope.command, rules: rule, legacyHistory: histories[envelope.programID] ?? [], archivedRules: document.rules, archivedProfiles: document.profiles)
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
            try validateDraft(draft, state: head.returnedState, rules: admittedRule(head.rulesetHash))
        }
        return Replay(histories: histories, heads: heads, rulesByHash: admittedRules)
    }
    /// Capture follows complete admission. Immutable bytes are represented by
    /// their admitted checksums, avoiding re-encoding megabytes for review tokens.
    static func migrationStoreFingerprint(_ document: BackupDocument) throws -> String {
        func objects(_ values: [ArchivedObject]) -> CanonicalValue {
            .array(values.sorted { $0.id < $1.id }.map { .object(["id": .string($0.id), "checksum": .string($0.checksum)]) })
        }
        var fields: [String: CanonicalValue] = ["formatVersion": .integer(Int64(document.formatVersion)), "datasetID": .string(document.datasetID),
            "heads": .object(document.heads.mapValues(CanonicalValue.string)), "journal": objects(document.journal),
            "rules": objects(document.rules), "profiles": objects(document.profiles), "drafts": objects(document.drafts)]
        if let graph = document.recovery {
            fields["recovery"] = .object(["version": .integer(Int64(graph.version)),
                "heads": .object(graph.heads.mapValues { .array($0.map(CanonicalValue.string)) }),
                "rootDatasets": .object(graph.rootDatasets.mapValues(CanonicalValue.string)),
                "originals": .array(graph.originals.map { record in .object(["recordID": .string(record.recordID),
                    "zoneName": .string(record.zoneName), "recordType": .string(record.recordType),
                    "claimedChecksum": record.claimedChecksum.map(CanonicalValue.string) ?? .null,
                    "checksum": .string(hash(record.bytes))]) }),
                "quarantines": .array(graph.quarantines.map { .object(["id": .string($0.id), "reason": .string($0.reason), "checksum": .string(hash($0.bytes))]) }),
                "resolvedQuarantineKeys": .array(graph.resolvedQuarantineKeys.map(CanonicalValue.string))])
        }
        return try CanonicalJSON.sha256(.object(fields))
    }
    static func externalSource(_ archives: [ArchivedObject], hash: String, migrationCache: MigrationAdmissionCache? = nil) throws -> ExternalSourceArchive {
        if let archive = archives.first(where: { $0.id == hash }), let source = migrationCache?.source(archive) { return source }
        guard let archive = archives.first(where: { $0.id == hash }),
              try archiveHash(archive.bytes, key: "contentHash") == hash else { throw invalid("missing_external_source") }
        try validateStarterProfileRegistration(archive, migrationCache: migrationCache)
        if let source = migrationCache?.source(archive) { return source }
        let source = try JSONDecoder().decode(ExternalSourceArchive.self, from: archive.bytes)
        guard source.contentHash == hash else { throw invalid("external_source_hash") }
        try validateExternalSourceArchive(source)
        return source
    }
    static func migrationArchiveHash(_ command: JournalCommand) -> String? {
        if case let .migrateProgram(_, _, _, hash) = command { return hash }
        return nil
    }
    static func replayMigrationRoot(_ envelope: JournalEnvelope, rules: Ruleset, profiles: [ArchivedObject], migrationCache: MigrationAdmissionCache? = nil, ruleArchiveBytes: Data? = nil) throws -> ConfigurationResult {
        guard envelope.schemaVersion == 5, envelope.parentEnvelopeHash == nil,
              envelope.inputStateHash == nil, envelope.inputRevision == -1,
              envelope.returnedState.revision == 0,
              case let .migrateProgram(checkpoint, selection, acceptance, hash) = envelope.command,
              hash == checkpoint.externalArchiveHash,
              let id = UUID(uuidString: envelope.programID) else { throw invalid("migration_root") }
        let source = try externalSource(profiles, hash: hash, migrationCache: migrationCache)
        guard let archive = profiles.first(where: { $0.id == hash }) else { throw invalid("missing_external_source") }
        guard let profile = profiles.first(where: { $0.id == envelope.profileHash }),
              let sourceProfile = profiles.first(where: { $0.id == envelope.sourceProfileHash }) else { throw invalid("migration_profile_dependencies") }
        let cacheKey = try self.hash([envelope.envelopeHash, self.hash(try bytes(envelope)), rules.hash,
            self.hash(ruleArchiveBytes ?? bytes(rules)), self.hash(profile.bytes), self.hash(sourceProfile.bytes), hash, self.hash(archive.bytes)])
        if let cached = migrationCache?.root(key: cacheKey) { return cached }
        let result = try migrateProgram(checkpoint: checkpoint, selection: selection, acceptance: acceptance,
            source: source, programID: id, rules: rules)
        let replayed = ConfigurationResult(state: result.state, workout: result.workout, decisions: [])
        migrationCache?.remember(root: replayed, key: cacheKey)
        return replayed
    }
    static func eventHash(_ command: JournalCommand) throws -> String {
        if case let .workout(event, _) = command { return try hash(event) }
        return try hash(command)
    }
    static func transition(state: ProgramState, command: JournalCommand, rules: Ruleset, legacyHistory: [JournalEnvelope] = [], archivedRules: [ArchivedObject] = [], archivedProfiles: [ArchivedObject] = []) throws -> ConfigurationResult {
        if case let .changeStarterProgram(choice, goal, next) = command {
            guard let profileHash = rules.profileHash,
                  (try? ProgramPolicy.resolve(schemaVersion: 4, rules: rules))?.usesStarterDoses == true else {
                throw EngineError(code: "unsupported_version", field: "destinationRules")
            }
            let definition = try starterDefinition(archivedProfiles, hash: profileHash)
            let source = try self.rules(archivedRules, hash: state.rulesetHash)
            return try changeStarterProgram(state: state, sourceRules: source, destinationRules: rules,
                destinationDefinition: definition, choice: choice, goal: goal, verifiedHistory: legacyHistory, nextWorkout: next)
        }
        if case let .activatePolicy(source, destination, evidence, next) = command {
            guard state.schemaVersion == 2, source == state.rulesetHash, destination == rules.hash,
                  evidence == (try policyActivationEvidenceEventIDs(state: state, history: legacyHistory)) else { throw invalid("activation_evidence") }
            let sourceRules = try RulesetCatalog.resolve(version: state.rulesetVersion, hash: source)
            return try activateProgramPolicy(state: state, sourceRules: sourceRules, destinationRules: rules, legacyHistory: legacyHistory, nextWorkout: next)
        }
        _ = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
        guard state.rulesetVersion == rules.version, state.rulesetHash == rules.hash else { throw invalid("command_rules") }
        switch command {
        case .activatePolicy, .changeStarterProgram: throw invalid("activation")
        case .initialize, .migrateProgram: throw invalid("nonroot_initialize")
        case .activateFlexibleScheduling: return try activateFlexibleScheduling(state: state, rules: rules)
        case let .workout(event, next):
            guard rawVariantSnapshotsMatch(state: state, event: event) else { throw invalid("raw_observation_snapshot") }
            if event.observationAudit != nil {
                let displayed = try prepareWorkout(state: state, rules: rules, easierToday: event.sessionMode == .easier)
                _ = try ObservationAuditValidator.originalLogs(effective: event.exercises, audit: event.observationAudit,
                    prescription: displayed, config: state.config, schemaVersion: state.schemaVersion)
            }
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
    /// Exact retained rejection plus a no-write pinned-core acceptance proof owns
    /// every allowed outcome demotion. Raw observations and audit remain unchanged.
    static func rejectedCompletionRepair(_ draft: WorkoutDraft, state: ProgramState, rules: Ruleset,
                                         submission: PendingWorkoutFinish) throws -> WorkoutDraft? {
        try validateDraft(draft, state: state, rules: rules)
        do {
            _ = try transition(state: state, command: .workout(completedWorkout: submission.event, next: submission.next), rules: rules)
            return nil
        } catch let error as EngineError {
            guard error.code == "invalid_sets" else { return nil }
        }
        var repaired = draft
        var changed = false
        for (i, row) in draft.displayed.exercises.enumerated() where draft.logs[i].status == .completed {
            let movement = try resolveEffectiveMovement(config: state.config, variantID: row.movementID, rules: rules)
            if !qualifiesCompletedExercise(draft.logs[i], prescription: row, movement: movement, schemaVersion: state.schemaVersion) {
                repaired.logs[i].status = draft.logs[i].actualSets.isEmpty && draft.logs[i].problem == .none ? .skipped : .partial
                changed = true
            }
        }
        guard changed else { return nil }
        var event = submission.event; event.exercises = repaired.logs
        _ = try transition(state: state, command: .workout(completedWorkout: event, next: submission.next), rules: rules)
        repaired.pendingFinish = nil
        return repaired
    }
    static func validateDraft(_ draft: WorkoutDraft, state: ProgramState, rules: Ruleset) throws {
        let displayed = try prepareWorkout(state: state, rules: rules, easierToday: draft.sessionMode == .easier)
        if [3, 4, 5].contains(state.schemaVersion) {
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
        if let attestations = draft.migrationRecoveryAttestations {
            guard state.schemaVersion == 5, let source = state.migration, let start = draft.startedAtMilliseconds,
                  Set(attestations.map(\.movementID)).count == attestations.count,
                  attestations.allSatisfy({ attestation in
                      guard let base = state.config.variants?[attestation.movementID]?.baseMovementID else { return false }
                      return source.baselines.first { $0.baseMovementID == base }?.recoveryRequired == true &&
                          draft.logs.contains { $0.movementID == attestation.movementID } && attestation.externalArchiveHash == source.externalArchiveHash &&
                          attestation.checkedAtMilliseconds >= start
                  }) else { throw invalid("draft_recovery_attestation") }
            for attestation in attestations { _ = try SessionTiming.localDate(milliseconds: attestation.checkedAtMilliseconds, timeZoneID: draft.timeZoneID) }
        }
        for log in draft.logs where log.status == .completed {
            if let base = log.baseMovementID, state.migration?.baselines.first(where: { $0.baseMovementID == base })?.recoveryRequired == true {
                guard draft.migrationRecoveryAttestations?.contains(where: { $0.movementID == log.movementID }) == true else { throw invalid("draft_recovery_attestation") }
            }
        }
        let acknowledged = draft.acknowledgedMovementIDs ?? []
        guard Set(acknowledged).count == acknowledged.count,
              Set(acknowledged).isSubset(of: Set(displayed.exercises.map(\.movementID))),
              draft.restDeadline.map({ $0.timeIntervalSince1970.isFinite && WorkoutDraft.supportedRestDeadlineRange.contains($0) }) ?? true else { throw invalid("draft_ui_metadata") }
        if state.schedulingPolicy == .flexibleV1 {
            guard let start = draft.startedAtMilliseconds,
                  try SessionTiming.localDate(milliseconds: start, timeZoneID: draft.timeZoneID) == draft.date,
                  state.lastSessionDate == nil || draft.date > state.lastSessionDate!,
                  state.migration?.externalLastSessionDate == nil || draft.date > state.migration!.externalLastSessionDate! else { throw invalid("draft_timing") }
        } else {
            guard draft.startedAtMilliseconds == nil, draft.date == displayed.date else { throw invalid("draft_timing") }
        }
        guard draft.programID == state.config.programID, draft.expectedRevision == state.revision,
              try bytes(draft.planned) == bytes(state.activePrescription), try bytes(draft.displayed) == bytes(displayed),
              TimeZone(identifier: draft.timeZoneID) != nil,
              Set(draft.logs.map(\.movementID)).count == draft.logs.count,
              draft.logs.map(\.movementID) == displayed.exercises.map(\.movementID),
              draft.logs.allSatisfy({ log in
                  log.prescriptionID == displayed.id && log.baseMovementID == state.config.variants?[log.movementID]?.baseMovementID &&
                  log.modificationsSnapshot != nil && log.modificationsSnapshot!.utf8.elementsEqual(state.config.variants?[log.movementID]?.modifications.utf8 ?? "".utf8) &&
                  log.actualSets.allSatisfy { $0.reps >= 0 && ($0.leftReps ?? 0) >= 0 && ($0.rightReps ?? 0) >= 0 }
              }) else { throw invalid("draft_binding") }
        try WorkoutFlowResolver.validate(draft)
        _ = try ObservationAuditValidator.originalLogs(effective: draft.logs, audit: draft.observationAudit,
            prescription: draft.displayed, config: state.config, schemaVersion: state.schemaVersion)
        if let pending = draft.pendingFinish {
            guard pending.event.migrationRecoveryAttestations == draft.migrationRecoveryAttestations else { throw invalid("draft_recovery_finish_binding") }
            try WorkoutScheduler.validate(slot: pending.next, config: state.config, schedulingPolicy: state.schedulingPolicy)
            if let timing = pending.event.timing {
                let finishedDate = try timing.validate(sessionDate: draft.date, plannedDate: draft.planned.date)
                let expectedNext = try WorkoutScheduler.nextRotation(after: max(finishedDate, draft.planned.date),
                    consumedSlotID: draft.planned.slotID, config: state.config)
                guard pending.next == expectedNext else { throw invalid("draft_pending_finish_schedule") }
            }
        }
    }
}


extension BackupService {
    static func recoveryRecords(_ document: BackupDocument, migrationCache: MigrationAdmissionCache? = nil) throws -> [ArchivedRecord] {
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
                if migrationCache?.source(archive) == nil, let source = try? JSONDecoder().decode(CausalOriginalArchive.self, from: archive.bytes),
                   source.record.zoneName != CloudRecordCodec.zoneID(dataset).zoneName { continue }
                let canonical = try migrationCache?.canonicalBytes(archive.bytes) ?? CloudRecordCodec.canonicalBytes(archive.bytes)
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
    static func validateGraph(_ document: BackupDocument, migrationCache: MigrationAdmissionCache? = nil) throws -> Replay {
        try validateGraph(document, capturedBatch: nil, migrationCache: migrationCache)
    }
    /// The repository alone uses this for the exact immutable capture from which
    /// it assembled the manifest. Untrusted import/restore use validate instead.
    static func validateCapturedGraph(_ document: BackupDocument, batch: VerifiedCloudBatch, migrationCache: MigrationAdmissionCache? = nil) throws -> Replay {
        try validateGraph(document, capturedBatch: batch, migrationCache: migrationCache)
    }
    private static func validateGraph(_ document: BackupDocument, capturedBatch: VerifiedCloudBatch?, migrationCache: MigrationAdmissionCache? = nil) throws -> Replay {
        guard let graph = document.recovery, graph.version == 1 else { throw invalid("graph_version") }
        try [document.journal, document.rules, document.profiles, document.drafts].forEach(validateObjects)
        // Admit each frozen archive once for this immutable document. Every event
        // still replays with its referenced policy. Repository contexts may retain
        // only byte-bound immutable source admission and root replay evidence.
        var admittedRules: [String: Ruleset] = [:]
        for archive in document.rules {
            guard try archiveHash(archive.bytes, key: "hash") == archive.id else { throw invalid("rules_hash") }
            admittedRules[archive.id] = try rules([archive], hash: archive.id)
        }
        func admittedRule(_ hash: String) throws -> Ruleset {
            guard let rule = admittedRules[hash] else { throw invalid("missing_rules") }
            return rule
        }
        for archive in document.profiles {
            if migrationCache?.source(archive) != nil { continue }
            guard try archiveHash(archive.bytes, key: "contentHash") == archive.id else { throw invalid("profile_hash") }
            try validateStarterProfileRegistration(archive, migrationCache: migrationCache)
        }
        guard Set(graph.quarantines.map(\.id)).count == graph.quarantines.count,
              graph.quarantines.allSatisfy({ hash($0.bytes) == $0.id }) else { throw invalid("portable_quarantine") }
        let batch = try capturedBatch ?? RecoveryVerifier().verify(recoveryRecords(document, migrationCache: migrationCache), migrationCache: migrationCache)
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
            try validateDraft(draft, state: head.returnedState, rules: admittedRule(head.rulesetHash))
        }
        return Replay(histories: histories, heads: heads, recoveryBatch: batch, rulesByHash: admittedRules)
    }
}

import Foundation
import SwiftData
import TrainingCore

/// The sole writer. Every mutation is synchronous within actor isolation: validation,
/// transition, journal/head/outbox/draft changes and save have no suspension point.
@ModelActor actor TrainingRepository {
    private var lease: StoreLease?
    private var archiveDirectory: URL?
    #if DEBUG
    private var failSave = false
    private var commitObserver: (@Sendable (String) -> Void)?
    #endif

    private init(container: ModelContainer, lease: StoreLease, archiveDirectory: URL?) {
        modelContainer = container
        modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
        self.lease = lease
        self.archiveDirectory = archiveDirectory
    }
    static func open(at url: URL, archiveDirectory: URL? = nil) throws -> TrainingRepository {
        let lease = try StoreLease(url: url)
        return TrainingRepository(container: try TrainingMigrationPlan.open(at: url), lease: lease, archiveDirectory: archiveDirectory)
    }
    func close() { modelContext.rollback(); lease = nil }
    private func requireOpen() throws {
        guard lease != nil else { throw EngineError(code: "repository_closed", field: "store") }
        modelContext.autosaveEnabled = false
    }
    private func transaction<T: Sendable>(cloudMetadata: Bool = false, _ body: () throws -> T) throws -> T {
        try requireOpen()
        var attemptedSave = false
        do {
            var output: T?
            var changed = false
            try modelContext.transaction {
                output = try body()
                changed = modelContext.hasChanges
                if changed {
                    attemptedSave = true
                    #if DEBUG
                    commitObserver?("before_save")
                    if failSave { failSave = false; throw EngineError(code: "injected_save_failure", field: "save") }
                    #endif
                    try modelContext.save()
                }
            }
            if changed { didCommit() }
            // ModelContext.transaction executes its closure synchronously or throws.
            guard let output else { preconditionFailure("Transaction did not execute") }
            return output
        } catch {
            modelContext.rollback()
            if cloudMetadata && attemptedSave { throw CloudPersistenceError(underlying: error) }
            throw error
        }
    }
    private func didCommit() {
        #if DEBUG
        commitObserver?("after_commit")
        #endif
    }
    #if DEBUG
    func failNextSave() { failSave = true }
    func observeCommits(_ observer: (@Sendable (String) -> Void)?) { commitObserver = observer }
    #endif
    func counts() throws -> [Int] {
        try requireOpen()
        return try [modelContext.fetchCount(FetchDescriptor<JournalRecord>()), modelContext.fetchCount(FetchDescriptor<ProgramHeadRecord>()),
            modelContext.fetchCount(FetchDescriptor<DraftRecord>()), modelContext.fetchCount(FetchDescriptor<OutboxRecord>()),
            modelContext.fetchCount(FetchDescriptor<QuarantineRecord>())]
    }
    private func head(_ programID: String) throws -> ProgramHeadRecord {
        guard let head = try modelContext.fetch(FetchDescriptor<ProgramHeadRecord>()).first(where: { $0.programID == programID }) else {
            throw EngineError(code: "program_not_found", field: "programID")
        }
        return head
    }
    private func rule(_ hash: String) throws -> Ruleset { try BackupService.rules(rawBackup().rules, hash: hash) }
    private func archiveData(_ name: String, relative: String) throws -> Data {
        let url: URL
        if let archiveDirectory { url = archiveDirectory.appendingPathComponent(relative) }
        else {
            guard let bundled = Bundle.main.url(forResource: name, withExtension: "json") else { throw BackupService.invalid("missing_bundled_archive") }
            url = bundled
        }
        return try Data(contentsOf: url)
    }
    private func bundledArchives(ruleset: Ruleset) throws -> (ArchivedObject, [ArchivedObject]) {
        let name: String
        switch ruleset.version {
        case "general-fitness-swift1": name = "ruleset-swift1"
        case "general-fitness-exact-v1": name = "ruleset-exact-v1"
        default: throw EngineError(code: "unsupported_version", field: "rules")
        }
        let rules = try archiveData(name, relative: "Packages/TrainingCore/Sources/TrainingCore/Resources/\(name).json")
        let profile = try archiveData("fixed-exercise-profile", relative: "Packages/TrainingCore/Sources/TrainingCore/Resources/fixed-exercise-profile.json")
        let source = try archiveData("2026-10-05-fixed-exercise-profile", relative: "docs/specs/2026-10-05-fixed-exercise-profile.json")
        func object(_ bytes: Data, key: String) throws -> ArchivedObject {
            ArchivedObject(id: try BackupService.archiveHash(bytes, key: key), bytes: bytes, checksum: BackupService.hash(bytes))
        }
        return (try object(rules, key: "hash"), try [object(profile, key: "contentHash"), object(source, key: "contentHash")])
    }
    private func putArchives(rules: [ArchivedObject], profiles: [ArchivedObject]) throws {
        let existingRules = try modelContext.fetch(FetchDescriptor<RuleArchiveRecord>())
        for archive in rules {
            if let saved = existingRules.first(where: { $0.contentHash == archive.id }) {
                guard saved.bytes == archive.bytes else { throw BackupService.invalid("rule_archive_conflict") }
            } else { modelContext.insert(RuleArchiveRecord(hash: archive.id, bytes: archive.bytes)) }
        }
        let existingProfiles = try modelContext.fetch(FetchDescriptor<ProfileArchiveRecord>())
        for archive in profiles {
            if let saved = existingProfiles.first(where: { $0.contentHash == archive.id }) {
                guard saved.bytes == archive.bytes else { throw BackupService.invalid("profile_archive_conflict") }
            } else { modelContext.insert(ProfileArchiveRecord(hash: archive.id, bytes: archive.bytes)) }
        }
    }
    private func envelope(programID: String, eventID: String, datasetID: String, command: JournalCommand,
                          parent: JournalEnvelope?, result: ConfigurationResult, rules: Ruleset) throws -> JournalEnvelope {
        let config = result.state.config
        // Numeric schema-1 configs may omit optional profile fields. The
        // verified selected parent owns their frozen archive references; never
        // insert current profile values into the legacy serialized config.
        let legacyParent = result.state.schemaVersion == 1 ? parent : nil
        guard let profileID = config.profileID ?? legacyParent?.profileID,
              let profileHash = config.profileHash ?? legacyParent?.profileHash,
              let sourceProfileID = config.sourceProfileID ?? legacyParent?.sourceProfileID,
              let sourceProfileHash = config.sourceProfileHash ?? legacyParent?.sourceProfileHash else {
            throw EngineError(code: "invalid_input", field: "profile_references")
        }
        var envelope = JournalEnvelope(schemaVersion: result.state.schemaVersion, datasetID: datasetID, programID: programID, eventID: eventID,
            eventHash: try BackupService.eventHash(command), parentEnvelopeHash: parent?.envelopeHash,
            inputRevision: parent?.returnedState.revision ?? -1,
            inputStateHash: try parent.map { try BackupService.hash($0.returnedState) },
            rulesetVersion: rules.version, rulesetHash: rules.hash, profileID: profileID, profileHash: profileHash,
            sourceProfileID: sourceProfileID, sourceProfileHash: sourceProfileHash, command: command,
            returnedState: result.state, returnedPrescription: result.workout, decisions: result.decisions, envelopeHash: "")
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        return envelope
    }
    private func persist(_ envelope: JournalEnvelope) throws {
        guard try !modelContext.fetch(FetchDescriptor<JournalRecord>()).contains(where: { $0.eventID == envelope.eventID }),
              try !modelContext.fetch(FetchDescriptor<OutboxRecord>()).contains(where: { $0.key == envelope.eventID }) else { throw BackupService.invalid("unique_key_conflict") }
        modelContext.insert(JournalRecord(eventID: envelope.eventID, programID: envelope.programID, revision: envelope.returnedState.revision,
            bytes: try BackupService.bytes(envelope), hash: envelope.envelopeHash))
        if let existing = try modelContext.fetch(FetchDescriptor<ProgramHeadRecord>()).first(where: { $0.programID == envelope.programID }) {
            existing.revision = envelope.returnedState.revision; existing.bytes = try BackupService.bytes(envelope.returnedState)
            existing.headHash = envelope.envelopeHash
        } else {
            modelContext.insert(ProgramHeadRecord(programID: envelope.programID, revision: envelope.returnedState.revision,
                bytes: try BackupService.bytes(envelope.returnedState), headHash: envelope.envelopeHash, datasetID: envelope.datasetID))
        }
        let pending = OutboxRecord(key: envelope.eventID, datasetID: envelope.datasetID, payloadHash: envelope.envelopeHash)
        do { pending.accountScope = try cloudBindings().datasets[envelope.datasetID] }
        catch CloudFailure.bindingMetadataUnavailable {
            // Optional association bytes are preserved for repair. Healthy local
            // acceptance still commits an unscoped durable reference; cloud reads
            // and explicit binding remain fail-closed against the unreadable slot.
            pending.accountScope = nil
        }
        modelContext.insert(pending)
    }
    func initialize(config: ProgramConfig, rules: Ruleset, firstWorkout: WorkoutSlot, datasetID requestedDatasetID: UUID? = nil) throws -> StoreSnapshot {
        let programUUID: UUID = try transaction {
            guard ["general-fitness-swift1", "general-fitness-exact-v1"].contains(rules.version), config.profileHash != nil, let programUUID = UUID(uuidString: config.programID) else { throw EngineError(code: "unsupported_version", field: "initialize") }
            guard config.programID == programUUID.uuidString.lowercased() else { throw BackupService.invalid("program_uuid_spelling") }
            let archives = try bundledArchives(ruleset: rules)
            guard archives.0.id == rules.hash else { throw BackupService.invalid("initial_rules") }
            let initialized = try initializeProgram(config: config, rules: rules, firstWorkout: firstWorkout)
            let existing = try modelContext.fetch(FetchDescriptor<ProgramHeadRecord>())
            guard !existing.contains(where: { $0.programID == config.programID }) else { throw BackupService.invalid("program_exists") }
            let datasets = Set(existing.map(\.datasetID))
            if let requestedDatasetID, datasets.contains(requestedDatasetID.uuidString.lowercased()) { throw BackupService.invalid("dataset_exists") }
            let datasetID = requestedDatasetID?.uuidString.lowercased() ?? (datasets.count == 1 ? datasets.first! : UUID().uuidString.lowercased())
            let envelope = try envelope(programID: config.programID, eventID: UUID().uuidString.lowercased(), datasetID: datasetID,
                command: .initialize(config: config, firstWorkout: firstWorkout), parent: nil,
                result: ConfigurationResult(state: initialized.state, workout: initialized.workout, decisions: []), rules: rules)
            _ = try BackupService.validate(BackupDocument(datasetID: datasetID, heads: [config.programID: envelope.envelopeHash], journal: [BackupService.object(envelope, id: envelope.eventID)],
                rules: [archives.0], profiles: archives.1, drafts: []))
            try putArchives(rules: [archives.0], profiles: archives.1)
            try persist(envelope)
            return programUUID
        }
        return try snapshot(programID: programUUID)
    }
    private func rawBackup() throws -> BackupDocument {
        let heads = try modelContext.fetch(FetchDescriptor<ProgramHeadRecord>())
        let datasets = Set(heads.map(\.datasetID))
        func object(_ id: String, _ data: Data) -> ArchivedObject { ArchivedObject(id: id, bytes: data, checksum: BackupService.hash(data)) }
        let journal = try modelContext.fetch(FetchDescriptor<JournalRecord>()).sorted { ($0.programID, $0.revision, $0.eventID) < ($1.programID, $1.revision, $1.eventID) }
        var document = BackupDocument(datasetID: datasets.sorted().first ?? "empty", heads: Dictionary(uniqueKeysWithValues: heads.map { ($0.programID, $0.headHash) }), journal: journal.map { object($0.eventID, $0.bytes) },
            rules: try modelContext.fetch(FetchDescriptor<RuleArchiveRecord>()).sorted { $0.contentHash < $1.contentHash }.map { object($0.contentHash, $0.bytes) },
            profiles: try modelContext.fetch(FetchDescriptor<ProfileArchiveRecord>()).sorted { $0.contentHash < $1.contentHash }.map { object($0.contentHash, $0.bytes) },
            drafts: try modelContext.fetch(FetchDescriptor<DraftRecord>()).sorted { $0.id.uuidString < $1.id.uuidString }.map { object($0.id.uuidString.lowercased(), $0.bytes) })
        let recovery = try recoveryState()
        let quarantines = try modelContext.fetch(FetchDescriptor<QuarantineRecord>()).sorted { $0.id < $1.id }.map { PortableQuarantine(id: $0.id, bytes: $0.bytes, reason: $0.reason) }
        if recovery.originals.isEmpty && quarantines.isEmpty && datasets.count <= 1 && recovery.graphRequired != true { return document }
        let legacyOriginals = try quarantines.filter { $0.reason == "backup_branch_conflict" }.flatMap {
            try BackupService.recoveryRecords(JSONDecoder().decode(BackupDocument.self, from: $0.bytes))
        }
        let originals = try Dictionary((recovery.originals + legacyOriginals).map { (try $0.key, $0) }, uniquingKeysWith: { first, _ in first }).sorted { $0.key < $1.key }.map(\.value)
        let batch = try RecoveryVerifier().verify(BackupService.recoveryRecords(document) + originals)
        let branched = batch.heads.values.contains { $0.count > 1 }
        let resolutions = batch.envelopes.values.contains { if case .resolveConflict = $0.command { return true }; return false }
        if datasets.count > 1 || branched || resolutions || !recovery.originals.isEmpty || !quarantines.isEmpty || recovery.graphRequired == true {
            document.formatVersion = 2
            document.recovery = BackupService.graphManifest(batch, originals: originals, quarantines: quarantines, resolved: recovery.resolvedQuarantineKeys)
        }
        return document
    }
    func exportBackup() throws -> BackupDocument {
        try requireOpen()
        let document = try rawBackup()
        let replay = try BackupService.validate(document)
        let heads = try modelContext.fetch(FetchDescriptor<ProgramHeadRecord>())
        guard heads.count == replay.heads.count else { throw BackupService.invalid("head_count") }
        for head in heads {
            guard let accepted = replay.heads[head.programID], head.revision == accepted.returnedState.revision,
                  head.headHash == accepted.envelopeHash, head.bytes == (try BackupService.bytes(accepted.returnedState)) else { throw BackupService.invalid("head_projection") }
        }
        let records = try modelContext.fetch(FetchDescriptor<JournalRecord>())
        let outbox = try modelContext.fetch(FetchDescriptor<OutboxRecord>())
        guard (document.formatVersion != 1 || records.count == outbox.count), outbox.allSatisfy({ row in records.contains { $0.eventID == row.key } }) else { throw BackupService.invalid("outbox_count") }
        for record in records {
            let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: record.bytes)
            guard record.contentHash == envelope.envelopeHash, record.programID == envelope.programID, record.revision == envelope.returnedState.revision,
                  (outbox.first(where: { $0.key == record.eventID }).map { $0.payloadHash == record.contentHash && $0.datasetID == envelope.datasetID } ?? true) else { throw BackupService.invalid("journal_projection") }
        }
        return document
    }
    func snapshot(programID: UUID) throws -> StoreSnapshot {
        let document = try exportBackup()
        let replay = try BackupService.validate(document)
        let id = programID.uuidString.lowercased()
        guard let history = replay.histories[id], let head = replay.heads[id] else { throw EngineError(code: "program_not_found", field: "programID") }
        let draft = try document.drafts.map { try JSONDecoder().decode(WorkoutDraft.self, from: $0.bytes) }.first { $0.programID == id }
        let health: StoreHealth
        if document.formatVersion == 1 { health = .ready }
        else { health = try recoveryHealth(programID: id, batch: RecoveryVerifier().verify(BackupService.recoveryRecords(document))) }
        return StoreSnapshot(state: head.returnedState, draft: draft, history: history, decisions: history.flatMap(\.decisions), health: health)
    }
    /// Exact archive lookup; original drafts and repair commands use their own policy.
    func rules(for state: ProgramState) throws -> Ruleset {
        try requireOpen()
        let rules = try rule(state.rulesetHash)
        guard state.rulesetVersion == rules.version else { throw BackupService.invalid("state_rules") }
        _ = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
        return rules
    }
    func activateExactPolicy(programID: UUID, expectedRevision: Int, expectedHeadHash: String) throws -> StoreSnapshot {
        try transaction {
            let current = try snapshot(programID: programID)
            guard current.health == .ready else { throw EngineError(code: "store_" + current.health.rawValue, field: "health") }
            let parent = try projectedEnvelope(current.state.config.programID)
            guard current.state.revision == expectedRevision else { throw EngineError(code: "stale_revision", field: "expectedRevision") }
            guard parent.envelopeHash == expectedHeadHash else { throw EngineError(code: "stale_head", field: "expectedHeadHash") }
            guard current.draft == nil else { throw EngineError(code: "policy_activation_draft_locked", field: "draft") }
            let source = try rules(for: current.state)
            let destination = try RulesetCatalog.exactV1()
            if current.state.schemaVersion == 3, source == destination { return }
            let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(rawBackup()))
            let prefix = try RecoveryVerifier.ancestors(parent.envelopeHash, envelopes: proof.envelopes).compactMap { proof.envelopes[$0] }
            let evidence = try policyActivationEvidenceEventIDs(state: current.state, history: prefix)
            let pending = current.state.activePrescription
            let command = JournalCommand.activatePolicy(sourceRulesetHash: source.hash, destinationRulesetHash: destination.hash,
                normalEvidenceEventIDs: evidence, next: WorkoutSlot(date: pending.date, slotID: pending.slotID))
            let result = try BackupService.transition(state: current.state, command: command, rules: destination, legacyHistory: prefix)
            if try !modelContext.fetch(FetchDescriptor<RuleArchiveRecord>()).contains(where: { $0.contentHash == destination.hash }) {
                let archives = try bundledArchives(ruleset: destination)
                guard archives.0.id == destination.hash else { throw BackupService.invalid("activation_archive") }
                try putArchives(rules: [archives.0], profiles: [])
            }
            let accepted = try envelope(programID: current.state.config.programID, eventID: UUID().uuidString.lowercased(),
                datasetID: parent.datasetID, command: command, parent: parent, result: result, rules: destination)
            try persist(accepted)
            _ = try exportBackup()
        }
        return try snapshot(programID: programID)
    }
    func finalize(programID: UUID, expectedRevision: Int, event: CompletedWorkout, next: WorkoutSlot) throws -> FinalizationReceipt {
        let result: AdvanceResult = try transaction {
            let current = try snapshot(programID: programID)
            let command = JournalCommand.workout(completedWorkout: event, next: next)
            let originals = current.history.filter { $0.eventID == event.eventID }
            if !originals.isEmpty {
                let eventHash = try BackupService.hash(event)
                return originals.contains(where: { $0.eventHash == eventHash })
                    ? .noOp(nextState: current.state, reason: .eventReplayed)
                    : .rejected(nextState: current.state, errors: ["event_id_conflict"])
            }
            if try modelContext.fetch(FetchDescriptor<JournalRecord>()).contains(where: { $0.eventID == event.eventID }) {
                return .rejected(nextState: current.state, errors: ["event_id_conflict"])
            }
            guard current.health == .ready else { return .rejected(nextState: current.state, errors: ["store_" + current.health.rawValue]) }
            guard expectedRevision == current.state.revision else { return .rejected(nextState: current.state, errors: ["stale_revision"]) }
            if let draft = current.draft {
                guard draft.id.uuidString.lowercased() == event.eventID.lowercased(), draft.planned.id == event.plannedPrescriptionID,
                      draft.displayed.id == event.prescriptionID, draft.date == event.date,
                      try BackupService.bytes(draft.logs) == BackupService.bytes(event.exercises), draft.sessionMode == event.sessionMode else {
                    return .rejected(nextState: current.state, errors: ["draft_binding_conflict"])
                }
            }
            let rules = try rule(current.state.rulesetHash)
            let result: ConfigurationResult
            do { result = try BackupService.transition(state: current.state, command: command, rules: rules) }
            catch let error as EngineError { return .rejected(nextState: current.state, errors: [error.code]) }
            let accepted = try envelope(programID: current.state.config.programID, eventID: event.eventID,
                datasetID: current.history[0].datasetID, command: command, parent: try projectedEnvelope(current.state.config.programID), result: result, rules: rules)
            try persist(accepted)
            for draft in try modelContext.fetch(FetchDescriptor<DraftRecord>()) where draft.programID == accepted.programID { modelContext.delete(draft) }
            return .applied(nextState: result.state, nextWorkout: result.workout, decisions: result.decisions)
        }
        return FinalizationReceipt(result: result, snapshot: try snapshot(programID: programID))
    }
    private func apply(programID: UUID, expectedRevision: Int, command: JournalCommand, invalidateEmptyDraft: Bool) throws -> StoreSnapshot {
        try transaction {
            let current = try snapshot(programID: programID)
            guard current.health == .ready else { throw EngineError(code: "store_" + current.health.rawValue, field: "health") }
            guard expectedRevision == current.state.revision else { throw EngineError(code: "stale_revision", field: "expectedRevision") }
            let rules = try rule(current.state.rulesetHash)
            let result = try BackupService.transition(state: current.state, command: command, rules: rules)
            guard result.state.revision != current.state.revision else { return }
            if let draft = current.draft {
                guard !draft.hasObservations else { throw EngineError(code: "working_draft_locked", field: "draft") }
                guard invalidateEmptyDraft else { throw EngineError(code: "draft_requires_explicit_invalidation", field: "draft") }
            }
            let accepted = try envelope(programID: current.state.config.programID, eventID: UUID().uuidString.lowercased(),
                datasetID: current.history[0].datasetID, command: command, parent: try projectedEnvelope(current.state.config.programID), result: result, rules: rules)
            try persist(accepted)
            for draft in try modelContext.fetch(FetchDescriptor<DraftRecord>()) where draft.programID == accepted.programID { modelContext.delete(draft) }
        }
        return try snapshot(programID: programID)
    }
    func applyConfiguration(programID: UUID, expectedRevision: Int, change: ConfigurationChange, next: WorkoutSlot, invalidateEmptyDraft: Bool = false) throws -> StoreSnapshot {
        try apply(programID: programID, expectedRevision: expectedRevision, command: .reconfigure(change: change, next: next), invalidateEmptyDraft: invalidateEmptyDraft)
    }
    func applyVariantChange(programID: UUID, expectedRevision: Int, change: VariantChange, next: WorkoutSlot, invalidateEmptyDraft: Bool = false) throws -> StoreSnapshot {
        try apply(programID: programID, expectedRevision: expectedRevision, command: .variantChange(change: change, next: next), invalidateEmptyDraft: invalidateEmptyDraft)
    }
    func reschedule(programID: UUID, expectedRevision: Int, slot: WorkoutSlot, invalidateEmptyDraft: Bool = false) throws -> StoreSnapshot {
        try apply(programID: programID, expectedRevision: expectedRevision, command: .reschedule(slot: slot), invalidateEmptyDraft: invalidateEmptyDraft)
    }
    func prepareReturn(programID: UUID, expectedRevision: Int, asOf: LocalDate) throws -> StoreSnapshot {
        try apply(programID: programID, expectedRevision: expectedRevision, command: .interruption(asOf: asOf), invalidateEmptyDraft: false)
    }
    func saveDraft(_ draft: WorkoutDraft, expectedExistingDraft: WorkoutDraft? = nil) throws {
        try transaction {
            guard let id = UUID(uuidString: draft.programID) else { throw BackupService.invalid("draft_program") }
            let current = try snapshot(programID: id)
            try BackupService.validateDraft(draft, state: current.state, rules: rule(current.state.rulesetHash))
            if let expected = expectedExistingDraft {
                // Explicit unaccepted-completion repair proof: canonical exact draft,
                // unchanged revision and globally absent event, checked atomically.
                guard let existing = current.draft, current.state.revision == expected.expectedRevision,
                      try BackupService.bytes(existing) == BackupService.bytes(expected),
                      try !modelContext.fetch(FetchDescriptor<JournalRecord>()).contains(where: { $0.eventID == expected.id.uuidString.lowercased() }) else {
                    throw BackupService.invalid("draft_repair_proof_changed")
                }
            }
            if let existing = current.draft {
                guard existing.id == draft.id, existing.date == draft.date, existing.timeZoneID == draft.timeZoneID,
                      existing.planned == draft.planned, existing.displayed == draft.displayed,
                      (!existing.workingSetsStarted || draft.workingSetsStarted),
                      (!existing.hasObservations || draft.hasObservations) else { throw BackupService.invalid("draft_identity") }
                // Ordinary saves may append performed sets and update effort/status,
                // but cannot rewrite recorded reps/sides/load or remove a safety flag.
                // Corrections require an explicit path that retains the originals.
                for original in existing.logs {
                    guard let updated = draft.logs.first(where: { $0.movementID == original.movementID }),
                          updated.actualSets.starts(with: original.actualSets),
                          original.actualSets.isEmpty || updated.actualLoad == original.actualLoad,
                          original.problem == .none || updated.problem == original.problem else {
                        throw BackupService.invalid("draft_observation_changed")
                    }
                }
            }
            do {
                let records = try modelContext.fetch(FetchDescriptor<DraftRecord>())
                if let record = records.first(where: { $0.id == draft.id }) {
                    guard record.programID == draft.programID else { throw BackupService.invalid("draft_id_conflict") }
                    record.bytes = try BackupService.bytes(draft)
                } else { modelContext.insert(DraftRecord(id: draft.id, programID: draft.programID, bytes: try BackupService.bytes(draft))) }
            }
        }
    }
    func discardDraft(id: UUID) throws {
        try transaction {
            for record in try modelContext.fetch(FetchDescriptor<DraftRecord>()) where record.id == id { modelContext.delete(record) }
        }
    }
    func importBackup(_ document: BackupDocument) throws -> ImportReceipt {
        return try transaction {
            if document.formatVersion == 2 { return try importGraph(document) }
            let incoming = try BackupService.validate(document)
            let original = try exportBackup()
            let local = try BackupService.validate(original)
            let sameDataset = original.journal.isEmpty || original.datasetID == document.datasetID
            let localObjects = Dictionary(uniqueKeysWithValues: original.journal.map { ($0.id, $0) })
            var identical = 0
            var conflicts: [ArchivedObject] = []
            var accepted: [JournalEnvelope] = []
            for program in incoming.histories.keys.sorted() {
                let history = incoming.histories[program]!
                let own = local.histories[program] ?? []
                let compatible = sameDataset && own.count <= history.count && zip(own, history).allSatisfy { $0.envelopeHash == $1.envelopeHash }
                let shorterIdentical = sameDataset && history.count <= own.count && zip(history, own).allSatisfy { $0.envelopeHash == $1.envelopeHash }
                if !compatible && !shorterIdentical { conflicts += document.journal.filter { item in history.contains { $0.eventID == item.id } }; continue }
                for envelope in history {
                    if let saved = localObjects[envelope.eventID] {
                        if saved.bytes == (try BackupService.bytes(envelope)) { identical += 1 }
                        else { conflicts.append(try BackupService.object(envelope, id: envelope.eventID)) }
                    } else { accepted.append(envelope) }
                }
            }
            // A single conflicting object makes the incoming recovery atomic: quarantine
            // the original entire document, preserve every original accepted object.
            if !conflicts.isEmpty {
                let raw = try BackupService.bytes(document)
                let key = BackupService.hash(raw)
                do {
                    if try !modelContext.fetch(FetchDescriptor<QuarantineRecord>()).contains(where: { $0.id == key }) {
                        modelContext.insert(QuarantineRecord(id: key, bytes: raw, reason: "backup_branch_conflict"))
                    }
                }
                return ImportReceipt(accepted: 0, identical: identical, conflicted: conflicts.count)
            }
            // Validate merged heads/drafts before touching the context, including prefix imports.
            var merged = original.journal.isEmpty ? document : original
            if !original.journal.isEmpty {
                merged.journal += try accepted.map { try BackupService.object($0, id: $0.eventID) }
                for envelope in accepted { merged.heads[envelope.programID] = envelope.envelopeHash }
                for item in document.rules where !merged.rules.contains(where: { $0.id == item.id }) { merged.rules.append(item) }
                for item in document.profiles where !merged.profiles.contains(where: { $0.id == item.id }) { merged.profiles.append(item) }
                for item in document.drafts {
                    if let own = merged.drafts.first(where: { $0.id == item.id }), own.bytes != item.bytes { throw BackupService.invalid("draft_import_conflict") }
                    if !merged.drafts.contains(where: { $0.id == item.id }) { merged.drafts.append(item) }
                }
            }
            _ = try BackupService.validate(merged)
            do {
                try putArchives(rules: document.rules, profiles: document.profiles)
                for envelope in accepted.sorted(by: { ($0.programID, $0.returnedState.revision) < ($1.programID, $1.returnedState.revision) }) { try persist(envelope) }
                for item in document.drafts {
                    let draft = try JSONDecoder().decode(WorkoutDraft.self, from: item.bytes)
                    if try !modelContext.fetch(FetchDescriptor<DraftRecord>()).contains(where: { $0.id == draft.id }) {
                        modelContext.insert(DraftRecord(id: draft.id, programID: draft.programID, bytes: item.bytes))
                    }
                }
            }
            return ImportReceipt(accepted: accepted.count, identical: identical, conflicted: 0)
        }
    }
}

// Transport metadata uses existing opaque cursor slots. TrainingSchemaV1 stays
// frozen; original V1 stores reopen without migration or training-row rewrites.
extension TrainingRepository {
    private static var bindingsKey: String { "cloud-bindings-v1" }
    private func metadataBytes(key: String) throws -> Data? {
        try modelContext.fetch(FetchDescriptor<CloudCursorRecord>()).first { $0.accountScope == key }?.bytes
    }
    private func putMetadataBytes(_ bytes: Data, key: String) throws {
        if let row = try modelContext.fetch(FetchDescriptor<CloudCursorRecord>()).first(where: { $0.accountScope == key }) {
            row.bytes = bytes
        } else { modelContext.insert(CloudCursorRecord(accountScope: key, bytes: bytes)) }
    }
    private func cloudBindings() throws -> CloudBindings {
        guard let bytes = try metadataBytes(key: Self.bindingsKey) else { return .init() }
        do {
            let bindings = try JSONDecoder().decode(CloudBindings.self, from: bytes)
            guard bindings.version == 1 else { throw CloudFailure.bindingMetadataUnavailable }
            return bindings
        } catch { throw CloudFailure.bindingMetadataUnavailable }
    }
    func cloudMetadata(scope: CloudScope) throws -> CloudScopeMetadata {
        try requireOpen()
        guard let bytes = try metadataBytes(key: scope.key) else { return .init() }
        let metadata = try JSONDecoder().decode(CloudScopeMetadata.self, from: bytes)
        guard metadata.version == 1 else { throw BackupService.invalid("cloud_metadata_version") }
        return metadata
    }
    func bindDataset(datasetID: UUID, to scope: CloudScope) throws {
        try transaction(cloudMetadata: true) {
            let id = datasetID.uuidString.lowercased()
            var bindings = try cloudBindings()
            guard bindings.datasets[id] == nil || bindings.datasets[id] == scope.key else { throw BackupService.invalid("dataset_account_binding") }
            let rows = try modelContext.fetch(FetchDescriptor<OutboxRecord>()).filter { $0.datasetID == id }
            guard rows.allSatisfy({ $0.accountScope == nil || $0.accountScope == scope.key }) else { throw BackupService.invalid("dataset_binding") }
            if rows.isEmpty {
                let document = try rawBackup()
                let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
                guard proof.envelopes.values.contains(where: { $0.parentEnvelopeHash == nil && $0.datasetID == id && { if case .initialize = $0.command { return true }; return false }($0) }) else { throw BackupService.invalid("dataset_binding") }
            }
            bindings.datasets[id] = scope.key
            for row in rows { row.accountScope = scope.key }
            try putMetadataBytes(JSONEncoder().encode(bindings), key: Self.bindingsKey)
        }
    }
    private func allCloudRecords(scope: CloudScope, includeReceived: Bool = false) throws -> [PendingCloudRecord] {
        try requireOpen()
        let metadata = try cloudMetadata(scope: scope)
        let bindings = try cloudBindings()
        var rows = try modelContext.fetch(FetchDescriptor<OutboxRecord>()).filter { $0.accountScope == scope.key && bindings.datasets[$0.datasetID] == scope.key }.map { (key: $0.key, datasetID: $0.datasetID, payloadHash: $0.payloadHash) }
        let journals = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<JournalRecord>()).map { ($0.eventID, $0) })
        if includeReceived {
            let known = Set(rows.map(\.key))
            for journal in journals.values where !known.contains(journal.eventID) {
                let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: journal.bytes)
                if bindings.datasets[envelope.datasetID] == scope.key {
                    rows.append((key: journal.eventID, datasetID: envelope.datasetID, payloadHash: envelope.envelopeHash))
                }
            }
        }
        var output: [PendingCloudRecord] = []
        var archives: [String: (UUID, String, Data)] = [:]
        let storedArchives = try modelContext.fetch(FetchDescriptor<RuleArchiveRecord>()).map { ($0.contentHash, $0.bytes, "hash") } +
            modelContext.fetch(FetchDescriptor<ProfileArchiveRecord>()).map { ($0.contentHash, $0.bytes, "contentHash") }
        for row in rows {
            guard let dataset = UUID(uuidString: row.datasetID), let journal = journals[row.key] else { throw BackupService.invalid("cloud_outbox_journal") }
            let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: journal.bytes)
            guard envelope.datasetID == row.datasetID, envelope.envelopeHash == row.payloadHash,
                  envelope.envelopeHash == (try BackupService.envelopeHash(envelope)),
                  journal.contentHash == row.payloadHash,
                  journal.bytes == (try CloudRecordCodec.canonicalBytes(journal.bytes)) else { throw BackupService.invalid("cloud_journal_integrity") }
            var hashes = [envelope.rulesetHash, envelope.profileHash, envelope.sourceProfileHash]
            if case let .resolveConflict(_, _, originals, _) = envelope.command { hashes += originals }
            var references: [String] = []
            for hash in hashes {
                let name = try CloudRecordCodec.recordName(kind: .archive, datasetID: dataset, identity: hash)
                // Frozen archives are shared across events. Validate/canonicalize
                // each dataset/archive once per query, not once per ancestor.
                if archives[name] == nil {
                    guard let archive = storedArchives.first(where: { $0.0 == hash }),
                          try BackupService.archiveHash(archive.1, key: archive.2) == hash else { throw BackupService.invalid("cloud_archive_missing") }
                    archives[name] = (dataset, hash, try CloudRecordCodec.canonicalBytes(archive.1))
                }
                references.append(name)
            }
            let name = try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: row.key)
            output.append(PendingCloudRecord(recordID: name, kind: .journal, datasetID: dataset, identity: row.key,
                payload: journal.bytes, checksum: BackupService.hash(journal.bytes), archiveReferences: references,
                programID: envelope.programID, isRoot: envelope.parentEnvelopeHash == nil,
                isCompletedWorkout: CloudRecordCodec.isWorkout(envelope.command), systemFields: metadata.acknowledgements[name]?.systemFields))
        }
        for (name, archive) in archives {
            output.append(PendingCloudRecord(recordID: name, kind: .archive, datasetID: archive.0, identity: archive.1,
                payload: archive.2, checksum: BackupService.hash(archive.2), archiveReferences: [], programID: nil,
                isRoot: false, isCompletedWorkout: false, systemFields: metadata.acknowledgements[name]?.systemFields))
        }
        return output.sorted { ($0.kind.rawValue, $0.recordID) < ($1.kind.rawValue, $1.recordID) }
    }
    func pendingCloudRecords(scope: CloudScope) throws -> [PendingCloudRecord] {
        let metadata = try cloudMetadata(scope: scope)
        let covered = try cloudSourceCoverage(scope: scope).covered
        return try allCloudRecords(scope: scope).filter { metadata.acknowledgements[$0.recordID]?.verifiedHash != $0.checksum && !covered.contains($0.recordID + ":" + $0.checksum) }
    }
    func acknowledge(records: [CloudAcknowledgement], scope: CloudScope) throws {
        try transaction(cloudMetadata: true) {
            var metadata = try cloudMetadata(scope: scope)
            let known = try allCloudRecords(scope: scope)
            for ack in records {
                guard let record = known.first(where: { $0.recordID == ack.recordID }), record.checksum == ack.verifiedHash,
                      !metadata.conflictingRecordIDs.contains(ack.recordID) else { throw BackupService.invalid("cloud_ack_scope_hash") }
                if let old = metadata.acknowledgements[ack.recordID] {
                    guard old.verifiedHash == ack.verifiedHash else { throw BackupService.invalid("cloud_ack_conflict") }
                    continue
                }
                metadata.acknowledgements[ack.recordID] = .init(verifiedHash: ack.verifiedHash, systemFields: ack.systemFields, date: Date())
                if record.kind == .journal {
                    let row = try modelContext.fetch(FetchDescriptor<OutboxRecord>()).first { $0.key == record.identity && $0.accountScope == scope.key }
                    row?.acknowledged = true
                }
            }
            try putMetadataBytes(JSONEncoder().encode(metadata), key: scope.key)
        }
    }
    func saveCloudCursor(_ data: Data, scope: CloudScope) throws {
        try transaction(cloudMetadata: true) {
            var metadata = try cloudMetadata(scope: scope); metadata.cursor = data
            try putMetadataBytes(JSONEncoder().encode(metadata), key: scope.key)
        }
    }
    func cloudCursor(scope: CloudScope) throws -> Data? { try cloudMetadata(scope: scope).cursor }
    /// Stage actual bytes, including changed duplicates; this never imports heads.
    func retainCloudObservations(_ observations: [CloudObservation], deletedRecordIDs: [String] = [], scope: CloudScope) throws {
        try transaction(cloudMetadata: true) {
            var metadata = try cloudMetadata(scope: scope)
            let known = Dictionary(uniqueKeysWithValues: try allCloudRecords(scope: scope, includeReceived: true).map { ($0.recordID, $0) })
            for observation in observations {
                // Full original observation identity preserves another source's
                // system fields even when its changed payload bytes repeat.
                let key = try BackupService.hash(observation)
                metadata.observations[key] = observation
                if let local = known[observation.recordID], !CloudRecordCodec.matches(observation, pending: local) {
                    metadata.conflictingRecordIDs.insert(observation.recordID)
                }
            }
            metadata.deletedRecordIDs.formUnion(deletedRecordIDs)
            try putMetadataBytes(JSONEncoder().encode(metadata), key: scope.key)
        }
    }
    /// Shared immutable response policy used by the real engine and test server.
    func acceptCloudSaveObservation(_ observation: CloudObservation, scope: CloudScope) throws {
        // Retain before comparison so a conflict is not rolled back with an error.
        try retainCloudObservations([observation], scope: scope)
        guard let pending = try allCloudRecords(scope: scope).first(where: { $0.recordID == observation.recordID }) else {
            throw BackupService.invalid("cloud_response_scope")
        }
        if CloudRecordCodec.matches(observation, pending: pending) {
            try acknowledge(records: [.init(recordID: observation.recordID, verifiedHash: pending.checksum, systemFields: observation.systemFields)], scope: scope)
        } else {
            // Retention and known-ID quarantine already committed atomically.
            throw BackupService.invalid("cloud_immutable_conflict")
        }
    }
    func cloudStatus(scope: CloudScope) throws -> SyncStatus {
        let metadata = try cloudMetadata(scope: scope)
        let records = try allCloudRecords(scope: scope, includeReceived: true)
        let uploadIDs = Set(try allCloudRecords(scope: scope).map(\.recordID))
        let coverage = try cloudSourceCoverage(scope: scope)
        let pending = records.filter { uploadIDs.contains($0.recordID) && metadata.acknowledgements[$0.recordID]?.verifiedHash != $0.checksum && !coverage.covered.contains($0.recordID + ":" + $0.checksum) }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) })
        let completed = coverage.completed
        let incomplete = coverage.incomplete || (pending.isEmpty && coverage.pendingCompleted > 0) || !metadata.deletedRecordIDs.isEmpty || metadata.observations.values.contains { observation in
            guard let record = byID[observation.recordID] else { return true }
            return !CloudRecordCodec.matches(observation, pending: record)
        }
        return SyncStatus(phase: !metadata.conflictingRecordIDs.isEmpty ? .conflict : incomplete ? .incomplete : pending.isEmpty ? .upToDateForKnownRecords : .pending,
            pendingRecordCount: pending.count, pendingCompletedWorkoutCount: coverage.pendingCompleted, acknowledgedCompletedWorkoutCount: completed,
            lastRecordAcknowledgement: metadata.acknowledgements.values.map(\.date).max(), retryReason: nil)
    }
}

extension TrainingRepository {
    private static var recoveryKey: String { "training-recovery-v1" }
    private func recoveryState() throws -> RecoveryStoreState {
        guard let bytes = try metadataBytes(key: Self.recoveryKey) else { return .init() }
        let state = try JSONDecoder().decode(RecoveryStoreState.self, from: bytes)
        guard state.version == 1 else { throw BackupService.invalid("recovery_metadata_version") }
        return state
    }
    private func saveRecoveryState(_ state: RecoveryStoreState) throws {
        try putMetadataBytes(BackupService.bytes(state), key: Self.recoveryKey)
    }
    private func projectedEnvelope(_ programID: String) throws -> JournalEnvelope {
        let saved = try head(programID)
        let document = try rawBackup()
        let batch = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
        guard let envelope = batch.envelopes[saved.headHash] else { throw BackupService.invalid("projection_head") }
        return envelope
    }
    private func recoveryHealth(programID: String, batch: VerifiedCloudBatch) throws -> StoreHealth {
        let state = try recoveryState()
        let resolved = Set(state.resolvedQuarantineKeys)
        let heads = batch.heads[programID, default: []]
        if try RecoveryVerifier.hasMixedPolicyConflict(programID: programID, envelopes: batch.envelopes, heads: heads) { return .mixedPolicyConflict }
        if heads.count > 1 { return .integrityConflict }
        let programProblems = batch.quarantined.filter { $0.programID == programID }
        let problems = programProblems.filter { !resolved.contains(BackupService.hash($0.record.bytes)) }
        if programProblems.contains(where: { $0.reason == "unsupported_version" }) { return .unsupportedVersion }
        if !problems.isEmpty { return .integrityConflict }
        let waiting = batch.waiting.contains { record in
            let fields = (try? JSONSerialization.jsonObject(with: record.bytes)) as? [String: Any]
            return fields?["programId"] as? String == programID
        }
        if waiting {
            if batch.quarantined.contains(where: { $0.reason == "unsupported_version" && $0.record.recordType == CloudRecordKind.archive.recordType }) { return .unsupportedVersion }
            return .incompleteRecovery
        }
        if let graphHead = batch.heads[programID]?.only, let projection = try? head(programID), projection.headHash != graphHead {
            return .incompleteRecovery
        }
        return .ready
    }
    /// The entire union proof and every projection/health change occurs inside
    /// the same non-suspending writer transaction as local finalization.
    func ingestCloud(_ batch: VerifiedCloudBatch, scope: CloudScope) throws -> IngestionReport {
        try transaction {
            let original = try rawBackup()
            var state = try recoveryState()
            state.graphRequired = true
            let localRecords = try BackupService.recoveryRecords(original)
            let known = Set(try localRecords.map { try $0.key })
            let incoming = try Dictionary(batch.originals.map { (try $0.key, $0) }, uniquingKeysWith: { first, _ in first })
            var bindings = try cloudBindings()
            var allowed: [ArchivedRecord] = []
            let rejected: [RecoveryQuarantine] = []
            let existingPrograms = try modelContext.fetch(FetchDescriptor<ProgramHeadRecord>())
            for record in incoming.values {
                let dataset = String(record.zoneName.dropFirst(CloudRecordCodec.zonePrefix.count))
                if record.zoneName.hasPrefix(CloudRecordCodec.zonePrefix), UUID(uuidString: dataset) != nil {
                    if let bound = bindings.datasets[dataset], bound != scope.key {
                        throw BackupService.invalid("dataset_account_binding")
                    }
                    bindings.datasets[dataset] = scope.key
                }
                allowed.append(record)
            }
            let proof = try RecoveryVerifier().verify(localRecords + state.originals + allowed)
            var originals = try Dictionary(state.originals.map { (try $0.key, $0) }, uniquingKeysWith: { first, _ in first })
            for record in allowed + rejected.map(\.record) { originals[try record.key] = record }
            state.originals = originals.sorted { $0.key < $1.key }.map(\.value)
            // Preserve archive formatting already on disk; cloud canonicalization
            // is not permission to rewrite frozen original resources.
            for archive in proof.rules {
                if let saved = try modelContext.fetch(FetchDescriptor<RuleArchiveRecord>()).first(where: { $0.contentHash == archive.id }) {
                    guard try CloudRecordCodec.canonicalBytes(saved.bytes) == archive.bytes else { throw BackupService.invalid("rules_original_conflict") }
                } else { modelContext.insert(RuleArchiveRecord(hash: archive.id, bytes: archive.bytes)) }
            }
            for archive in proof.profiles {
                if let saved = try modelContext.fetch(FetchDescriptor<ProfileArchiveRecord>()).first(where: { $0.contentHash == archive.id }) {
                    guard try CloudRecordCodec.canonicalBytes(saved.bytes) == archive.bytes else { throw BackupService.invalid("profile_original_conflict") }
                } else { modelContext.insert(ProfileArchiveRecord(hash: archive.id, bytes: archive.bytes)) }
            }
            var events = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<JournalRecord>()).map { ($0.eventID, $0) })
            for envelope in proof.envelopes.values.sorted(by: { ($0.returnedState.revision, $0.envelopeHash) < ($1.returnedState.revision, $1.envelopeHash) }) {
                if events[envelope.eventID] == nil {
                    let row = JournalRecord(eventID: envelope.eventID, programID: envelope.programID, revision: envelope.returnedState.revision,
                        bytes: try BackupService.bytes(envelope), hash: envelope.envelopeHash)
                    modelContext.insert(row); events[envelope.eventID] = row
                }
            }
            let drafts = try modelContext.fetch(FetchDescriptor<DraftRecord>())
            for (program, hashes) in proof.heads.sorted(by: { $0.key < $1.key }) {
                let existing = existingPrograms.first(where: { $0.programID == program })
                let projection: JournalEnvelope?
                if hashes.count == 1, !drafts.contains(where: { $0.programID == program }) { projection = proof.envelopes[hashes[0]] }
                else if existing != nil { projection = nil }
                else {
                    let paths = try hashes.map { try RecoveryVerifier.ancestors($0, envelopes: proof.envelopes) }
                    let common = paths.dropFirst().reduce(paths[0]) { $0.intersection($1) }
                    projection = common.compactMap { proof.envelopes[$0] }.sorted {
                        ($0.returnedState.revision, $0.envelopeHash) > ($1.returnedState.revision, $1.envelopeHash)
                    }.first
                }
                if let projection {
                    if let existing {
                        existing.revision = projection.returnedState.revision; existing.headHash = projection.envelopeHash
                        existing.bytes = try BackupService.bytes(projection.returnedState)
                    } else {
                        modelContext.insert(ProgramHeadRecord(programID: program, revision: projection.returnedState.revision,
                            bytes: try BackupService.bytes(projection.returnedState), headHash: projection.envelopeHash, datasetID: projection.datasetID))
                    }
                }
            }
            for quarantine in proof.quarantined + rejected {
                let bytes = try BackupService.bytes(quarantine.record)
                let id = BackupService.hash(bytes)
                if try !modelContext.fetch(FetchDescriptor<QuarantineRecord>()).contains(where: { $0.id == id }) {
                    modelContext.insert(QuarantineRecord(id: id, bytes: bytes, reason: quarantine.reason))
                }
            }
            for envelope in proof.envelopes.values {
                if case let .resolveConflict(selection, _, _, _) = envelope.command {
                    state.resolvedQuarantineKeys = Array(Set(state.resolvedQuarantineKeys + selection.reviewedQuarantineChecksums)).sorted()
                }
            }
            var metadata = try cloudMetadata(scope: scope)
            for record in allowed {
                let observation = CloudObservation(recordID: record.recordID, zoneName: record.zoneName, recordType: record.recordType,
                    claimedChecksum: record.claimedChecksum, payload: record.bytes, systemFields: Data())
                // The direct proof boundary has no system fields. Preserve all
                // original full observations already retained by C1/ingestor.
                if !metadata.observations.values.contains(where: { ArchivedRecord(observation: $0) == record }) {
                    metadata.observations[try BackupService.hash(observation)] = observation
                }
            }
            try putMetadataBytes(JSONEncoder().encode(metadata), key: scope.key)
            try saveRecoveryState(state)
            try putMetadataBytes(JSONEncoder().encode(bindings), key: Self.bindingsKey)
            let unresolved = proof.quarantined.filter { !state.resolvedQuarantineKeys.contains(BackupService.hash($0.record.bytes)) } + rejected
            let programHealth = try proof.heads.keys.map { try recoveryHealth(programID: $0, batch: proof) }
            let health: StoreHealth = programHealth.contains(.unsupportedVersion) ? .unsupportedVersion :
                programHealth.contains(.mixedPolicyConflict) ? .mixedPolicyConflict :
                programHealth.contains(.integrityConflict) || !unresolved.isEmpty ? .integrityConflict :
                !proof.waiting.isEmpty || programHealth.contains(.incompleteRecovery) ? .incompleteRecovery : .ready
            let waitingKeys = Set(try proof.waiting.map { try $0.key })
            let rejectedKeys = Set(try (proof.quarantined + rejected).map { try $0.record.key })
            return IngestionReport(accepted: incoming.keys.filter { !known.contains($0) && !waitingKeys.contains($0) && !rejectedKeys.contains($0) }.count,
                identical: incoming.keys.filter { known.contains($0) }.count,
                waitingForDependencies: proof.waiting.count, quarantined: unresolved.count, health: health)
        }
    }
    func resolveConflict(programID: UUID, expectedHeadHashes: [String], selection: BranchSelection, next: WorkoutSlot) throws -> StoreSnapshot {
        try transaction {
            let id = programID.uuidString.lowercased()
            let document = try rawBackup()
            let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
            let heads = proof.heads[id, default: []]
            guard Set(expectedHeadHashes).count == expectedHeadHashes.count, expectedHeadHashes.sorted() == heads,
                  let parent = proof.envelopes[selection.selectedHeadHash], parent.programID == id else { throw BackupService.invalid("stale_resolution_heads") }
            var state = try recoveryState()
            let checksums = Set(proof.quarantined.filter { $0.programID == id && !state.resolvedQuarantineKeys.contains(BackupService.hash($0.record.bytes)) }.map { BackupService.hash($0.record.bytes) })
            guard Set(selection.reviewedQuarantineChecksums).count == selection.reviewedQuarantineChecksums.count,
                  Set(selection.reviewedQuarantineChecksums) == checksums else { throw BackupService.invalid("stale_resolution_quarantine") }
            // Started or ambiguous Finish drafts keep their exact original binding.
            guard try !modelContext.fetch(FetchDescriptor<DraftRecord>()).contains(where: { $0.programID == id }) else { throw EngineError(code: "resolution_draft_locked", field: "draft") }
            let rules = try rule(parent.rulesetHash)
            let input = try RecoveryVerifier.resolutionInput(envelopes: proof.envelopes, heads: heads, selection: selection, next: next, rules: rules)
            let result = try resolveCloudBranches(input)
            let ancestors = try heads.reduce(into: Set<String>()) { hashes, head in
                hashes.formUnion(try RecoveryVerifier.ancestors(head, envelopes: proof.envelopes))
            }
            let rawOriginals = proof.originals.filter { record in
                if selection.reviewedQuarantineChecksums.contains(BackupService.hash(record.bytes)) { return true }
                guard record.recordType == CloudRecordKind.journal.recordType,
                      let envelope = try? JSONDecoder().decode(JournalEnvelope.self, from: record.bytes) else { return false }
                return ancestors.contains(envelope.envelopeHash)
            }
            let originals = try rawOriginals.map { try CausalOriginalArchive.make($0) }
            try putArchives(rules: [], profiles: originals)
            let command = JournalCommand.resolveConflict(selection: selection, preservedHeadHashes: heads,
                originalArchiveHashes: Array(Set(originals.map(\.id))).sorted(), next: next)
            let accepted = try envelope(programID: id, eventID: UUID().uuidString.lowercased(), datasetID: parent.datasetID,
                command: command, parent: parent, result: ConfigurationResult(state: result.state, workout: result.workout, decisions: result.decisions), rules: rules)
            try persist(accepted)
            state.resolvedQuarantineKeys = Array(Set(state.resolvedQuarantineKeys + selection.reviewedQuarantineChecksums)).sorted()
            try saveRecoveryState(state)
            // Verify the assembled resolution and its exact portable sources
            // before save. Unrepresentable reviewed originals must roll back.
            _ = try exportBackup()
        }
        return try snapshot(programID: programID)
    }
}
private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

extension TrainingRepository {
    private func importGraph(_ document: BackupDocument) throws -> ImportReceipt {
        let incoming = try BackupService.validate(document)
        let original = try rawBackup()
        let representedRecords = try BackupService.recoveryRecords(original)
        let incomingRecords = try BackupService.recoveryRecords(document)
        let proof = try RecoveryVerifier().verify(representedRecords + incomingRecords)
        var state = try recoveryState()
        state.graphRequired = true
        var originals = try Dictionary(state.originals.map { (try $0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let represented = try Dictionary(representedRecords.map { (try $0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let importedOriginals = original.journal.isEmpty && state.originals.isEmpty ? document.recovery!.originals : incomingRecords
        for record in importedOriginals {
            let key = try record.key
            // Native rows already represent these exact portable descriptors.
            // Retain every differing payload or transport descriptor as an original.
            if represented[key] != record { originals[key] = record }
        }
        state.originals = originals.sorted { $0.key < $1.key }.map(\.value)
        state.resolvedQuarantineKeys = Array(Set(state.resolvedQuarantineKeys + (document.recovery?.resolvedQuarantineKeys ?? []))).sorted()
        try putArchives(rules: document.rules, profiles: document.profiles)
        var records = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<JournalRecord>()).map { ($0.eventID, $0) })
        var accepted = 0, identical = 0, conflicted = 0
        for item in document.journal {
            let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: item.bytes)
            if let existing = records[item.id] {
                if existing.bytes == item.bytes { identical += 1 } else { conflicted += 1 }
            } else {
                let row = JournalRecord(eventID: item.id, programID: envelope.programID, revision: envelope.returnedState.revision, bytes: item.bytes, hash: envelope.envelopeHash)
                modelContext.insert(row); records[item.id] = row; accepted += 1
            }
        }
        let heads = try modelContext.fetch(FetchDescriptor<ProgramHeadRecord>())
        let drafts = try modelContext.fetch(FetchDescriptor<DraftRecord>())
        for (program, envelope) in incoming.heads {
            let projection = proof.heads[program]?.only.flatMap { proof.envelopes[$0] } ?? envelope
            if let existing = heads.first(where: { $0.programID == program }) {
                if proof.heads[program]?.count == 1, !drafts.contains(where: { $0.programID == program }) {
                    existing.bytes = try BackupService.bytes(projection.returnedState); existing.headHash = projection.envelopeHash
                    existing.revision = projection.returnedState.revision
                }
            } else {
                // A protected incoming draft keeps its validated original binding.
                let initial = document.drafts.contains { (try? JSONDecoder().decode(WorkoutDraft.self, from: $0.bytes).programID) == program } ? envelope : projection
                modelContext.insert(ProgramHeadRecord(programID: program, revision: initial.returnedState.revision,
                    bytes: try BackupService.bytes(initial.returnedState), headHash: initial.envelopeHash, datasetID: initial.datasetID))
            }
        }
        for item in document.drafts {
            let draft = try JSONDecoder().decode(WorkoutDraft.self, from: item.bytes)
            if let existing = drafts.first(where: { $0.programID == draft.programID }) {
                guard existing.id == draft.id, existing.bytes == item.bytes else { throw BackupService.invalid("draft_import_conflict") }
            } else {
                let retained = try JSONDecoder().decode(ProgramState.self, from: head(draft.programID).bytes)
                try BackupService.validateDraft(draft, state: retained, rules: BackupService.rules(original.rules + document.rules, hash: retained.rulesetHash))
                modelContext.insert(DraftRecord(id: draft.id, programID: draft.programID, bytes: item.bytes))
            }
        }
        for quarantine in document.recovery!.quarantines {
            if try !modelContext.fetch(FetchDescriptor<QuarantineRecord>()).contains(where: { $0.id == quarantine.id }) {
                modelContext.insert(QuarantineRecord(id: quarantine.id, bytes: quarantine.bytes, reason: quarantine.reason))
            }
        }
        try saveRecoveryState(state)
        // Incoming validity does not imply validity of the assembled union.
        // Keep this check inside the writer transaction so failure rolls back.
        _ = try exportBackup()
        return ImportReceipt(accepted: accepted, identical: identical, conflicted: conflicted)
    }
}

extension TrainingRepository {
    /// Exact original-source coverage is derived from immutable resolution
    /// commands. It is never a fabricated acknowledgement of an occupied name.
    private func cloudSourceCoverage(scope: CloudScope) throws -> (covered: Set<String>, completed: Int, pendingCompleted: Int, incomplete: Bool) {
        let document = try rawBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
        let state = try recoveryState()
        let metadata = try cloudMetadata(scope: scope)
        let bindings = try cloudBindings()
        let stored = try modelContext.fetch(FetchDescriptor<RuleArchiveRecord>()).map { ($0.contentHash, $0.bytes) } +
            modelContext.fetch(FetchDescriptor<ProfileArchiveRecord>()).map { ($0.contentHash, $0.bytes) }
        let archiveBytes = try Dictionary(stored.map { ($0.0, try CloudRecordCodec.canonicalBytes($0.1)) }, uniquingKeysWith: { first, _ in first })
        let wrappers = archiveBytes.compactMap { hash, bytes -> (String, CausalOriginalArchive)? in
            guard let wrapper = try? JSONDecoder().decode(CausalOriginalArchive.self, from: bytes), wrapper.archiveKind == "causal-original-v1" else { return nil }
            return (hash, wrapper)
        }
        func available(kind: CloudRecordKind, dataset: String, identity: String, bytes: Data) -> Bool {
            guard bindings.datasets[dataset] == scope.key, let uuid = UUID(uuidString: dataset),
                  let name = try? CloudRecordCodec.recordName(kind: kind, datasetID: uuid, identity: identity),
                  !metadata.conflictingRecordIDs.contains(name) else { return false }
            let checksum = BackupService.hash(bytes)
            if metadata.acknowledgements[name]?.verifiedHash == checksum { return true }
            return state.originals.contains { $0.recordID == name && $0.zoneName == CloudRecordCodec.zoneID(uuid).zoneName &&
                $0.recordType == kind.recordType && $0.claimedChecksum == checksum && $0.bytes == bytes } &&
                metadata.observations.values.contains { $0.recordID == name && $0.zoneName == CloudRecordCodec.zoneID(uuid).zoneName &&
                    $0.recordType == kind.recordType && $0.claimedChecksum == checksum && $0.payload == bytes }
        }
        func archiveAvailable(_ hash: String, dataset: String) -> Bool {
            guard let bytes = archiveBytes[hash] else { return false }
            return available(kind: .archive, dataset: dataset, identity: hash, bytes: bytes)
        }
        func directAvailable(_ envelope: JournalEnvelope) -> Bool {
            guard let bytes = try? BackupService.bytes(envelope) else { return false }
            return available(kind: .journal, dataset: envelope.datasetID, identity: envelope.eventID, bytes: bytes)
        }
        func wrapperAvailable(_ envelope: JournalEnvelope) -> Bool {
            guard let bytes = try? BackupService.bytes(envelope), let dataset = UUID(uuidString: envelope.datasetID),
                  let name = try? CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: envelope.eventID) else { return false }
            return wrappers.contains { hash, wrapper in
                wrapper.record.recordID == name && wrapper.record.zoneName == CloudRecordCodec.zoneID(dataset).zoneName &&
                wrapper.record.recordType == CloudRecordKind.journal.recordType && wrapper.record.claimedChecksum == BackupService.hash(bytes) &&
                wrapper.record.bytes == bytes && archiveAvailable(hash, dataset: envelope.datasetID)
            }
        }
        var cache: [String: Bool] = [:]
        func complete(_ hash: String, wrappersAllowed: Bool, visiting: Set<String> = []) -> Bool {
            let key = hash + (wrappersAllowed ? ":sources" : ":direct")
            if let cached = cache[key] { return cached }
            guard !visiting.contains(hash), let envelope = proof.envelopes[hash],
                  directAvailable(envelope) || (wrappersAllowed && wrapperAvailable(envelope)),
                  [envelope.rulesetHash, envelope.profileHash, envelope.sourceProfileHash].allSatisfy({ archiveAvailable($0, dataset: envelope.datasetID) }) else { cache[key] = false; return false }
            var allowSources = wrappersAllowed
            if case let .resolveConflict(_, _, originals, _) = envelope.command {
                guard !originals.isEmpty, originals.allSatisfy({ archiveAvailable($0, dataset: envelope.datasetID) }) else { cache[key] = false; return false }
                allowSources = true
            }
            let answer = RecoveryVerifier.dependencies(envelope).allSatisfy { complete($0, wrappersAllowed: allowSources, visiting: visiting.union([hash])) }
            cache[key] = answer
            return answer
        }
        var coveredHashes = Set<String>()
        for envelope in proof.envelopes.values {
            if case .resolveConflict = envelope.command, directAvailable(envelope), complete(envelope.envelopeHash, wrappersAllowed: false) {
                coveredHashes.formUnion(try RecoveryVerifier.ancestors(envelope.envelopeHash, envelopes: proof.envelopes))
            }
        }
        var covered = Set<String>()
        for hash in coveredHashes {
            guard let envelope = proof.envelopes[hash], wrapperAvailable(envelope), let dataset = UUID(uuidString: envelope.datasetID) else { continue }
            let name = try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: envelope.eventID)
            if metadata.conflictingRecordIDs.contains(name) { covered.insert(name + ":" + BackupService.hash(try BackupService.bytes(envelope))) }
        }
        var completed = 0
        for envelope in proof.envelopes.values where CloudRecordCodec.isWorkout(envelope.command) {
            if complete(envelope.envelopeHash, wrappersAllowed: false) || (coveredHashes.contains(envelope.envelopeHash) && complete(envelope.envelopeHash, wrappersAllowed: true)) {
                completed += 1
            }
        }
        let total = proof.envelopes.values.filter { bindings.datasets[$0.datasetID] == scope.key && CloudRecordCodec.isWorkout($0.command) }.count
        // Imported originals are not uploads. Binding an empty portable outbox
        // cannot establish that this account independently has the root/archives.
        let authored = Set(try modelContext.fetch(FetchDescriptor<OutboxRecord>()).map(\.key))
        var missingReceivedRoot = false
        for envelope in proof.envelopes.values where envelope.parentEnvelopeHash == nil && bindings.datasets[envelope.datasetID] == scope.key && !authored.contains(envelope.eventID) {
            if !complete(envelope.envelopeHash, wrappersAllowed: false) &&
                !(coveredHashes.contains(envelope.envelopeHash) && complete(envelope.envelopeHash, wrappersAllowed: true)) {
                missingReceivedRoot = true
            }
        }
        return (covered, completed, max(0, total - completed), missingReceivedRoot || !proof.waiting.isEmpty || proof.heads.values.contains { $0.count > 1 })
    }
}

extension TrainingRepository {
    /// C3 selects an active program explicitly. This query exposes every known
    /// program, including unsupported/incomplete roots without a projection.
    func recoveryPrograms() throws -> [RecoveryProgramSummary] {
        let document = try rawBackup()
        let records = try BackupService.recoveryRecords(document)
        let proof = try RecoveryVerifier().verify(records)
        var datasets: [String: Set<String>] = [:]
        for record in proof.originals {
            guard record.recordType == CloudRecordKind.journal.recordType,
                  let fields = (try? JSONSerialization.jsonObject(with: record.bytes)) as? [String: Any],
                  let claimedProgram = fields["programId"] as? String,
                  let dataset = UUID(uuidString: String(record.zoneName.dropFirst(CloudRecordCodec.zonePrefix.count))),
                  record.zoneName == CloudRecordCodec.zoneID(dataset).zoneName else { continue }
            let program = proof.quarantined.first { $0.record == record }?.programID ?? claimedProgram
            guard UUID(uuidString: program)?.uuidString.lowercased() == program else { continue }
            datasets[program, default: []].insert(dataset.uuidString.lowercased())
        }
        return try datasets.keys.sorted().map { program in
            var health = try recoveryHealth(programID: program, batch: proof)
            if proof.heads[program, default: []].isEmpty && health == .ready { health = .incompleteRecovery }
            return RecoveryProgramSummary(programID: program, datasetIDs: datasets[program]!.sorted(),
                headHashes: proof.heads[program, default: []], projectedHeadHash: document.heads[program],
                knownCompletedWorkoutCount: proof.envelopes.values.filter { $0.programID == program && CloudRecordCodec.isWorkout($0.command) }.count,
                health: health)
        }
    }
}

extension TrainingRepository {
    func datasetAssociation(_ id: UUID) throws -> String? { try cloudBindings().datasets[id.uuidString.lowercased()] }
}

/// Evidence export only; no staged import or accepted-projection semantics.
struct StagedRecoveryOriginalsExport: Codable, Sendable {
    var formatVersion = 1
    var artifactKind = "plentystrong-staged-recovery-originals"
    var originals: [ArchivedRecord]
}
extension TrainingRepository {
    func stagedRecoveryOriginals() throws -> StagedRecoveryOriginalsExport {
        try requireOpen()
        let adopted = Set(try BackupService.recoveryRecords(rawBackup()).map { try $0.key })
        let rows = try modelContext.fetch(FetchDescriptor<CloudCursorRecord>()).filter { $0.accountScope.hasPrefix("cloud-v1:") }
        var originals: [String: ArchivedRecord] = [:]
        for row in rows {
            let metadata = try JSONDecoder().decode(CloudScopeMetadata.self, from: row.bytes)
            guard metadata.version == 1 else { throw BackupService.invalid("cloud_metadata_version") }
            for observation in metadata.observations.values {
                let original = ArchivedRecord(observation: observation), key = try original.key
                if !adopted.contains(key) { originals[key] = original }
            }
        }
        return .init(originals: originals.sorted { $0.key < $1.key }.map(\.value))
    }
}

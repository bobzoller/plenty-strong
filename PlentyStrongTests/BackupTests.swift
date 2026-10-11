import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong
struct BackupTests {
    func empty() throws -> TrainingRepository {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try TrainingRepository.open(at: dir.appendingPathComponent("training.store"))
    }
    @Test func fullRoundTripPreservesCommandsTracesVariantsAndSourceBytes() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let thursday = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU")
        let scheduled = try await s.repository.reschedule(programID: s.programID, expectedRevision: 1, slot: thursday)
        let sunday = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        let secondEvent = RepositoryTestHarness.event(state: scheduled.state)
        let second = try await s.repository.finalize(programID: s.programID, expectedRevision: 2, event: secondEvent, next: sunday)
        let base = "db_lateral_raise"
        let oldID = second.snapshot.state.config.activeVariantIDs![base]!
        #expect(second.snapshot.state.revision == 3)
        #expect(second.snapshot.state.exercises[oldID]!.ceilingStreak == 1)
        #expect(second.snapshot.history.last!.decisions.contains { $0.movementID == oldID && $0.explanationKey == "ceiling_confirmation" })
        let created = try await s.repository.applyVariantChange(programID: s.programID, expectedRevision: 3, change: .create(baseMovementID: base, variantID: "modified", modifications: "Old description"), next: sunday)
        #expect(created.state.exercises["modified"]!.ceilingStreak == 0)
        let corrected = try await s.repository.applyVariantChange(programID: s.programID, expectedRevision: 4, change: .correctDescription(variantID: "modified", modifications: "Corrected"), next: sunday)
        let selected = try await s.repository.applyVariantChange(programID: s.programID, expectedRevision: 5, change: .select(baseMovementID: base, variantID: oldID), next: sunday)
        #expect(created.state.exercises[oldID] == corrected.state.exercises[oldID])
        #expect(selected.state.exercises[oldID]!.ceilingStreak == 1)
        let doc = try await s.repository.exportBackup()
        let destination = try empty()
        let imported = try await destination.importBackup(doc)
        #expect(imported == ImportReceipt(accepted: 7, identical: 0, conflicted: 0))
        #expect(try await destination.snapshot(programID: s.programID) == selected)
        #expect(try await destination.exportBackup() == doc)
        #expect(try await destination.importBackup(doc) == ImportReceipt(accepted: 0, identical: 7, conflicted: 0))
    }
    @Test func corruptNewerDuplicateAndTruncatedBackupsLeaveExistingHistory() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let original = try await s.repository.exportBackup()
        var bad = original; bad.journal[0].bytes.append(0)
        await #expect(throws: (any Error).self) { try await s.repository.importBackup(bad) }
        bad = original; bad.formatVersion = 2
        await #expect(throws: (any Error).self) { try await s.repository.importBackup(bad) }
        bad = original; bad.journal.append(bad.journal[0])
        await #expect(throws: (any Error).self) { try await s.repository.importBackup(bad) }
        let encoded = try BackupService.bytes(original)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BackupDocument.self, from: encoded.dropLast(8)) }
        #expect(try await s.repository.exportBackup() == original)
    }
    @Test func forgedHashCorrectRootAndMissingParentRejectBeforeMutation() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let original = try await s.repository.exportBackup()
        var bad = original
        var envelope = try JSONDecoder().decode(JournalEnvelope.self, from: bad.journal[0].bytes)
        envelope.returnedState.revision = 99
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        bad.journal[0] = ArchivedObject(id: envelope.eventID, bytes: try BackupService.bytes(envelope), checksum: try BackupService.hash(envelope))
        await #expect(throws: (any Error).self) { try await empty().importBackup(bad) }
        bad = original; bad.journal.removeFirst()
        await #expect(throws: (any Error).self) { try await empty().importBackup(bad) }
        #expect(try await s.repository.exportBackup() == original)
    }
}
extension BackupTests {
    @Test func omittedTerminalEnvelopeRejectsEvenWhenRemainingChainIsValid() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        var bad = try await s.repository.exportBackup(); bad.journal.removeLast()
        await #expect(throws: (any Error).self) { try await empty().importBackup(bad) }
    }
    @Test func validForkIsQuarantinedWithoutOverwritingOriginals() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let root = try await s.repository.exportBackup()
        let other = try empty(); _ = try await other.importBackup(root)
        var altered = s.firstEvent; altered.exercises[0].finalEffort = .tooHard
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        _ = try await other.finalize(programID: s.programID, expectedRevision: 0, event: altered, next: s.next)
        let original = try await s.repository.exportBackup()
        let receipt = try await s.repository.importBackup(other.exportBackup())
        #expect(receipt.accepted == 0 && receipt.conflicted == 2)
        let retained = try await s.repository.exportBackup()
        #expect(retained.journal == original.journal && retained.heads == original.heads)
        #expect(retained.formatVersion == 2 && retained.recovery!.quarantines.count == 1)
        #expect(retained.recovery!.heads[s.programID.uuidString.lowercased()]!.count == 2)
        #expect(try await s.repository.snapshot(programID: s.programID).health == .integrityConflict)
        #expect(try await s.repository.counts() == [2, 1, 0, 2, 1])
        let reopened = try await s.reopened()
        #expect(try await reopened.exportBackup() == retained)
        #expect(try await reopened.snapshot(programID: s.programID).health == .integrityConflict)
    }
}
extension BackupTests {
    @Test func bundledMalformedFixturesRejectWithoutMutation() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let original = try await s.repository.exportBackup()
        let bundle = Bundle(for: FixtureBundleToken.self)
        let newer = try JSONDecoder().decode(BackupDocument.self, from: Data(contentsOf: bundle.url(forResource: "unsupported-backup-v2", withExtension: "json")!))
        await #expect(throws: (any Error).self) { try await s.repository.importBackup(newer) }
        let truncated = try Data(contentsOf: bundle.url(forResource: "truncated-backup", withExtension: "json")!)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BackupDocument.self, from: truncated) }
        #expect(try await s.repository.exportBackup() == original)
    }
    @Test func canonicallyEquivalentUnicodeDoesNotWeakenExactReplay() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let first = try await s.repository.snapshot(programID: s.programID)
        let base = s.firstEvent.exercises[0].baseMovementID!
        let slot = WorkoutSlot(date: first.state.activePrescription.date, slotID: first.state.activePrescription.slotID)
        _ = try await s.repository.applyVariantChange(programID: s.programID, expectedRevision: 0,
            change: .create(baseMovementID: base, variantID: "unicode", modifications: "cafe\u{0301}"), next: slot)
        var bad = try await s.repository.exportBackup()
        var envelope = try JSONDecoder().decode(JournalEnvelope.self, from: bad.journal.last!.bytes)
        envelope.returnedState.config.variants!["unicode"]!.modifications = "caf\u{00e9}"
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        bad.journal[bad.journal.count - 1] = try BackupService.object(envelope, id: envelope.eventID)
        bad.heads[envelope.programID] = envelope.envelopeHash
        await #expect(throws: (any Error).self) { try await empty().importBackup(bad) }
    }
}
private final class FixtureBundleToken: NSObject {}
extension BackupTests {
    @Test func draftBackupRetainsExactDateZoneAndRawProblems() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await s.draft(); draft.logs[0].problem = .controlLost
        draft.logs[0].actualSets = [ActualSet(reps: 2, leftReps: 2, rightReps: 1)]
        try await s.repository.saveDraft(draft)
        let document = try await s.repository.exportBackup()
        let destination = try empty(); _ = try await destination.importBackup(document)
        #expect(try await destination.snapshot(programID: s.programID).draft == draft)
        #expect(try await destination.exportBackup() == document)
    }
}

extension BackupTests {
    @Test func mixedArchivesReplayBothFormats() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let prefix = try await s.repository.exportBackup()
        let activated = try await activateSynthetic(s.repository, id: s.programID)
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: activated.state.revision,
            event: exactActivationEvent(state: activated.state), next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU"))
        let v1 = try await s.repository.exportBackup()
        #expect(v1.formatVersion == 1)
        #expect(Array(v1.journal.prefix(prefix.journal.count)) == prefix.journal)
        #expect(prefix.rules.allSatisfy { v1.rules.contains($0) })
        let batch = try RecoveryVerifier().verify(BackupService.recoveryRecords(v1))
        var v2 = v1; v2.formatVersion = 2
        v2.recovery = BackupService.graphManifest(batch, originals: [], quarantines: [], resolved: [])
        for document in [v1,v2] {
            let destination = try empty()
            _ = try await destination.importBackup(document)
            let first = try await destination.exportBackup()
            _ = try await destination.importBackup(document)
            #expect(try await destination.exportBackup() == first)
            #expect(try await destination.snapshot(programID: s.programID).state.schemaVersion == 3)
            var missing = document; missing.rules.removeAll { $0.id == RulesetCatalog.fixedRulesetHash }
            await #expect(throws: (any Error).self) { try await destination.importBackup(missing) }
            #expect(try await destination.exportBackup() == first)
            var future = document
            var rule = try JSONDecoder().decode(Ruleset.self, from: future.rules.first { $0.id == RulesetCatalog.exactRulesetHash }!.bytes)
            rule.version = "general-fitness-exact-future"
            guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(rule)) else { throw BackupService.invalid("fixture") }
            fields.removeValue(forKey: "hash"); rule.hash = try CanonicalJSON.sha256(.object(fields))
            future.rules.append(try BackupService.object(rule, id: rule.hash))
            await #expect(throws: (any Error).self) { try await destination.importBackup(future) }
            #expect(try await destination.exportBackup() == first)
        }
        // A fresh exact root is admitted directly and portable in both formats.
        let destination = try empty()
        let id = UUID(), config = try selectFixedProgram(goal: .size, programID: id)
        _ = try await destination.initialize(config: config, rules: RulesetCatalog.exactV1(), firstWorkout: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        let direct = try await destination.exportBackup()
        #expect(try BackupService.validate(direct).heads[config.programID]?.schemaVersion == 3)
        var directGraph = direct; directGraph.formatVersion = 2
        directGraph.recovery = BackupService.graphManifest(try RecoveryVerifier().verify(BackupService.recoveryRecords(direct)), originals: [], quarantines: [], resolved: [])
        #expect(try BackupService.validate(directGraph).heads[config.programID]?.schemaVersion == 3)
    }
    @Test func oldClientStyleAdmissionRejectsSchema3() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let exact = try await activateSynthetic(s.repository, id: s.programID)
        #expect(throws: (any Error).self) { try ProgramPolicy.resolve(schemaVersion: exact.state.schemaVersion, rules: RulesetCatalog.fixedV1()) }
        #expect(exact.history.last!.schemaVersion == 3)
    }
}

extension BackupTests {
    @Test func correctionAuditBindsHashesAndReplaysBothBackupFormats() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var event = s.firstEvent
        let after = event.exercises[0].actualSets[0]
        var before = after; before.reps = 7
        if before.leftReps != nil { before.leftReps = 7; before.rightReps = 7 }
        let correction = SetCorrection(operationID: UUID(), movementID: event.exercises[0].movementID,
            setIndex: 0, before: before, after: after, beforeStatus: .completed,
            afterStatus: .completed, outcomeAcknowledged: true)
        let plainCommand = JournalCommand.workout(completedWorkout: event, next: s.next)
        let plainHash = try BackupService.eventHash(plainCommand)
        guard case .object(let fields) = try JSONDecoder().decode(CanonicalValue.self, from: BackupService.bytes(event)) else {
            Issue.record("Expected event object"); return
        }
        #expect(fields["observationAudit"] == nil)
        event.observationAudit = ObservationAudit(corrections: [correction])
        let auditedCommand = JournalCommand.workout(completedWorkout: event, next: s.next)
        let auditedHash = try BackupService.eventHash(auditedCommand)
        #expect(auditedHash != plainHash)
        let finalized = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: event, next: s.next)
        #expect(finalized.snapshot.state.processedEvents[event.eventID] == auditedHash)
        let v1 = try await s.repository.exportBackup()
        let envelope = try JSONDecoder().decode(JournalEnvelope.self, from: v1.journal.last!.bytes)
        var plainEnvelope = envelope; plainEnvelope.command = plainCommand
        #expect(try BackupService.envelopeHash(plainEnvelope) != envelope.envelopeHash)
        var v2 = v1; v2.formatVersion = 2
        let batch = try RecoveryVerifier().verify(BackupService.recoveryRecords(v1))
        v2.recovery = BackupService.graphManifest(batch, originals: [], quarantines: [], resolved: [])
        for document in [v1, v2] {
            let destination = try empty()
            _ = try await destination.importBackup(document)
            #expect(try await destination.snapshot(programID: s.programID).state == finalized.snapshot.state)
            #expect(try await destination.exportBackup().journal == document.journal)
        }
        var forged = event; forged.observationAudit!.corrections[0].before.reps = -1
        let initial = try await RepositoryTestHarness.make(goal: .size)
        let state = try await initial.repository.snapshot(programID: initial.programID).state
        var commandEvent = initial.firstEvent
        commandEvent.observationAudit = ObservationAudit(corrections: [SetCorrection(operationID: UUID(),
            movementID: commandEvent.exercises[0].movementID, setIndex: 0, before: forged.observationAudit!.corrections[0].before,
            after: commandEvent.exercises[0].actualSets[0], beforeStatus: .completed, afterStatus: .completed, outcomeAcknowledged: true)])
        #expect(throws: EngineError.self) { try BackupService.transition(state: state,
            command: .workout(completedWorkout: commandEvent, next: initial.next), rules: RulesetCatalog.fixedV1()) }
    }
}

extension BackupTests {
    @MainActor @Test func correctedUnfinishedDraftReopensWithOriginalsInBothFormats() async throws {
        for schema in [3, 4] {
            let f = try await GuidedWorkoutFixture.make(schemaVersion: schema)
            var draft = try #require(f.model.snapshot.draft)
            draft.logs[0].actualSets = [ActualSet(reps: 7, setIndex: 0, missedGoalReason: .effortLimit)]
            draft.workingSetsStarted = true
            draft.flow?.forward = .set(movementID: draft.logs[0].movementID, index: 1)
            _ = try await f.repository.saveDraft(draft)
            let original = try await f.repository.exportBackup()
            let corrected = try await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft),
                operationID: UUID(), movementID: draft.logs[0].movementID, setIndex: 0, replacement: ActualSet(reps: 8, setIndex: 0))
            let effective = try #require(corrected.draft)
            let v1 = try await f.repository.exportBackup()
            #expect(v1.journal == original.journal && v1.heads == original.heads)
            var v2 = v1; v2.formatVersion = 2
            v2.recovery = BackupService.graphManifest(try RecoveryVerifier().verify(BackupService.recoveryRecords(v1)), originals: [], quarantines: [], resolved: [])
            await f.repository.close()
            let sourceReopened = try TrainingRepository.open(at: f.storeURL)
            #expect(try BackupService.bytes(await sourceReopened.snapshot(programID: f.model.programID).draft) == BackupService.bytes(effective))
            await sourceReopened.close()
            for document in [v1, v2] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("training.store")
                let destination = try TrainingRepository.open(at: url)
                _ = try await destination.importBackup(document)
                await destination.close()
                let reopened = try TrainingRepository.open(at: url)
                let saved = try await reopened.snapshot(programID: f.model.programID)
                #expect(try BackupService.bytes(saved.draft) == BackupService.bytes(effective))
                #expect(try await reopened.exportBackup().journal == original.journal)
                #expect(try ObservationAuditValidator.originalLogs(effective: effective.logs, audit: effective.observationAudit,
                    prescription: effective.displayed, config: saved.state.config, schemaVersion: schema) == draft.logs)
                #expect(try await reopened.counts() == [original.journal.count, 1, 1, document.formatVersion == 1 ? original.journal.count : 0, 0])
                await reopened.close()
            }
        }
    }
}

extension BackupTests {
    @Test(arguments: [false, true]) func correctedEventRoundTripsAndRecovers(inactive: Bool) async throws {
        let f = try await CorrectionHistoryFixture.make(inactive: inactive)
        // Only the effective observations drive progression. Audit remains hashed
        // provenance, so processedEvents (and therefore whole states) differ.
        #expect(f.envelope.returnedState.exercises == f.plainEnvelope.returnedState.exercises)
        #expect(f.envelope.returnedPrescription == f.plainEnvelope.returnedPrescription)
        #expect(f.envelope.decisions == f.plainEnvelope.decisions)
        #expect(f.envelope.eventHash != f.plainEnvelope.eventHash)
        #expect(f.envelope.envelopeHash != f.plainEnvelope.envelopeHash)
        #expect(f.envelope.returnedState.processedEvents[f.event.eventID] == f.envelope.eventHash)
        #expect(f.plainEnvelope.returnedState.processedEvents[f.event.eventID] == f.plainEnvelope.eventHash)
        #expect(Array(f.document.journal.prefix(f.prefix.journal.count)) == f.prefix.journal)
        for document in try f.formats() {
            let destination = try empty()
            _ = try await destination.importBackup(document)
            let snapshot = try await destination.snapshot(programID: f.programID)
            #expect((snapshot.state.config.activeVariantIDs!.values.contains(f.movementID)) == !inactive)
            #expect(snapshot.state.config.variants![f.movementID] != nil)
            #expect(snapshot.history.contains(f.envelope))
            let restored = try await destination.exportBackup()
            #expect(restored.journal == document.journal)
            #expect(restored.rules == document.rules && restored.profiles == document.profiles)
            #expect(try BackupService.bytes(snapshot.history.first { $0.eventID == f.envelope.eventID }!) == BackupService.bytes(f.envelope))
            await destination.close()
        }
    }

    @Test func oldDecoderCannotStripAuditAndAccept() async throws {
        let f = try await CorrectionHistoryFixture.make()
        let archived = try #require(f.document.journal.first { $0.id == f.envelope.eventID })
        let old = try JSONDecoder().decode(SyntheticOldEnvelope.self, from: archived.bytes)
        let downgraded = try BackupService.bytes(old)
        #expect(downgraded != archived.bytes && BackupService.hash(downgraded) != archived.checksum)
        let decoded = try JSONDecoder().decode(JournalEnvelope.self, from: downgraded)
        guard case let .workout(event, _) = decoded.command else { Issue.record("Missing workout"); return }
        #expect(event.observationAudit == nil)
        #expect(try BackupService.eventHash(decoded.command) != decoded.eventHash)
        #expect(try BackupService.envelopeHash(decoded) != decoded.envelopeHash)
        var backup = f.document
        backup.journal[backup.journal.firstIndex { $0.id == archived.id }!] = ArchivedObject(id: archived.id,
            bytes: downgraded, checksum: BackupService.hash(downgraded))
        let destination = try empty()
        let before = try await destination.exportBackup()
        await #expect(throws: (any Error).self) { try await destination.importBackup(backup) }
        #expect(try await destination.exportBackup() == before)
        await destination.close()
        // Nil-audit envelopes survive the same old decoder byte-for-byte.
        let plainBytes = try BackupService.bytes(f.plainEnvelope)
        #expect(try BackupService.bytes(JSONDecoder().decode(SyntheticOldEnvelope.self, from: plainBytes)) == plainBytes)
    }
}

/// An old client's typed workout knows every former field and ignores new keys.
/// The envelope preserves its old canonical fields and hashes unchanged.
private struct SyntheticOldWorkout: Codable {
    let eventId: String
    let date: LocalDate
    let slotId: String
    let prescriptionId: String
    let plannedPrescriptionId: String
    let sessionMode: SessionMode
    let exercises: [ExerciseLog]
    let timing: SessionTiming?
}
private struct SyntheticOldEnvelope: Codable {
    let value: CanonicalValue
    init(from decoder: any Decoder) throws {
        var fields = try [String: CanonicalValue](from: decoder)
        if case .object(var command) = fields["command"], let event = command["completedWorkout"] {
            let old = try JSONDecoder().decode(SyntheticOldWorkout.self, from: CanonicalJSON.encode(event))
            command["completedWorkout"] = try JSONDecoder().decode(CanonicalValue.self, from: BackupService.bytes(old))
            fields["command"] = .object(command)
        }
        value = .object(fields)
    }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

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

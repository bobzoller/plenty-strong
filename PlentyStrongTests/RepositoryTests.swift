import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong
struct RepositoryTests {
    @Test func repeatedFinishDoesNotCommitTwice() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let first = try await s.repository.finalize(programID: s.programID, expectedRevision: s.initialRevision, event: s.firstEvent, next: s.next)
        let repeated = try await s.repository.finalize(programID: s.programID, expectedRevision: s.initialRevision, event: s.firstEvent, next: s.next)
        #expect(first.snapshot.state.revision == s.initialRevision + 1)
        #expect(repeated.snapshot.state == first.snapshot.state)
        #expect(repeated.snapshot.history.filter { $0.eventID == s.firstEvent.eventID }.count == 1)
    }
}
extension RepositoryTests {
    @Test func changedDuplicateAndStaleDoNotChangeDisk() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let accepted = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        var changed = s.firstEvent; changed.exercises[0].finalEffort = .tooHard
        let conflict = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: changed, next: s.next)
        #expect(conflict.result == .rejected(nextState: accepted.snapshot.state, errors: ["event_id_conflict"]))
        changed.eventID = UUID().uuidString
        let stale = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: changed, next: s.next)
        #expect(stale.result == .rejected(nextState: accepted.snapshot.state, errors: ["stale_revision"]))
        #expect(try await s.repository.counts() == [2, 1, 0, 2, 0])
        #expect(try await s.reopened().snapshot(programID: s.programID).state == accepted.snapshot.state)
    }
    @Test func racingSubmissionsAcceptExactlyOne() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var other = s.firstEvent; other.eventID = UUID().uuidString
        async let a = s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        async let b = s.repository.finalize(programID: s.programID, expectedRevision: 0, event: other, next: s.next)
        let receipts = try await [a, b]
        #expect(receipts.filter { if case .applied = $0.result { return true }; return false }.count == 1)
        #expect(try await s.repository.counts() == [2, 1, 0, 2, 0])
    }
    @Test func injectedFailureRollsBackJournalHeadOutboxAndDraft() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let draft = try await s.draft()
        try await s.repository.saveDraft(draft)
        let before = try await s.repository.snapshot(programID: s.programID)
        await s.repository.failNextSave()
        await #expect(throws: (any Error).self) { try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next) }
        #expect(try await s.repository.snapshot(programID: s.programID) == before)
        #expect(try await s.repository.counts() == [1, 1, 1, 1, 0])
        #expect(try await s.reopened().snapshot(programID: s.programID) == before)
    }
    @Test func persistedDraftRetainsRawSidesProblemsAndMidnightDate() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await s.draft(); draft.logs[0].problem = .pain; draft.logs[0].finalEffort = .unknown
        draft.logs[0].actualSets = [ActualSet(reps: 3, leftReps: 3, rightReps: 2)]
        try await s.repository.saveDraft(draft)
        let reopened = try await s.reopened()
        #expect(try await reopened.snapshot(programID: s.programID).draft == draft)
        #expect(draft.date == (try LocalDate(iso8601: "2026-10-04")))
        await #expect(throws: (any Error).self) { try await reopened.reschedule(programID: s.programID, expectedRevision: 0, slot: s.next, invalidateEmptyDraft: true) }
        await #expect(throws: (any Error).self) { try await reopened.applyVariantChange(programID: s.programID, expectedRevision: 0, change: .create(baseMovementID: draft.logs[0].baseMovementID!, variantID: "new", modifications: "Grip"), next: s.next, invalidateEmptyDraft: true) }
    }
    @Test func emptyDraftNeedsExplicitInvalidationAndCannotBeRebound() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let draft = try await s.draft(empty: true)
        try await s.repository.saveDraft(draft)
        await #expect(throws: (any Error).self) { try await s.repository.reschedule(programID: s.programID, expectedRevision: 0, slot: s.next) }
        let updated = try await s.repository.reschedule(programID: s.programID, expectedRevision: 0, slot: s.next, invalidateEmptyDraft: true)
        #expect(updated.draft == nil && updated.state.revision == 1)
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(draft) }
        #expect(try await s.reopened().snapshot(programID: s.programID).state == updated.state)
    }
}
extension RepositoryTests {
    @Test func secondWriterIsRefusedAndClosedWriterCannotWrite() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        #expect(throws: (any Error).self) { try TrainingRepository.open(at: s.storeURL) }
        await s.repository.close()
        await #expect(throws: (any Error).self) { try await s.repository.discardDraft(id: UUID()) }
        let reopened = try TrainingRepository.open(at: s.storeURL)
        #expect(try await reopened.snapshot(programID: s.programID).state.revision == 0)
    }
    @Test func ineligibleRawObservationsAndSharedSafetySurviveReopenAndBackup() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var event = s.firstEvent
        event.exercises[0].status = .skipped; event.exercises[0].actualSets = []; event.exercises[0].problem = .pain
        event.exercises[1].status = .partial; event.exercises[1].actualSets = [ActualSet(reps: 3)]
        let result = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: event, next: s.next)
        #expect(result.snapshot.history.last?.command == .workout(completedWorkout: event, next: s.next))
        #expect(result.snapshot.state.baseSafety![event.exercises[0].baseMovementID!]!.paused)
        let restored = try await s.reopened().snapshot(programID: s.programID)
        #expect(restored == result.snapshot)
    }
}
extension RepositoryTests {
    @Test func observedDraftCannotBeClearedToEvadeBindingGuard() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await s.draft(empty: true)
        draft.logs[0].problem = .pain
        try await s.repository.saveDraft(draft)
        draft.logs[0].problem = .none
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(draft) }
    }
}
extension RepositoryTests {
    @Test func configurationAndInterruptionCommandsReplayAndNoopsDoNotWrite() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let draft = try await s.draft(); try await s.repository.saveDraft(draft)
        let slot = WorkoutSlot(date: draft.date, slotID: draft.planned.slotID)
        let before = try await s.repository.snapshot(programID: s.programID)
        let noOp = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: 0, change: .goal(.size), next: slot)
        #expect(noOp == before)
        #expect(try await s.repository.counts() == [1, 1, 1, 1, 0])
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let goal = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: 1, change: .goal(.maintenance), next: s.next)
        #expect(goal.history.last?.command == .reconfigure(change: .goal(.maintenance), next: s.next))
        let asOf = try LocalDate(iso8601: "2026-11-01")
        let returned = try await s.repository.prepareReturn(programID: s.programID, expectedRevision: 2, asOf: asOf)
        #expect(returned.state.revision == 3)
        #expect(returned.history.last?.command == .interruption(asOf: asOf))
        #expect(try await s.reopened().snapshot(programID: s.programID) == returned)
    }
    @Test func incompleteAppLogNeverDowngradesIntoLegacySemantics() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let before = try await s.repository.snapshot(programID: s.programID)
        var event = s.firstEvent; event.exercises[0].baseMovementID = nil; event.exercises[0].modificationsSnapshot = nil
        let rejected = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: event, next: s.next)
        #expect(rejected.snapshot == before)
        if case .rejected = rejected.result {} else { Issue.record("Incomplete app event was accepted") }
        #expect(try await s.repository.counts() == [1, 1, 0, 1, 0])
    }
}
extension RepositoryTests {
    @Test func acceptedEventReplayIgnoresNewSchedulingSuggestion() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let accepted = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: s.next)
        let newSuggestion = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU")
        let repeated = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: s.firstEvent, next: newSuggestion)
        #expect(repeated.result == .noOp(nextState: accepted.snapshot.state, reason: .eventReplayed))
        #expect(repeated.snapshot == accepted.snapshot)
        #expect(repeated.snapshot.history.last!.command == .workout(completedWorkout: s.firstEvent, next: s.next))
        #expect(try await s.repository.counts() == [2, 1, 0, 2, 0])
    }
}
extension RepositoryTests {
    @Test func startedDraftCannotEraseActualsOrSafetyProblems() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var original = try await s.draft()
        original.logs[0].problem = .pain
        original.logs[1].problem = .controlLost
        try await s.repository.saveDraft(original)
        let before = try await s.repository.snapshot(programID: s.programID)
        let backup = try await s.repository.exportBackup()
        var erased = original
        for i in erased.logs.indices { erased.logs[i].actualSets = []; erased.logs[i].problem = .none }
        #expect(erased.workingSetsStarted && erased.hasObservations)
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(erased) }
        #expect(try await s.repository.snapshot(programID: s.programID) == before)
        #expect(try await s.repository.exportBackup() == backup)
        let reopened = try await s.reopened()
        #expect(try await reopened.snapshot(programID: s.programID) == before)
        #expect(try await reopened.exportBackup().drafts == backup.drafts)
        var omitted = s.firstEvent; omitted.exercises = erased.logs
        let rejected = try await reopened.finalize(programID: s.programID, expectedRevision: 0, event: omitted, next: s.next)
        #expect(rejected.result == .rejected(nextState: before.state, errors: ["draft_binding_conflict"]))
        #expect(rejected.snapshot == before)
        var truthful = s.firstEvent; truthful.exercises = original.logs
        let accepted = try await reopened.finalize(programID: s.programID, expectedRevision: 0, event: truthful, next: s.next)
        #expect(accepted.snapshot.state.revision == 1)
        #expect(accepted.snapshot.history.last!.command == .workout(completedWorkout: truthful, next: s.next))
        for log in original.logs.prefix(2) {
            let safety = accepted.snapshot.state.baseSafety![log.baseMovementID!]!
            #expect(safety.paused && safety.sourceEventIDs.contains(truthful.eventID))
        }
        await reopened.close()
        let finalReader = try TrainingRepository.open(at: s.storeURL)
        #expect(try await finalReader.snapshot(programID: s.programID) == accepted.snapshot)
    }
    @Test func unrelatedActualSetCannotHideRemovedMovementProblem() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var original = try await s.draft(empty: true)
        for i in original.logs.indices { original.logs[i].status = .skipped }
        original.logs[0].problem = .controlLost
        original.logs[1].status = .partial
        original.logs[1].actualSets = [ActualSet(reps: 10)]
        try await s.repository.saveDraft(original)
        let before = try await s.repository.snapshot(programID: s.programID)
        let backup = try await s.repository.exportBackup()
        var erased = original; erased.logs[0].problem = .none
        #expect(!erased.workingSetsStarted && erased.hasObservations)
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(erased) }
        #expect(try await s.repository.snapshot(programID: s.programID) == before)
        #expect(try await s.repository.exportBackup() == backup)
        let reopened = try await s.reopened()
        #expect(try await reopened.snapshot(programID: s.programID) == before)
        #expect(try await reopened.exportBackup().drafts == backup.drafts)
        var omitted = s.firstEvent; omitted.exercises = erased.logs
        let rejected = try await reopened.finalize(programID: s.programID, expectedRevision: 0, event: omitted, next: s.next)
        #expect(rejected.result == .rejected(nextState: before.state, errors: ["draft_binding_conflict"]))
        #expect(rejected.snapshot == before)
        var truthful = s.firstEvent; truthful.exercises = original.logs
        let accepted = try await reopened.finalize(programID: s.programID, expectedRevision: 0, event: truthful, next: s.next)
        #expect(accepted.snapshot.state.revision == 1)
        #expect(accepted.snapshot.history.last!.command == .workout(completedWorkout: truthful, next: s.next))
        let safety = accepted.snapshot.state.baseSafety![original.logs[0].baseMovementID!]!
        #expect(safety.paused && safety.sourceEventIDs.contains(truthful.eventID))
        await reopened.close()
        let finalReader = try TrainingRepository.open(at: s.storeURL)
        #expect(try await finalReader.snapshot(programID: s.programID) == accepted.snapshot)
    }
    @Test func draftMayAppendSetsAndUpdateEffortStatusWithoutReplacingObservations() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await s.draft(empty: true)
        try await s.repository.saveDraft(draft)
        draft.workingSetsStarted = true
        draft.logs[0].actualSets = [ActualSet(reps: 8)]
        draft.logs[0].status = .partial
        draft.logs[0].finalEffort = .onTarget
        try await s.repository.saveDraft(draft)
        draft.logs[0].actualSets.append(ActualSet(reps: 10))
        draft.logs[0].status = .stopped
        draft.logs[0].finalEffort = .tooHard
        draft.logs[0].problem = .pain
        try await s.repository.saveDraft(draft)
        #expect(try await s.repository.snapshot(programID: s.programID).draft == draft)
        let backup = try await s.repository.exportBackup()
        var altered = draft; altered.logs[0].actualSets[0].reps = 7
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(altered) }
        altered = draft; altered.logs[0].actualSets.reverse()
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(altered) }
        altered = draft; altered.logs[0].actualSets[0].leftReps = 8
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(altered) }
        altered = draft; altered.logs[0].actualLoad = Load(amount: "10", unit: .lb, basis: .perImplement)
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(altered) }
        altered = draft; altered.logs[0].problem = .controlLost
        await #expect(throws: (any Error).self) { try await s.repository.saveDraft(altered) }
        #expect(try await s.repository.exportBackup() == backup)
        let reopened = try await s.reopened()
        #expect(try await reopened.snapshot(programID: s.programID).draft == draft)
        #expect(try await reopened.exportBackup().drafts == backup.drafts)
    }
}

extension RepositoryTests {
    @Test func draftReceiptIsDurableAndFailedSaveRetainsPreviousProjection() async throws {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        let draft = try await scenario.draft(empty: true)
        let receipt = try await scenario.repository.saveDraft(draft)
        #expect(receipt.draft == draft)
        #expect(receipt == (try await scenario.repository.snapshot(programID: scenario.programID)))
        #expect(try await scenario.repository.snapshots() == [receipt])
        var changed = draft
        changed.logs[0].actualSets = [ActualSet(reps: 8)]
        changed.workingSetsStarted = true
        await scenario.repository.failNextSave()
        await #expect(throws: (any Error).self) { try await scenario.repository.saveDraft(changed) }
        #expect(receipt == (try await scenario.repository.snapshot(programID: scenario.programID)))
        let reopened = try await scenario.reopened()
        #expect(receipt == (try await reopened.snapshot(programID: scenario.programID)))
        await reopened.close()
    }
}


extension RepositoryTests {
    @MainActor @Test func opaqueArchivedRootContributesSafetyWithoutChangingItsBytes() async throws {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        let selected = try await scenario.repository.snapshot(programID: scenario.programID)
        var document = try await scenario.repository.exportBackup()
        let rules = try RulesetCatalog.fixedV1()
        var config = try selectFixedProgram(goal: .size, programID: UUID())
        config.programID = "synthetic-opaque-archived-root"
        config.variants = [:]; config.activeVariantIDs = [:]
        for movement in config.movements {
            let id = try defaultVariantID(programID: config.programID, baseMovementID: movement.id)
            config.variants![id] = MovementVariant(id: id, baseMovementID: movement.id, modifications: "")
            config.activeVariantIDs![movement.id] = id
        }
        let slot = WorkoutSlot(date: scenario.firstEvent.date, slotID: config.weeklySlots[0].id)
        let initialized = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
        func envelope(_ command: JournalCommand, parent: JournalEnvelope?, result: ConfigurationResult) throws -> JournalEnvelope {
            var value = JournalEnvelope(schemaVersion: result.state.schemaVersion, datasetID: document.datasetID,
                programID: config.programID, eventID: UUID().uuidString.lowercased(), eventHash: try BackupService.eventHash(command),
                parentEnvelopeHash: parent?.envelopeHash, inputRevision: parent?.returnedState.revision ?? -1,
                inputStateHash: try parent.map { try BackupService.hash($0.returnedState) },
                rulesetVersion: rules.version, rulesetHash: rules.hash, profileID: config.profileID!, profileHash: config.profileHash!,
                sourceProfileID: config.sourceProfileID!, sourceProfileHash: config.sourceProfileHash!, command: command,
                returnedState: result.state, returnedPrescription: result.workout, decisions: result.decisions, envelopeHash: "")
            value.envelopeHash = try BackupService.envelopeHash(value)
            return value
        }
        let root = try envelope(.initialize(config: config, firstWorkout: slot), parent: nil,
            result: ConfigurationResult(state: initialized.state, workout: initialized.workout, decisions: []))
        let base = config.movements[0].id
        let command = JournalCommand.reconfigure(change: .minimumRir(baseMovementID: base, value: 4), next: slot)
        let changed = try BackupService.transition(state: initialized.state, command: command, rules: rules)
        let head = try envelope(command, parent: root, result: changed)
        let objects = try [root, head].map { try BackupService.object($0, id: $0.eventID) }
        document.journal += objects
        document.heads[config.programID] = head.envelopeHash
        _ = try await scenario.repository.importBackup(document)
        let admission = try await scenario.repository.workingAdmission(for: selected.state)
        #expect(admission.roots.contains { $0.state.config.programID == config.programID })
        let model = WorkoutViewModel(repository: scenario.repository, snapshot: selected, timeZoneID: "Pacific/Honolulu")
        try await model.operations.perform { operation in
            try await model.refreshWorkingAdmission(operation: operation)
        }
        let row = try #require(selected.state.activePrescription.exercises.first { $0.baseMovementID == base })
        #expect(model.blockedWorkingMovementIDs.contains(row.movementID))
        let exported = try await scenario.repository.exportBackup()
        for object in objects { #expect(exported.journal.first { $0.id == object.id }?.bytes == object.bytes) }
        await scenario.repository.close()
    }
}

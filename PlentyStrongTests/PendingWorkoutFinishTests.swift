import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@MainActor @Suite(.serialized) struct PendingWorkoutFinishTests {
    private func legacyFixture() async throws -> GuidedWorkoutFixture {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        _ = try await scenario.repository.saveDraft(scenario.draft(empty: true))
        let snapshot = try await scenario.repository.snapshot(programID: scenario.programID)
        let model = WorkoutViewModel(repository: scenario.repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu",
            now: { ISO8601DateFormatter().date(from: "2026-10-04T20:00:00Z")! })
        return GuidedWorkoutFixture(model: model, repository: scenario.repository, storeURL: scenario.storeURL)
    }
    private func ready(_ f: GuidedWorkoutFixture, invalid: Bool = false, audited: Bool = false) async throws -> WorkoutDraft {
        var draft = try #require(f.model.snapshot.draft)
        if audited {
            let row = draft.displayed.exercises[0], movement = f.model.movement(for: row)
            draft.logs[0].actualLoad = movement.loadingMode == .externalLoad ? movement.availableLoads.first : nil
            draft.logs[0].actualSets = [ActualSet(reps: 8, leftReps: movement.repCounting == .perSide ? 8 : nil,
                rightReps: movement.repCounting == .perSide ? 8 : nil, setIndex: 0)]
            draft.workingSetsStarted = true
            draft.flow?.forward = .set(movementID: row.movementID, index: 1)
            _ = try await f.repository.saveDraft(draft)
            var actual = draft.logs[0].actualSets[0]; actual.reps = 9
            if actual.leftReps != nil { actual.leftReps = 9 }
            if actual.rightReps != nil { actual.rightReps = 9 }
            draft = try #require(await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft),
                operationID: UUID(), movementID: row.movementID, setIndex: 0, replacement: actual).draft)
        }
        for i in draft.logs.indices where !audited || i != 0 { draft.logs[i].status = .skipped }
        draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
        draft.flow = WorkoutFlow(forward: .workoutReview, reviewedSummaryMovementIDs: draft.logs.map(\.movementID))
        if invalid { draft.logs[0].status = .completed }
        return try #require(await f.repository.saveDraft(draft).draft)
    }
    private func submission(_ draft: WorkoutDraft, state: ProgramState) throws -> PendingWorkoutFinish {
        var event = CompletedWorkout(eventID: draft.id.uuidString.lowercased(), date: draft.date, slotID: draft.displayed.slotID,
            prescriptionID: draft.displayed.id, plannedPrescriptionID: draft.planned.id, sessionMode: draft.sessionMode,
            exercises: draft.logs, observationAudit: draft.observationAudit)
        if let start = draft.startedAtMilliseconds {
            event.timing = SessionTiming(plannedDate: draft.planned.date, startedAtMilliseconds: start,
                finishedAtMilliseconds: start + 60_000, timeZoneID: draft.timeZoneID)
        }
        let next = try WorkoutScheduler.nextRotation(after: max(draft.date, draft.planned.date), consumedSlotID: draft.planned.slotID, config: state.config)
        return PendingWorkoutFinish(event: event, next: next, expectedRevision: draft.expectedRevision)
    }
    private func freeze(_ f: GuidedWorkoutFixture, draft: WorkoutDraft) async throws -> WorkoutDraft {
        try #require(await f.repository.freezeDraftFinish(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft),
            submission: submission(draft, state: f.model.snapshot.state)).draft)
    }
    @Test func frozenSubmissionSurvivesRelaunchAtMidnight() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let draft = try await ready(f, audited: true), frozenDraft = try await freeze(f, draft: draft)
        let frozen = try #require(frozenDraft.pendingFinish), before = try await f.repository.exportBackup()
        await f.repository.failNextSave()
        await #expect(throws: EngineError.self) { try await f.repository.finalize(programID: f.model.programID,
            expectedRevision: frozen.expectedRevision, event: frozen.event, next: frozen.next) }
        #expect(try await f.repository.exportBackup() == before)
        await f.repository.close()
        let reopenedRepository = try TrainingRepository.open(at: f.storeURL)
        let reopened = try await reopenedRepository.snapshot(programID: f.model.programID)
        #expect(reopened.draft?.pendingFinish == frozen)
        #expect(frozen.event.observationAudit?.corrections.count == 1)
        #expect(reopened.draft?.pendingFinish?.event.observationAudit == frozen.event.observationAudit)
        let model = WorkoutViewModel(repository: reopenedRepository, snapshot: reopened, timeZoneID: "Pacific/Honolulu",
            now: { ISO8601DateFormatter().date(from: "2026-10-12T10:01:00Z")! })
        #expect(model.hasAmbiguousFinish && !model.needsDateChoice && !model.canDiscardDraft)
        await #expect(throws: EngineError.self) { try await model.start(easierToday: false) }
        await #expect(throws: EngineError.self) { try await model.prepareToday() }
        await #expect(throws: EngineError.self) { try await model.recordEffort(movementID: draft.logs[0].movementID, effort: .tooEasy) }
        let retried = try await model.finish().snapshot
        #expect(retried.history.filter { $0.eventID == frozen.event.eventID }.count == 1)
        guard case let .workout(event, next) = retried.history.last?.command else { Issue.record("Missing workout"); return }
        #expect(try BackupService.bytes(event) == BackupService.bytes(frozen.event))
        #expect(next == frozen.next)
        _ = try await model.finish()
        #expect(try await reopenedRepository.snapshot(programID: model.programID).history == retried.history)
        await reopenedRepository.close()
    }
    @Test func ordinarySaveCannotForgeOrClearFreeze() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let draft = try await ready(f)
        var forged = draft; forged.pendingFinish = try submission(draft, state: f.model.snapshot.state)
        await #expect(throws: EngineError.self) { try await f.repository.saveDraft(forged, expectedExistingDraft: draft) }
        let frozen = try await freeze(f, draft: draft), before = try await f.repository.exportBackup()
        var clear = frozen; clear.pendingFinish = nil
        var replace = frozen; replace.pendingFinish!.event.timing!.finishedAtMilliseconds += 1
        var feedback = frozen; feedback.logs[0].finalEffort = .tooEasy
        for changed in [clear, replace, feedback] {
            await #expect(throws: EngineError.self) { try await f.repository.saveDraft(changed, expectedExistingDraft: frozen) }
        }
        #expect(try await f.repository.exportBackup() == before)
        await f.repository.close()
    }
    @Test func finalizeRejectsChangedFrozenPayload() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let draft = try await ready(f)
        let plain = try submission(draft, state: f.model.snapshot.state)
        let missing = try await f.repository.finalize(programID: f.model.programID, expectedRevision: plain.expectedRevision, event: plain.event, next: plain.next)
        guard case .rejected = missing.result else { Issue.record("Guided freeze bypass"); return }
        let frozen = try #require(await freeze(f, draft: draft).pendingFinish), before = try await f.repository.exportBackup()
        var variants: [PendingWorkoutFinish] = []
        var changed = frozen; changed.event.observationAudit = ObservationAudit(corrections: []); variants.append(changed)
        changed = frozen; changed.event.date = try LocalDate(iso8601: "2026-10-11"); variants.append(changed)
        changed = frozen; changed.event.eventID = UUID().uuidString; variants.append(changed)
        changed = frozen; changed.event.timing!.finishedAtMilliseconds += 1; variants.append(changed)
        changed = frozen; changed.next.date = try LocalDate(iso8601: "2026-10-20"); variants.append(changed)
        changed = frozen; changed.expectedRevision += 1; variants.append(changed)
        for changed in variants {
            let receipt = try await f.repository.finalize(programID: f.model.programID, expectedRevision: changed.expectedRevision, event: changed.event, next: changed.next)
            guard case .rejected = receipt.result else { Issue.record("Changed frozen payload accepted"); continue }
        }
        #expect(try await f.repository.exportBackup() == before)
        await f.repository.close()
    }
    @Test func repairRechecksAbsentEventAndExactDraft() async throws {
        let f = try await legacyFixture()
        let draft = try await ready(f, invalid: true)
        await #expect(throws: EngineError.self) { try await f.repository.repairRejectedDraft(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft)) }
        let frozenDraft = try await freeze(f, draft: draft), frozen = try #require(frozenDraft.pendingFinish)
        let rejected = try await f.repository.finalize(programID: f.model.programID, expectedRevision: frozen.expectedRevision, event: frozen.event, next: frozen.next)
        guard case let .rejected(_, errors) = rejected.result else { Issue.record("Expected rejected completion"); return }
        #expect(errors == ["invalid_sets"])
        let before = try await f.repository.exportBackup()
        await #expect(throws: EngineError.self) { try await f.repository.repairRejectedDraft(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft)) }
        await f.repository.failNextSave()
        await #expect(throws: EngineError.self) { try await f.repository.repairRejectedDraft(programID: f.model.programID, expectedDraftHash: BackupService.hash(frozenDraft)) }
        #expect(try await f.repository.exportBackup() == before)
        let repaired = try #require(await f.repository.repairRejectedDraft(programID: f.model.programID, expectedDraftHash: BackupService.hash(frozenDraft)).draft)
        #expect(repaired.pendingFinish == nil && repaired.logs[0].status == .skipped)
        #expect(repaired.observationAudit == draft.observationAudit)
        #expect(repaired.logs.dropFirst() == draft.logs.dropFirst())
        #expect(repaired.logs[0].actualSets == draft.logs[0].actualSets && repaired.logs[0].actualLoad == draft.logs[0].actualLoad)
        #expect(try await f.repository.exportBackup().journal == before.journal)
        await #expect(throws: EngineError.self) { try await f.repository.repairRejectedDraft(programID: f.model.programID, expectedDraftHash: BackupService.hash(repaired)) }
        await f.repository.close()
    }
    @Test func freezeIsCASBoundIdempotentAndRollsBack() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let draft = try await ready(f), pending = try submission(draft, state: f.model.snapshot.state)
        let before = try await f.repository.exportBackup()
        await f.repository.failNextSave()
        await #expect(throws: EngineError.self) { try await f.repository.freezeDraftFinish(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft), submission: pending) }
        #expect(try await f.repository.exportBackup() == before)
        let frozen = try await f.repository.freezeDraftFinish(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft), submission: pending)
        #expect(try await f.repository.freezeDraftFinish(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft), submission: pending) == frozen)
        var conflict = pending; conflict.event.timing!.finishedAtMilliseconds += 1
        await #expect(throws: EngineError.self) { try await f.repository.freezeDraftFinish(programID: f.model.programID, expectedDraftHash: BackupService.hash(frozen.draft!), submission: conflict) }
        await f.repository.close()
    }
    @Test func legacyNilFlowFinishFreezesWithoutCreatingReviewMetadata() async throws {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await scenario.draft()
        draft.acknowledgedMovementIDs = nil
        draft.logs[0].actualSets = []
        _ = try await scenario.repository.saveDraft(draft)
        let initial = try await scenario.repository.snapshot(programID: scenario.programID)
        let model = WorkoutViewModel(repository: scenario.repository, snapshot: initial, timeZoneID: "Pacific/Honolulu",
            now: { ISO8601DateFormatter().date(from: "2026-10-04T20:00:00Z")! })
        await #expect(throws: EngineError.self) { try await model.finish() }
        #expect(model.canRecoverRejectedCompletion)
        let frozen = try #require(await scenario.repository.snapshot(programID: scenario.programID).draft)
        #expect(frozen.flow == nil && frozen.acknowledgedMovementIDs == nil && frozen.pendingFinish != nil)
        await scenario.repository.close()
        let repository = try TrainingRepository.open(at: scenario.storeURL)
        let snapshot = try await repository.snapshot(programID: scenario.programID)
        let reopened = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu",
            now: { ISO8601DateFormatter().date(from: "2026-10-06T10:01:00Z")! })
        #expect(reopened.hasAmbiguousFinish && !reopened.needsDateChoice)
        await #expect(throws: EngineError.self) { try await reopened.finish() }
        try await reopened.recoverRejectedCompletion()
        let repaired = try #require(reopened.snapshot.draft)
        #expect(repaired.flow == nil && repaired.acknowledgedMovementIDs == nil && repaired.pendingFinish == nil)
        #expect(repaired.logs[0].status == .skipped && repaired.logs[0].actualSets == draft.logs[0].actualSets)
        try await reopened.resolveDateChange(keepOriginal: true)
        let receipt = try await reopened.finish()
        #expect(receipt.snapshot.history.filter { $0.eventID == frozen.pendingFinish!.event.eventID }.count == 1)
        await repository.close()
    }
    @Test func legacySaveCASCannotAuthorizeAcknowledgedDemotion() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let draft = try await ready(f, invalid: true)
        var demoted = draft; demoted.logs[0].status = .skipped
        await #expect(throws: EngineError.self) { try await f.repository.saveDraft(demoted, expectedExistingDraft: draft) }
        #expect(try await f.repository.snapshot(programID: f.model.programID).draft == draft)
        await f.repository.close()
    }
    @Test func acceptedUUIDIdentityBlocksFrozenRepairAndDiscard() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let draft = try await ready(f, invalid: true), frozen = try await freeze(f, draft: draft)
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let first = try WorkoutScheduler.nextSlot(onOrAfter: draft.date, config: config)
        let other = try await f.repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        var event = RepositoryTestHarness.event(state: other.state)
        event.eventID = draft.id.uuidString.uppercased()
        let next = try WorkoutScheduler.nextSlot(after: event.date, config: config)
        let receipt = try await f.repository.finalize(programID: UUID(uuidString: config.programID)!, expectedRevision: other.state.revision, event: event, next: next)
        guard case .applied = receipt.result else { Issue.record("Synthetic sibling event failed"); return }
        let before = try await f.repository.exportBackup()
        await #expect(throws: EngineError.self) { try await f.repository.repairRejectedDraft(programID: f.model.programID, expectedDraftHash: BackupService.hash(frozen)) }
        await #expect(throws: EngineError.self) { try await f.repository.discardDraft(id: draft.id) }
        #expect(try await f.repository.exportBackup() == before)
        await f.repository.close()
    }

    @Test func incompleteGuidedReviewDoesNotCreateFinishLock() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        var draft = try await ready(f)
        draft.flow!.reviewedSummaryMovementIDs.removeLast()
        let snapshot = try await f.repository.saveDraft(draft)
        let model = WorkoutViewModel(repository: f.repository, snapshot: snapshot, timeZoneID: f.model.timeZoneID, now: f.model.now)
        await #expect(throws: EngineError.self) { try await model.finish() }
        #expect(!model.hasAmbiguousFinish && model.snapshot.draft?.pendingFinish == nil)
        var reviewed = draft; reviewed.flow!.reviewedSummaryMovementIDs = draft.logs.map(\.movementID)
        _ = try await f.repository.saveDraft(reviewed)
        await f.repository.close()
    }
    @Test func rejectedRepairPreservesCorrectedRawAuditAndOnlyDemotesInvalidCompletion() async throws {
        let f = try await legacyFixture()
        var draft = try await ready(f, invalid: true)
        let i = 1, row = draft.displayed.exercises[i], movement = f.model.movement(for: row)
        draft.logs[i].status = .partial
        draft.logs[i].actualLoad = movement.loadingMode == .externalLoad ? movement.availableLoads.first : nil
        draft.logs[i].actualSets = [ActualSet(reps: 8, leftReps: movement.repCounting == .perSide ? 8 : nil,
            rightReps: movement.repCounting == .perSide ? 8 : nil)]
        draft.workingSetsStarted = true
        _ = try await f.repository.saveDraft(draft)
        var actual = draft.logs[i].actualSets[0]; actual.reps = 9
        if actual.leftReps != nil { actual.leftReps = 9 }
        if actual.rightReps != nil { actual.rightReps = 9 }
        draft = try #require(await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft),
            operationID: UUID(), movementID: row.movementID, setIndex: 0, replacement: actual).draft)
        draft.flow!.reviewedSummaryMovementIDs = draft.logs.map(\.movementID)
        draft = try #require(await f.repository.saveDraft(draft).draft)
        let frozen = try await freeze(f, draft: draft)
        var omitted = frozen.pendingFinish!.event; omitted.observationAudit = nil
        let receipt = try await f.repository.finalize(programID: f.model.programID, expectedRevision: frozen.expectedRevision,
            event: omitted, next: frozen.pendingFinish!.next)
        guard case .rejected = receipt.result else { Issue.record("Omitted audit accepted"); return }
        let repaired = try #require(await f.repository.repairRejectedDraft(programID: f.model.programID, expectedDraftHash: BackupService.hash(frozen)).draft)
        #expect(repaired.pendingFinish == nil && repaired.logs[0].status == .skipped)
        #expect(try BackupService.bytes(repaired.observationAudit) == BackupService.bytes(draft.observationAudit))
        #expect(try BackupService.bytes(repaired.logs[i]) == BackupService.bytes(draft.logs[i]))
        #expect(repaired.flow == draft.flow && repaired.acknowledgedMovementIDs == draft.acknowledgedMovementIDs)
        await f.repository.close()
    }

    private func invalidateEmptyDraft(_ f: GuidedWorkoutFixture, mutation: String) async throws -> StoreSnapshot {
        let state = f.model.snapshot.state
        let next = WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID)
        if mutation == "configuration" {
            return try await f.repository.applyConfiguration(programID: f.model.programID, expectedRevision: state.revision,
                change: .goal(.maintenance), next: next, invalidateEmptyDraft: true)
        }
        let base = try #require(state.activePrescription.exercises[0].baseMovementID)
        return try await f.repository.applyVariantChange(programID: f.model.programID, expectedRevision: state.revision,
            change: .create(baseMovementID: base, variantID: "synthetic-finish-invalidation", modifications: "Synthetic grip"),
            next: next, invalidateEmptyDraft: true)
    }
    @Test(arguments: ["configuration", "variant"])
    func invalidationCannotClearEmptyFrozenFinish(mutation: String) async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let ready = try await ready(f), frozen = try await freeze(f, draft: ready)
        #expect(!frozen.hasObservations && frozen.pendingFinish != nil)
        let before = try await f.repository.snapshot(programID: f.model.programID)
        let backup = try await f.repository.exportBackup(), counts = try await f.repository.counts()
        await #expect(throws: EngineError.self) { try await invalidateEmptyDraft(f, mutation: mutation) }
        let after = try await f.repository.snapshot(programID: f.model.programID)
        let retained = try await f.repository.exportBackup()
        #expect(try BackupService.bytes(after.draft) == BackupService.bytes(before.draft))
        #expect(retained.journal == backup.journal && retained.heads == backup.heads)
        #expect(after.state.revision == before.state.revision)
        #expect(try BackupService.bytes(retained) == BackupService.bytes(backup))
        #expect(try await f.repository.counts() == counts)
        await f.repository.close()
    }
    @Test(arguments: ["configuration", "variant"])
    func editableEmptyDraftStillAllowsExplicitInvalidation(mutation: String) async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let draft = try #require(f.model.snapshot.draft)
        #expect(!draft.hasObservations && draft.pendingFinish == nil)
        let before = try await f.repository.exportBackup()
        let changed = try await invalidateEmptyDraft(f, mutation: mutation)
        #expect(changed.draft == nil && changed.state.revision == draft.expectedRevision + 1)
        let after = try await f.repository.exportBackup()
        #expect(before.journal.allSatisfy { after.journal.contains($0) })
        #expect(after.journal.count == before.journal.count + 1)
        if mutation == "configuration" { #expect(changed.state.config.goal == .maintenance) }
        else { #expect(changed.state.config.variants?["synthetic-finish-invalidation"]?.modifications == "Synthetic grip") }
        await f.repository.close()
    }

}

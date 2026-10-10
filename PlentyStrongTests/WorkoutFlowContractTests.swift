import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@MainActor @Suite(.serialized) struct WorkoutFlowContractTests {
    @Test func nilMetadataPreservesCanonicalDraft() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let draft = try #require(f.model.snapshot.draft)
        let bytes = try BackupService.bytes(draft)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for key in ["flow", "observationAudit", "pendingFinish"] { #expect(object[key] == nil) }
        #expect(try BackupService.bytes(JSONDecoder().decode(WorkoutDraft.self, from: bytes)) == bytes)
        #expect(draft.flow == nil && draft.observationAudit == nil && draft.pendingFinish == nil)
        await f.repository.close()
    }

    @Test func legacyReconciliationNeverInfersCompletion() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        var draft = try #require(f.model.snapshot.draft)
        let row = draft.displayed.exercises[0], id = row.movementID
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .introduction(movementID: id))
        for status in [LogStatus.skipped, .completed, .stopped] {
            var legacy = draft
            legacy.acknowledgedMovementIDs = nil
            legacy.logs[0].status = status
            legacy.logs[0].skippedSetIndices = nil
            if status != .skipped {
                legacy.logs[0].actualSets = [ActualSet(reps: row.sets[0].targetReps!, setIndex: 0)]
            }
            let originalLogs = legacy.logs
            let flow = try WorkoutFlowResolver.reconciled(legacy)
            #expect(flow.forward == .summary(movementID: id), "Declared \(status) must not reopen work")
            #expect(flow.reviewedSummaryMovementIDs.isEmpty)
            #expect(legacy.acknowledgedMovementIDs == nil && legacy.logs == originalLogs)
            legacy.flow = flow
            do { try WorkoutFlowResolver.validate(legacy) }
            catch { Issue.record("A reconciled legacy \(status) flow must be admitted: \(error)") }
            #expect(legacy.acknowledgedMovementIDs == nil && legacy.logs == originalLogs)
        }
        draft.restDeadline = Date(timeIntervalSince1970: 1791662520)
        draft.logs[0].actualSets = [ActualSet(reps: row.sets[0].targetReps!, setIndex: 0)]
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .set(movementID: id, index: 1))
        draft.logs[0].status = .stopped
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .summary(movementID: id))
        #expect(draft.acknowledgedMovementIDs == [])
        draft.logs[0].status = .partial
        draft.logs[0].skippedSetIndices = Array(row.sets.indices.dropFirst())
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .summary(movementID: id))
        #expect(draft.logs[0].status == .partial)
        #expect(draft.acknowledgedMovementIDs == [])
        draft.acknowledgedMovementIDs = [id]
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .introduction(movementID: draft.logs[1].movementID))
        draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .workoutReview)
        #expect(try WorkoutFlowResolver.reconciled(draft).reviewedSummaryMovementIDs.isEmpty)
        await f.repository.close()
    }

    @Test func invalidCursorAndFutureVersionsReject() async throws {
        let f = try await GuidedWorkoutFixture.make()
        var draft = try #require(f.model.snapshot.draft)
        let id = draft.logs[0].movementID, other = draft.logs[1].movementID
        let invalid: [WorkoutStep] = [.set(movementID: id, index: -1), .set(movementID: id, index: 1),
            .set(movementID: other, index: 0), .summary(movementID: "unknown"), .summary(movementID: id),
            .workoutReview, .rest(sourceMovementID: id, sourceSetIndex: 0, destination: .set(movementID: id, index: 1))]
        for step in invalid {
            draft.flow = WorkoutFlow(forward: step, reviewedSummaryMovementIDs: [])
            #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(draft) }
        }
        draft.flow = WorkoutFlow(version: 2, forward: .introduction(movementID: id), reviewedSummaryMovementIDs: [])
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.reconciled(draft) }
        draft.flow = WorkoutFlow(forward: .introduction(movementID: id), reviewedSummaryMovementIDs: [id])
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(draft) }
        await f.repository.close()
    }

    @Test func restBindsItsPerformedSourceAndIssuedDestination() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        var draft = try #require(f.model.snapshot.draft)
        let row = draft.displayed.exercises[0], id = row.movementID
        draft.logs[0].actualSets = [ActualSet(reps: row.sets[0].targetReps!, setIndex: 0)]
        draft.restDeadline = Date(timeIntervalSince1970: 1791662520)
        draft.flow = WorkoutFlow(forward: .rest(sourceMovementID: id, sourceSetIndex: 0, destination: .set(movementID: id, index: 1)), reviewedSummaryMovementIDs: [])
        try WorkoutFlowResolver.validate(draft)
        var bad = draft; bad.logs[0].status = .completed
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        bad.flow!.forward = .set(movementID: id, index: 1)
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.restDeadline = nil
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.flow!.forward = .rest(sourceMovementID: id, sourceSetIndex: 1, destination: .set(movementID: id, index: 1))
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        draft.acknowledgedMovementIDs = [id]
        draft.flow!.reviewedSummaryMovementIDs = [id]
        draft.flow!.forward = .rest(sourceMovementID: id, sourceSetIndex: 0, destination: .introduction(movementID: draft.logs[1].movementID))
        try WorkoutFlowResolver.validate(draft)
        let cursor = draft.flow!.forward, deadline = draft.restDeadline
        draft.flow!.reviewedSummaryMovementIDs = []
        try WorkoutFlowResolver.validate(draft)
        #expect(draft.flow!.forward == cursor && draft.restDeadline == deadline)
        for status in [LogStatus.stopped, .completed, .skipped] {
            bad = draft; bad.logs[1].status = status
            #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
            bad.flow!.forward = .introduction(movementID: draft.logs[1].movementID)
            #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        }
        bad = draft; bad.acknowledgedMovementIDs = []
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.flow!.forward = .rest(sourceMovementID: "unknown", sourceSetIndex: 0, destination: .introduction(movementID: draft.logs[1].movementID))
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.flow!.forward = .rest(sourceMovementID: id, sourceSetIndex: 0, destination: .introduction(movementID: "unknown"))
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.logs[0].problem = .pain; bad.logs[0].status = .stopped
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        if draft.logs.count > 2 {
            bad = draft; bad.acknowledgedMovementIDs!.append(draft.logs[1].movementID)
            bad.flow!.forward = .rest(sourceMovementID: id, sourceSetIndex: 0, destination: .introduction(movementID: draft.logs[2].movementID))
            #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        }
        await f.repository.close()
    }

    @Test func pendingFinishBindsAllInputs() async throws {
        for schema in [3, 4] {
            let f = try await GuidedWorkoutFixture.make(schemaVersion: schema)
            var draft = readyDraft(try #require(f.model.snapshot.draft))
            draft.pendingFinish = try pending(draft, state: f.model.snapshot.state)
            let rules = try RulesetCatalog.resolve(version: f.model.snapshot.state.rulesetVersion, hash: f.model.snapshot.state.rulesetHash)
            try BackupService.validateDraft(draft, state: f.model.snapshot.state, rules: rules)
            var mutations: [WorkoutDraft] = []
            var bad = draft; bad.pendingFinish!.version = 2; mutations.append(bad)
            bad = draft; bad.pendingFinish!.expectedRevision += 1; mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.eventID = UUID().uuidString.lowercased(); mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.prescriptionID = "different"; mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.plannedPrescriptionID = "different"; mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.slotID = "different"; mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.date = try draft.date.adding(days: 1); mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.sessionMode = .easier; mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.exercises[0].finalEffort = .tooEasy; mutations.append(bad)
            bad = draft; bad.pendingFinish!.event.observationAudit = ObservationAudit(corrections: []); mutations.append(bad)
            bad = draft; bad.pendingFinish!.next.slotID = "unknown"; mutations.append(bad)
            bad = draft; bad.pendingFinish!.next.date = draft.date; mutations.append(bad)
            bad = draft; bad.flow!.reviewedSummaryMovementIDs.removeLast(); mutations.append(bad)
            bad = draft; bad.acknowledgedMovementIDs!.removeLast(); mutations.append(bad)
            bad = draft; bad.flow = nil; mutations.append(bad)
            if draft.startedAtMilliseconds != nil {
                bad = draft; bad.pendingFinish!.event.timing!.timeZoneID = "UTC"; mutations.append(bad)
                bad = draft; bad.pendingFinish!.event.timing!.startedAtMilliseconds += 1; mutations.append(bad)
                bad = draft; bad.pendingFinish!.event.timing!.finishedAtMilliseconds = Int64.min; mutations.append(bad)
                bad = draft; bad.pendingFinish!.event.timing!.plannedDate = try draft.planned.date.adding(days: 1); mutations.append(bad)
                bad = draft; bad.pendingFinish!.event.timing = nil; mutations.append(bad)
            } else {
                bad = draft; bad.pendingFinish!.event.timing = SessionTiming(plannedDate: draft.planned.date, startedAtMilliseconds: 1791662400000, finishedAtMilliseconds: 1791662460000, timeZoneID: draft.timeZoneID); mutations.append(bad)
            }
            for (index, invalid) in mutations.enumerated() { #expect(throws: (any Error).self, "schema \(schema), mutation \(index)") { try BackupService.validateDraft(invalid, state: f.model.snapshot.state, rules: rules) } }
            let bytes = try BackupService.bytes(draft)
            #expect(try JSONDecoder().decode(WorkoutDraft.self, from: bytes) == draft)
            await f.repository.close()
        }
    }

    @Test func workoutReviewReadinessIsSeparateFromFinishReadiness() async throws {
        let f = try await GuidedWorkoutFixture.make()
        var draft = readyDraft(try #require(f.model.snapshot.draft))
        draft.flow!.reviewedSummaryMovementIDs.removeLast()
        try WorkoutFlowResolver.validate(draft)
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .workoutReview)
        draft.pendingFinish = try pending(draft, state: f.model.snapshot.state)
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(draft) }
        await f.repository.close()
    }

    @Test func metadataAndAuditRoundTripThroughBothBackupFormats() async throws {
        let f = try await GuidedWorkoutFixture.make()
        var draft = readyDraft(try #require(f.model.snapshot.draft))
        let row = draft.displayed.exercises[0]
        let before = ActualSet(reps: row.sets[0].targetReps!, setIndex: 0)
        let after = ActualSet(reps: before.reps + 1, setIndex: 0)
        draft.logs[0].actualSets = [after]; draft.logs[0].status = .partial
        draft.observationAudit = ObservationAudit(corrections: [SetCorrection(operationID: UUID(),
            movementID: row.movementID, setIndex: 0, before: before, after: after,
            beforeStatus: .partial, afterStatus: .partial, outcomeAcknowledged: true)])
        draft.pendingFinish = try pending(draft, state: f.model.snapshot.state)
        var v1 = try await f.repository.exportBackup()
        v1.drafts[0] = try BackupService.object(draft, id: v1.drafts[0].id)
        var v2 = v1; v2.formatVersion = 2
        let batch = try RecoveryVerifier().verify(BackupService.recoveryRecords(v1))
        v2.recovery = BackupService.graphManifest(batch, originals: [], quarantines: [], resolved: [])
        for original in [v1, v2] {
            let bytes = try BackupService.bytes(original)
            let decoded = try JSONDecoder().decode(BackupDocument.self, from: bytes)
            _ = try BackupService.validate(decoded)
            #expect(try JSONDecoder().decode(WorkoutDraft.self, from: decoded.drafts[0].bytes) == draft)
            var bad = draft; bad.observationAudit!.version = 2
            bad.pendingFinish!.event.observationAudit = bad.observationAudit
            var document = original; document.drafts[0] = try BackupService.object(bad, id: original.drafts[0].id)
            #expect(throws: (any Error).self) { try BackupService.validate(document) }
            bad = draft; bad.observationAudit!.corrections[0].after.reps += 1
            bad.pendingFinish!.event.observationAudit = bad.observationAudit
            document.drafts[0] = try BackupService.object(bad, id: original.drafts[0].id)
            #expect(throws: (any Error).self) { try BackupService.validate(document) }
            bad = draft; bad.flow!.version = 2
            document.drafts[0] = try BackupService.object(bad, id: original.drafts[0].id)
            #expect(throws: (any Error).self) { try BackupService.validate(document) }
        }
        await f.repository.close()
    }

    @Test func legacyArrayPositionsAndNilStartRemainAdmitted() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        var draft = try #require(f.model.snapshot.draft)
        let row = draft.displayed.exercises[0]
        draft.logs[0].actualSets = [ActualSet(reps: 8)]
        draft.logs[0].skippedSetIndices = nil
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .set(movementID: row.movementID, index: 1))
        draft = readyDraft(try #require(f.model.snapshot.draft))
        draft.startedAtMilliseconds = nil; draft.date = draft.planned.date
        var state = f.model.snapshot.state; state.schedulingPolicy = nil
        draft.pendingFinish = try pending(draft, state: state)
        let rules = try RulesetCatalog.resolve(version: state.rulesetVersion, hash: state.rulesetHash)
        try BackupService.validateDraft(draft, state: state, rules: rules)
        var bad = draft
        bad.pendingFinish!.event.timing = SessionTiming(plannedDate: draft.planned.date,
            startedAtMilliseconds: 1791662400000, finishedAtMilliseconds: 1791662460000, timeZoneID: draft.timeZoneID)
        #expect(throws: (any Error).self) { try BackupService.validateDraft(bad, state: state, rules: rules) }
        bad = draft; bad.flow!.reviewedSummaryMovementIDs.append(draft.logs[0].movementID)
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.flow!.reviewedSummaryMovementIDs.append("unissued")
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(bad) }
        await f.repository.close()
    }

    @Test func frozenEventBindsExactRawText() async throws {
        let f = try await GuidedWorkoutFixture.make()
        var draft = readyDraft(try #require(f.model.snapshot.draft))
        draft.logs[0].modificationsSnapshot = "caf\u{00e9}"
        draft.pendingFinish = try pending(draft, state: f.model.snapshot.state)
        try WorkoutFlowResolver.validate(draft)
        let original = draft.pendingFinish!.event
        draft.pendingFinish!.event.exercises[0].modificationsSnapshot = "cafe\u{0301}"
        #expect(draft.pendingFinish!.event == original)
        #expect(try BackupService.bytes(draft.pendingFinish!.event) != BackupService.bytes(original))
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(draft) }
        await f.repository.close()
    }

    @Test func legacyOverflowRemainsRawAndResumesSummaryWithoutOutOfRangeCursors() async throws {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await scenario.draft()
        let id = draft.logs[0].movementID, count = draft.displayed.exercises[0].sets.count
        draft.logs[0].actualSets.append(ActualSet(reps: 1))
        draft.logs[0].status = .partial
        let raw = draft.logs
        let rules = try RulesetCatalog.fixedV1()
        let state = try await scenario.repository.snapshot(programID: scenario.programID).state
        try BackupService.validateDraft(draft, state: state, rules: rules)
        #expect(try WorkoutFlowResolver.reconciled(draft).forward == .summary(movementID: id))
        _ = try await scenario.repository.saveDraft(draft)
        draft.flow = try WorkoutFlowResolver.reconciled(draft)
        try BackupService.validateDraft(draft, state: state, rules: rules)
        _ = try await scenario.repository.saveDraft(draft)
        #expect(try await scenario.repository.snapshot(programID: scenario.programID).draft?.logs == raw)
        var bad = draft; bad.flow!.forward = .set(movementID: id, index: count)
        #expect(throws: EngineError.self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.restDeadline = Date(timeIntervalSinceReferenceDate: 812_000_000)
        bad.flow!.forward = .rest(sourceMovementID: id, sourceSetIndex: count, destination: .introduction(movementID: draft.logs[1].movementID))
        #expect(throws: EngineError.self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.logs[0].actualSets = [ActualSet(reps: 8, setIndex: count)]
        #expect(throws: EngineError.self) { try WorkoutFlowResolver.validate(bad) }
        bad = draft; bad.logs[0].actualSets = []; bad.logs[0].skippedSetIndices = [count]
        #expect(throws: EngineError.self) { try WorkoutFlowResolver.validate(bad) }
        let reopened = try await scenario.reopened()
        #expect(try await reopened.snapshot(programID: scenario.programID).draft?.logs == raw)
        await reopened.close()
    }

    private func readyDraft(_ original: WorkoutDraft) -> WorkoutDraft {
        var draft = original
        for i in draft.logs.indices { draft.logs[i].status = .skipped }
        draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
        draft.flow = WorkoutFlow(forward: .workoutReview, reviewedSummaryMovementIDs: draft.logs.map(\.movementID))
        return draft
    }
    private func pending(_ draft: WorkoutDraft, state: ProgramState) throws -> PendingWorkoutFinish {
        var event = CompletedWorkout(eventID: draft.id.uuidString.lowercased(), date: draft.date, slotID: draft.displayed.slotID,
            prescriptionID: draft.displayed.id, plannedPrescriptionID: draft.planned.id, sessionMode: draft.sessionMode,
            exercises: draft.logs, observationAudit: draft.observationAudit)
        let next: WorkoutSlot
        if let start = draft.startedAtMilliseconds {
            event.timing = SessionTiming(plannedDate: draft.planned.date, startedAtMilliseconds: start,
                finishedAtMilliseconds: start + 60_000, timeZoneID: draft.timeZoneID)
            next = try WorkoutScheduler.nextRotation(after: max(draft.date, draft.planned.date), consumedSlotID: draft.planned.slotID, config: state.config)
        } else { next = try WorkoutScheduler.nextSlot(after: draft.date, config: state.config) }
        return PendingWorkoutFinish(event: event, next: next, expectedRevision: draft.expectedRevision)
    }
}

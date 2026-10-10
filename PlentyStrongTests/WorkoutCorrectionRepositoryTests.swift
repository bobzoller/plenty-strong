import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@MainActor @Suite(.serialized) struct WorkoutCorrectionRepositoryTests {
    private func recorded(_ fixture: GuidedWorkoutFixture, reps: Int = 7) async throws -> WorkoutDraft {
        var draft = try #require(fixture.model.snapshot.draft)
        draft.logs[0].actualSets = [ActualSet(reps: reps, setIndex: 0, missedGoalReason: reps < 8 ? .effortLimit : nil)]
        draft.workingSetsStarted = true
        return try #require(await fixture.repository.saveDraft(draft).draft)
    }
    private func correct(_ fixture: GuidedWorkoutFixture, draft: WorkoutDraft, operationID: UUID = UUID(), replacement: ActualSet) async throws -> StoreSnapshot {
        try await fixture.repository.correctDraftSet(programID: fixture.model.programID,
            expectedDraftHash: BackupService.hash(draft), operationID: operationID,
            movementID: draft.logs[0].movementID, setIndex: 0, replacement: replacement)
    }
    @Test func correctionRetainsOriginalAndIsIdempotent() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let before = try await recorded(f), op = UUID(), replacement = ActualSet(reps: 8, setIndex: 0)
        let corrected = try await correct(f, draft: before, operationID: op, replacement: replacement)
        let after = try #require(corrected.draft), trail = try #require(after.observationAudit?.corrections)
        #expect(trail.count == 1)
        #expect(trail[0].before.reps == 7 && trail[0].after.reps == 8)
        #expect(try ObservationAuditValidator.originalLogs(effective: after.logs, audit: after.observationAudit,
            prescription: after.displayed, config: corrected.state.config, schemaVersion: 3) == before.logs)
        var feedback = after; feedback.logs[0].finalEffort = .tooEasy
        let changed = try await f.repository.saveDraft(feedback)
        #expect(try await correct(f, draft: before, operationID: op, replacement: replacement) == changed)
        await #expect(throws: EngineError.self) { try await correct(f, draft: before, operationID: op, replacement: ActualSet(reps: 9, setIndex: 0)) }
        #expect(try await correct(f, draft: feedback, replacement: replacement) == changed)
        #expect(try await f.repository.snapshot(programID: f.model.programID) == changed)
        await f.repository.close()
    }
    @Test func ordinarySaveCannotRewriteAuditOrRawData() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let original = try await recorded(f)
        let before = try #require(await correct(f, draft: original, replacement: ActualSet(reps: 8, setIndex: 0)).draft)
        var forged = before; forged.observationAudit = nil
        var variants = [forged]
        forged = before; forged.observationAudit!.corrections[0].operationID = UUID(); variants.append(forged)
        forged = before; forged.observationAudit!.corrections[0].before.reps = 6; variants.append(forged)
        forged = before; forged.logs[0].actualSets[0].reps = 9; variants.append(forged)
        forged = before; forged.logs[0].actualLoad = f.model.movement(for: before.displayed.exercises[0]).availableLoads.first; variants.append(forged)
        forged = before; forged.logs[0].actualSets = []; variants.append(forged)
        for forgedAuditDraft in variants {
            await #expect(throws: EngineError.self) { try await f.repository.saveDraft(forgedAuditDraft) }
            #expect(try await f.repository.snapshot(programID: f.model.programID).draft == before)
        }
        await f.repository.close()
    }
    @Test func staleCorrectionDemotesWithoutReopening() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        var draft = try #require(f.model.snapshot.draft)
        let row = draft.displayed.exercises[0], id = row.movementID
        draft.logs[0].actualLoad = f.model.movement(for: row).availableLoads.first
        draft.logs[0].actualSets = row.sets.indices.map { ActualSet(reps: 8, setIndex: $0) }
        draft.logs[0].status = .completed
        draft.workingSetsStarted = true; draft.acknowledgedMovementIDs = [id]
        let deadline = Date(timeIntervalSinceReferenceDate: 812_000_000)
        draft.restDeadline = deadline
        draft.flow = WorkoutFlow(forward: .rest(sourceMovementID: id, sourceSetIndex: row.sets.count - 1,
            destination: .introduction(movementID: draft.logs[1].movementID)), reviewedSummaryMovementIDs: [id])
        let before = try #require(await f.repository.saveDraft(draft).draft)
        var changed = before; changed.logs[1].finalEffort = .onTarget
        let current = try #require(await f.repository.saveDraft(changed).draft)
        await #expect(throws: EngineError.self) { try await correct(f, draft: before, replacement: ActualSet(reps: 0, setIndex: 0, missedGoalReason: .otherUnknown)) }
        let after = try #require(await correct(f, draft: current, replacement: ActualSet(reps: 0, setIndex: 0, missedGoalReason: .otherUnknown)).draft)
        #expect(after.logs[0].status == .partial)
        #expect(after.acknowledgedMovementIDs == before.acknowledgedMovementIDs)
        #expect(after.flow?.forward == before.flow?.forward && after.flow?.reviewedSummaryMovementIDs == [])
        #expect(after.restDeadline == deadline)
        var append = after; append.logs[0].actualSets.append(ActualSet(reps: 8, setIndex: row.sets.count))
        await #expect(throws: EngineError.self) { try await f.repository.saveDraft(append) }
        var promote = after; promote.logs[0].status = .completed
        await #expect(throws: EngineError.self) { try await f.repository.saveDraft(promote) }
        #expect(try await f.repository.snapshot(programID: f.model.programID).draft == after)
        await f.repository.close()
    }
    @Test func preservesAcknowledgedPartialAndStoppedMissingSideOriginals() async throws {
        for stopped in [false, true] {
            let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
            var before = try #require(f.model.snapshot.draft)
            let index = try #require(before.displayed.exercises.firstIndex { f.model.movement(for: $0).repCounting == .perSide })
            let id = before.logs[index].movementID
            before.logs[index].actualSets = [ActualSet(reps: 0, leftReps: 3, setIndex: 0)]
            before.logs[index].status = stopped ? .stopped : .partial
            before.logs[index].problem = stopped ? .pain : .none
            before.acknowledgedMovementIDs = [id]; before.workingSetsStarted = true
            _ = try await f.repository.saveDraft(before)
            let snapshot = try await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(before),
                operationID: UUID(), movementID: id, setIndex: 0, replacement: ActualSet(reps: 8, leftReps: 8, rightReps: 8, setIndex: 0))
            let after = try #require(snapshot.draft)
            #expect(after.logs[index].status == before.logs[index].status)
            #expect(after.logs[index].problem == before.logs[index].problem)
            #expect(after.observationAudit?.corrections[0].before == before.logs[index].actualSets[0])
            var forged = after; forged.logs[index].problem = .none; forged.logs[index].status = .completed
            await #expect(throws: EngineError.self) { try await f.repository.saveDraft(forged) }
            forged = after; forged.acknowledgedMovementIDs = []
            await #expect(throws: EngineError.self) { try await f.repository.saveDraft(forged) }
            await f.repository.close()
        }
    }
    @Test func correctionValidatesRawSidesAndSlotAndRollsBackFailedSave() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 4)
        let before = try await recorded(f, reps: 8)
        for replacement in [ActualSet(reps: -1), ActualSet(reps: 8, setIndex: 1), ActualSet(reps: 8, leftReps: 7), ActualSet(reps: 7)] {
            await #expect(throws: EngineError.self) { try await correct(f, draft: before, replacement: replacement) }
        }
        await #expect(throws: EngineError.self) {
            try await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(before),
                operationID: UUID(), movementID: before.logs[0].movementID, setIndex: 1, replacement: ActualSet(reps: 8))
        }
        await f.repository.failNextSave()
        await #expect(throws: EngineError.self) { try await correct(f, draft: before, replacement: ActualSet(reps: 9)) }
        #expect(try await f.repository.snapshot(programID: f.model.programID).draft == before)
        #expect(try await correct(f, draft: before, replacement: ActualSet(reps: 9)).draft?.logs[0].actualSets[0].setIndex == 0)
        await f.repository.close()
    }
    @Test func cursorSaveCASAndAuditCreationGuard() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let before = try await recorded(f)
        var cursor = before; cursor.flow = WorkoutFlow(forward: .set(movementID: before.logs[0].movementID, index: 1), reviewedSummaryMovementIDs: [])
        _ = try await f.repository.saveDraft(cursor, expectedDraftHash: BackupService.hash(before))
        await #expect(throws: EngineError.self) { try await f.repository.saveDraft(before, expectedDraftHash: BackupService.hash(before)) }
        var forged = cursor; forged.observationAudit = ObservationAudit(corrections: [])
        await #expect(throws: EngineError.self) { try await f.repository.saveDraft(forged) }
        #expect(try await f.repository.snapshot(programID: f.model.programID).draft == cursor)
        await f.repository.close()
    }
    @Test func perSideShortfallRequiresReasonAndPreservesOriginalChain() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        var before = try #require(f.model.snapshot.draft)
        let index = try #require(before.displayed.exercises.firstIndex { f.model.movement(for: $0).repCounting == .perSide })
        let id = before.logs[index].movementID
        before.logs[index].actualSets = [ActualSet(reps: 8, leftReps: 8, rightReps: 8, setIndex: 0)]
        before.workingSetsStarted = true
        _ = try await f.repository.saveDraft(before)
        await #expect(throws: EngineError.self) {
            try await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(before),
                operationID: UUID(), movementID: id, setIndex: 0, replacement: ActualSet(reps: 8, leftReps: 8, rightReps: 7, setIndex: 0))
        }
        let first = try await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(before),
            operationID: UUID(), movementID: id, setIndex: 0, replacement: ActualSet(reps: 8, leftReps: 8, rightReps: 7, setIndex: 0, missedGoalReason: .effortLimit))
        let changed = try #require(first.draft)
        let second = try await f.repository.correctDraftSet(programID: f.model.programID, expectedDraftHash: BackupService.hash(changed),
            operationID: UUID(), movementID: id, setIndex: 0, replacement: ActualSet(reps: 9, leftReps: 9, rightReps: 9, setIndex: 0))
        let final = try #require(second.draft)
        #expect(final.observationAudit?.corrections.count == 2)
        #expect(try ObservationAuditValidator.originalLogs(effective: final.logs, audit: final.observationAudit,
            prescription: final.displayed, config: second.state.config, schemaVersion: 3) == before.logs)
        await f.repository.close()
    }
    @Test func legacyPositionalCorrectionRetainsMissingSidesAndOutcome() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await s.draft(empty: false)
        let state = try await s.repository.snapshot(programID: s.programID).state
        let index = try #require(draft.displayed.exercises.firstIndex { row in
            state.config.movements.first(where: { $0.id == row.baseMovementID })?.repCounting == .perSide
        })
        let id = draft.logs[index].movementID
        draft.logs[index].status = .partial
        draft.logs[index].actualSets[0] = ActualSet(reps: 0, leftReps: 3)
        draft.acknowledgedMovementIDs = [id]
        _ = try await s.repository.saveDraft(draft)
        let after = try await s.repository.correctDraftSet(programID: s.programID, expectedDraftHash: BackupService.hash(draft),
            operationID: UUID(), movementID: id, setIndex: 0, replacement: ActualSet(reps: 8, leftReps: 8, rightReps: 8))
        #expect(after.draft?.logs[index].status == .partial)
        #expect(after.draft?.logs[index].actualSets[0].setIndex == nil)
        #expect(after.draft?.observationAudit?.corrections[0].before == ActualSet(reps: 0, leftReps: 3))
        let reopened = try await s.reopened()
        #expect(try await reopened.snapshot(programID: s.programID).draft == after.draft)
        await reopened.close()
    }
    @Test func frozenFinishBlocksNewCorrectionAndOrdinarySkipRewrite() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        var draft = try await recorded(f, reps: 8)
        draft.logs[0].skippedSetIndices = [1]
        draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
        for index in draft.logs.indices.dropFirst() { draft.logs[index].status = .skipped }
        draft.flow = WorkoutFlow(forward: .workoutReview, reviewedSummaryMovementIDs: draft.logs.map(\.movementID))
        let before = try #require(await f.repository.saveDraft(draft).draft)
        var forged = before; forged.logs[0].skippedSetIndices = []
        await #expect(throws: EngineError.self) { try await f.repository.saveDraft(forged) }
        var event = CompletedWorkout(eventID: draft.id.uuidString.lowercased(), date: draft.date, slotID: draft.displayed.slotID,
            prescriptionID: draft.displayed.id, plannedPrescriptionID: draft.planned.id, sessionMode: draft.sessionMode, exercises: draft.logs)
        if let start = draft.startedAtMilliseconds {
            event.timing = SessionTiming(plannedDate: draft.planned.date, startedAtMilliseconds: start,
                finishedAtMilliseconds: start + 60_000, timeZoneID: draft.timeZoneID)
        }
        let next = try WorkoutScheduler.nextRotation(after: max(draft.date, draft.planned.date), consumedSlotID: draft.planned.slotID, config: f.model.snapshot.state.config)
        draft.pendingFinish = PendingWorkoutFinish(event: event, next: next, expectedRevision: draft.expectedRevision)
        let frozen = try #require(await f.repository.saveDraft(draft).draft)
        let backup = try await f.repository.exportBackup()
        await #expect(throws: EngineError.self) { try await correct(f, draft: frozen, replacement: ActualSet(reps: 9)) }
        #expect(try await f.repository.exportBackup() == backup)
        await f.repository.close()
    }

    @Test func demotedDeclaredCompletionRetainsSummaryWithoutInferredAcknowledgement() async throws {
        for legacy in [false, true] {
            let repository: TrainingRepository, programID: UUID, state: ProgramState
            var before: WorkoutDraft
            if legacy {
                let scenario = try await RepositoryTestHarness.make(goal: .size)
                repository = scenario.repository; programID = scenario.programID
                state = try await repository.snapshot(programID: programID).state
                before = try await scenario.draft()
                before.logs[0].actualSets = [ActualSet(reps: 8)]
                before.acknowledgedMovementIDs = nil
            } else {
                let fixture = try await GuidedWorkoutFixture.make(schemaVersion: 3)
                repository = fixture.repository; programID = fixture.model.programID; state = fixture.model.snapshot.state
                before = try #require(fixture.model.snapshot.draft)
                before.logs[0].actualSets = [ActualSet(reps: 8, setIndex: 0)]
                before.logs[0].status = .completed
                before.acknowledgedMovementIDs = []
            }
            let id = before.logs[0].movementID
            before.workingSetsStarted = true
            before.flow = WorkoutFlow(forward: .summary(movementID: id), reviewedSummaryMovementIDs: [])
            _ = try await repository.saveDraft(before)
            let snapshot = try await repository.correctDraftSet(programID: programID, expectedDraftHash: BackupService.hash(before),
                operationID: UUID(), movementID: id, setIndex: 0,
                replacement: ActualSet(reps: 0, setIndex: legacy ? nil : 0, missedGoalReason: legacy ? nil : .otherUnknown))
            let after = try #require(snapshot.draft)
            try WorkoutFlowResolver.validate(after)
            #expect(after.logs[0].status == .partial && after.flow == before.flow)
            #expect(after.acknowledgedMovementIDs == before.acknowledgedMovementIDs)
            #expect(try ObservationAuditValidator.originalLogs(effective: after.logs, audit: after.observationAudit,
                prescription: after.displayed, config: state.config, schemaVersion: state.schemaVersion) == before.logs)
            var appended = after
            appended.logs[0].actualSets.append(ActualSet(reps: 8, setIndex: legacy ? nil : 1))
            await #expect(throws: EngineError.self) { try await repository.saveDraft(appended) }
            var promoted = after; promoted.logs[0].status = .completed
            await #expect(throws: EngineError.self) { try await repository.saveDraft(promoted) }
            var stopped = after; stopped.logs[0].problem = .pain; stopped.logs[0].status = .stopped
            _ = try await repository.saveDraft(stopped) // legitimate later safety stop still dominates
            appended = stopped; appended.logs[0].actualSets.append(ActualSet(reps: 8, setIndex: legacy ? nil : 1))
            await #expect(throws: EngineError.self) { try await repository.saveDraft(appended) }
            await repository.close()
        }
    }
    @Test func correctionOfDefaultPartialAllowsContinuationAndFirstOutcome() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let first = try #require(f.model.snapshot.draft?.displayed.exercises.first)
        let movement = f.model.movement(for: first)
        if movement.loadingMode == .externalLoad {
            try await f.model.confirmLoad(movementID: first.movementID, load: #require(movement.availableLoads.first))
        }
        let before = try await recorded(f)
        var after = try #require(await correct(f, draft: before, replacement: ActualSet(reps: 8)).draft)
        let row = after.displayed.exercises[0]
        after.logs[0].actualSets.append(contentsOf: row.sets.indices.dropFirst().map { ActualSet(reps: 8, setIndex: $0) })
        _ = try await f.repository.saveDraft(after)
        after.logs[0].status = .completed; after.acknowledgedMovementIDs = [row.movementID]
        _ = try await f.repository.saveDraft(after)
        #expect(try await f.repository.snapshot(programID: f.model.programID).draft == after)
        await f.repository.close()
    }

    @Test func completedEventIdentityOnAnotherRootBlocksCorrectionWithoutWrites() async throws {
        for uppercase in [false, true] {
            let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
            let before = try await recorded(f)
            let foreignID = UUID(), config = try selectFixedProgram(goal: .size, programID: foreignID)
            let first = try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-04"), config: config)
            let foreign = try await f.repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
            var event = RepositoryTestHarness.event(state: foreign.state)
            event.eventID = uppercase ? before.id.uuidString : before.id.uuidString.lowercased()
            let next = try WorkoutScheduler.nextSlot(after: first.date, config: config)
            _ = try await f.repository.finalize(programID: foreignID, expectedRevision: foreign.state.revision, event: event, next: next)
            let backup = try await f.repository.exportBackup()
            await #expect(throws: EngineError.self) { try await correct(f, draft: before, replacement: ActualSet(reps: 8)) }
            #expect(try await f.repository.exportBackup() == backup)
            #expect(try await f.repository.snapshot(programID: f.model.programID).draft == before)
            await f.repository.close()
        }
    }

    @Test func legacyOverflowCorrectionsRetainRawExtrasAcrossBackupFormats() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var before = try await s.draft()
        let extra = ActualSet(reps: 17)
        before.logs[0].actualSets.append(extra)
        _ = try await s.repository.saveDraft(before)
        let original = try await s.repository.exportBackup()
        var effective = before
        // Correct an unrelated normal log first: adding any audit must retain
        // admitted raw extras elsewhere in the same draft.
        for index in [1, 0] {
            var actual = effective.logs[index].actualSets[0]; actual.reps += 1
            if actual.leftReps != nil { actual.leftReps = actual.reps; actual.rightReps = actual.reps }
            effective = try #require(await s.repository.correctDraftSet(programID: s.programID,
                expectedDraftHash: BackupService.hash(effective), operationID: UUID(),
                movementID: effective.logs[index].movementID, setIndex: 0, replacement: actual).draft)
            #expect(try BackupService.bytes(effective.logs[0].actualSets.last) == BackupService.bytes(extra))
        }
        await #expect(throws: EngineError.self) {
            try await s.repository.correctDraftSet(programID: s.programID, expectedDraftHash: BackupService.hash(effective),
                operationID: UUID(), movementID: effective.logs[0].movementID,
                setIndex: effective.displayed.exercises[0].sets.count, replacement: ActualSet(reps: 18))
        }
        let v1 = try await s.repository.exportBackup()
        var v2 = v1; v2.formatVersion = 2
        v2.recovery = BackupService.graphManifest(try RecoveryVerifier().verify(BackupService.recoveryRecords(v1)), originals: [], quarantines: [], resolved: [])
        let sourceReopened = try await s.reopened()
        #expect(try BackupService.bytes(await sourceReopened.snapshot(programID: s.programID).draft) == BackupService.bytes(effective))
        await sourceReopened.close()
        for document in [v1, v2] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("training.store")
            let destination = try TrainingRepository.open(at: url)
            _ = try await destination.importBackup(document); await destination.close()
            let reopened = try TrainingRepository.open(at: url)
            let saved = try await reopened.snapshot(programID: s.programID)
            #expect(try BackupService.bytes(saved.draft) == BackupService.bytes(effective))
            #expect(try await reopened.exportBackup().journal == original.journal)
            #expect(try ObservationAuditValidator.originalLogs(effective: effective.logs, audit: effective.observationAudit,
                prescription: effective.displayed, config: saved.state.config, schemaVersion: 2) == before.logs)
            await reopened.close()
        }
    }

    @Test func nilFlowDemotedCompletionCannotResumeWorkingButDefaultPartialCan() async throws {
        for declaredCompleted in [true, false] {
            let s = try await RepositoryTestHarness.make(goal: .size)
            var before = try await s.draft()
            before.logs[0].actualSets = [ActualSet(reps: 10)]
            before.logs[0].status = declaredCompleted ? .completed : .partial
            #expect(before.flow == nil && before.acknowledgedMovementIDs == nil)
            _ = try await s.repository.saveDraft(before)
            let after = try #require(await s.repository.correctDraftSet(programID: s.programID,
                expectedDraftHash: BackupService.hash(before), operationID: UUID(), movementID: before.logs[0].movementID,
                setIndex: 0, replacement: ActualSet(reps: 0)).draft)
            let id = after.logs[0].movementID
            #expect(after.flow == nil && after.acknowledgedMovementIDs == nil)
            #expect(try WorkoutFlowResolver.reconciled(after).forward == (declaredCompleted ? .summary(movementID: id) : .set(movementID: id, index: 1)))
            for step in [WorkoutStep.set(movementID: id, index: 1),
                .rest(sourceMovementID: id, sourceSetIndex: 0, destination: .set(movementID: id, index: 1))] {
                var cursor = after; cursor.flow = WorkoutFlow(forward: step, reviewedSummaryMovementIDs: [])
                cursor.restDeadline = Date(timeIntervalSince1970: 1791662520)
                if declaredCompleted {
                    await #expect(throws: EngineError.self) { try await s.repository.saveDraft(cursor) }
                    #expect(try BackupService.bytes(await s.repository.snapshot(programID: s.programID).draft) == BackupService.bytes(after))
                } else {
                    _ = try await s.repository.saveDraft(cursor)
                    let saved = try #require(await s.repository.snapshot(programID: s.programID).draft)
                    #expect(saved.logs == after.logs && saved.acknowledgedMovementIDs == nil)
                }
            }
            await s.repository.close()
        }
    }

    @Test func ordinarySaveAndCorrectionBindRawUnicodeMovementIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try TrainingRepository.open(at: directory.appendingPathComponent("training.store"))
        let programID = UUID()
        var config = try selectFixedProgram(goal: .size, programID: programID)
        let base = config.weeklySlots[0].movementIDs[0]
        let rawID = "caf\u{00e9}", equivalent = "cafe\u{0301}"
        config.variants![rawID] = MovementVariant(id: rawID, baseMovementID: base, modifications: "Synthetic Unicode fixture")
        config.activeVariantIDs![base] = rawID
        let first = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: config.weeklySlots[0].id)
        let snapshot = try await repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        let row = snapshot.state.activePrescription
        let movement = try #require(config.movements.first { $0.id == base })
        let raw = ActualSet(reps: 7, leftReps: movement.repCounting == .perSide ? 7 : nil, rightReps: movement.repCounting == .perSide ? 7 : nil)
        let logs = row.exercises.map { item in
            ExerciseLog(movementID: item.movementID, prescriptionID: row.id, status: .partial,
                actualLoad: nil, actualSets: item.movementID == rawID ? [raw] : [], finalEffort: .unknown, problem: .none,
                baseMovementID: item.baseMovementID, modificationsSnapshot: item.modificationsSnapshot)
        }
        let before = WorkoutDraft(id: UUID(), programID: config.programID, expectedRevision: snapshot.state.revision,
            planned: row, displayed: row, date: row.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal, logs: logs, workingSetsStarted: true)
        _ = try await repository.saveDraft(before)
        let index = try #require(before.logs.firstIndex { $0.movementID == rawID })
        var relabeled = before; relabeled.logs[index].movementID = equivalent
        #expect(rawID == equivalent && !rawID.utf8.elementsEqual(equivalent.utf8))
        try BackupService.validateDraft(relabeled, state: snapshot.state, rules: RulesetCatalog.fixedV1())
        await #expect(throws: EngineError.self) { try await repository.saveDraft(relabeled) }
        var replacement = raw; replacement.reps = 8
        if replacement.leftReps != nil { replacement.leftReps = 8; replacement.rightReps = 8 }
        await #expect(throws: EngineError.self) {
            try await repository.correctDraftSet(programID: programID, expectedDraftHash: BackupService.hash(before), operationID: UUID(),
                movementID: equivalent, setIndex: 0, replacement: replacement)
        }
        let corrected = try await repository.correctDraftSet(programID: programID, expectedDraftHash: BackupService.hash(before),
            operationID: UUID(), movementID: rawID, setIndex: 0, replacement: replacement)
        let after = try #require(corrected.draft)
        var forged = after; forged.observationAudit!.corrections[0].movementID = equivalent
        await #expect(throws: EngineError.self) { try await repository.saveDraft(forged) }
        #expect(try BackupService.bytes(await repository.snapshot(programID: programID).draft) == BackupService.bytes(after))
        await repository.close()
    }

}

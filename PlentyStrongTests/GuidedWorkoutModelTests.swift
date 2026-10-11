import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@MainActor @Suite(.serialized) struct GuidedWorkoutModelTests {
    @Test func easierWorkoutIsHiddenWithoutPerformedHistory() async throws {
        let f = try await GuidedWorkoutFixture.make()
        #expect(f.model.canChangePreparation)
        #expect(!f.model.canOfferEasierWorkout)
        for row in f.model.snapshot.draft!.displayed.exercises {
            try await f.model.recordStatus(movementID: row.movementID, status: .skipped)
            try await f.model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        }
        _ = try await f.model.finish()
        let next = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID, now: { f.model.now().addingTimeInterval(86_400) })
        try await next.start(easierToday: false)
        #expect(next.canChangePreparation)
        #expect(!next.canOfferEasierWorkout)
        await f.repository.close()
    }
    @Test func easierWorkoutUsesSameProgramHistoryAndObservationLock() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let first = f.model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(f.model, row: first)
        try await f.model.beginMovement(movementID: first.movementID)
        try await f.model.recordSet(movementID: first.movementID, index: 0, actual: actual(f.model, row: first, index: 0))
        try await f.model.recordStatus(movementID: first.movementID, status: .partial)
        try await f.model.confirmMovementSummary(movementID: first.movementID, effort: .unknown, status: .partial, reviewing: false)
        for row in f.model.snapshot.draft!.displayed.exercises.dropFirst() {
            try await f.model.recordStatus(movementID: row.movementID, status: .skipped)
            try await f.model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        }
        _ = try await f.model.finish()
        let next = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID, now: { f.model.now().addingTimeInterval(86_400) })
        try await next.start(easierToday: false)
        #expect(next.canOfferEasierWorkout)
        let row = next.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(next, row: row)
        #expect(next.canOfferEasierWorkout, "Weight confirmation alone is preparation, not performed work")
        try await next.beginMovement(movementID: row.movementID)
        try await next.recordSet(movementID: row.movementID, index: 0, actual: actual(next, row: row, index: 0))
        #expect(!next.canOfferEasierWorkout)
        // An unrelated initialized program in the same store has no performed history.
        let config = try selectStarterProgram(choice: .upperBody, goal: .size, programID: UUID())
        let rules = try RulesetCatalog.starter(.upperBody)
        let slot = try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-10"), config: config)
        let snapshot = try await f.repository.initialize(config: config, rules: rules, firstWorkout: slot)
        let other = WorkoutViewModel(repository: f.repository, snapshot: snapshot, timeZoneID: f.model.timeZoneID, now: f.model.now)
        try await other.start(easierToday: false)
        #expect(!other.canOfferEasierWorkout)
        await f.repository.close()
    }
    @Test func perSideReasonAndStaleSelection() throws {
        var entry = SetEntryDraft(left: "8", right: "6", reason: .effortLimit)
        #expect(entry.requiresReason(target: 8, repCounting: .perSide))
        let actual = try #require(entry.observation(target: 8, repCounting: .perSide, exact: true))
        #expect(actual.leftReps == 8 && actual.rightReps == 6 && actual.reps == 8)
        entry.update(reps: "", left: "8", right: "8", target: 8, repCounting: .perSide)
        #expect(entry.reason == nil)
        entry.update(reps: "", left: "8", right: "6", target: 8, repCounting: .perSide)
        #expect(entry.requiresReason(target: 8, repCounting: .perSide) && entry.reason == nil)
        #expect(SetEntryDraft().observation(target: 8, repCounting: .total, exact: true) == nil)
        #expect(SetEntryDraft(reps: "-1").observation(target: 8, repCounting: .total, exact: true) == nil)
        #expect(SetEntryDraft(left: "0").observation(target: 8, repCounting: .perSide, exact: true)?.rightReps == nil)
    }
    private func confirmLoad(_ model: WorkoutViewModel, row: ExercisePrescription) async throws {
        if model.movement(for: row).loadingMode == .externalLoad {
            try await model.confirmLoad(movementID: row.movementID, load: #require(model.movement(for: row).availableLoads.first))
        }
    }
    private func actual(_ model: WorkoutViewModel, row: ExercisePrescription, index: Int, reps: Int = 8) -> ActualSet {
        let sides = model.movement(for: row).repCounting == .perSide
        return ActualSet(reps: reps, leftReps: sides ? reps : nil, rightReps: sides ? reps : nil)
    }
    private func skipBefore(_ model: WorkoutViewModel, movementID: String) async throws {
        for row in model.snapshot.draft!.displayed.exercises.prefix(while: { $0.movementID != movementID }) {
            try await model.recordStatus(movementID: row.movementID, status: .skipped)
            try await model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        }
    }
    @Test func introductionRequiresConfirmedLoadAndPreservesBodyweightNullLoad() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let model = f.model, row = model.snapshot.draft!.displayed.exercises[0]
        #expect(model.movement(for: row).loadingMode == .externalLoad)
        let original = model.snapshot
        do { try await model.beginMovement(movementID: row.movementID); Issue.record("Intro admitted missing actual load") }
        catch let error as EngineError { #expect(error.code == "load_confirmation_required") }
        #expect(model.snapshot == original && model.visibleStep == original.draft?.flow?.forward)
        #expect(try await f.repository.snapshot(programID: model.programID) == original)
        try await confirmLoad(model, row: row)
        try await model.beginMovement(movementID: row.movementID)
        #expect(model.visibleStep == .set(movementID: row.movementID, index: 0))
        await f.repository.close()

        let body = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let clock = ISO8601DateFormatter().date(from: "2026-10-11T20:00:00Z")!
        let bodyModel = WorkoutViewModel(repository: body.repository, snapshot: body.initial, timeZoneID: "Pacific/Honolulu", now: { clock })
        try await bodyModel.start(easierToday: false)
        let externalID = try #require(bodyModel.snapshot.state.config.activeVariantIDs?["db_floor_glute_bridge"])
        try await bodyModel.selectBridgeLoadingMode(variantID: externalID, mode: .bodyweight)
        let bodyRow = try #require(bodyModel.snapshot.draft!.displayed.exercises.first { bodyModel.movement(for: $0).loadingMode == .bodyweight && !$0.sets.isEmpty })
        try await skipBefore(bodyModel, movementID: bodyRow.movementID)
        #expect(bodyModel.log(for: bodyRow.movementID)?.actualLoad == nil)
        try await bodyModel.beginMovement(movementID: bodyRow.movementID)
        #expect(bodyModel.visibleStep == .set(movementID: bodyRow.movementID, index: 0))
        #expect(bodyModel.log(for: bodyRow.movementID)?.actualLoad == nil)
        await body.repository.close()
    }
    @Test func introductionRejectsReviewedHandlingMismatchWithoutChangingDraft() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .strength)
        let clock = ISO8601DateFormatter().date(from: "2026-10-11T20:00:00Z")!
        let model = WorkoutViewModel(repository: s.repository, snapshot: s.initial, timeZoneID: "Pacific/Honolulu", now: { clock })
        try await model.start(easierToday: false)
        let id = try #require(model.snapshot.state.config.activeVariantIDs?["incline_db_press_30"])
        let reviewed = Load(amount: "15", unit: .lb, basis: .perImplement)
        try await model.reviewStrengthHandling(variantID: id, choice: .lowRep(load: reviewed))
        try await skipBefore(model, movementID: id)
        var mismatched = try #require(model.snapshot.draft)
        let i = try #require(mismatched.logs.firstIndex { $0.movementID == id })
        // A supported legacy/imported draft can carry a catalog load that differs
        // from its admitted low-rep handling choice. Intro must recheck it.
        mismatched.logs[i].actualLoad = Load(amount: "20", unit: .lb, basis: .perImplement)
        let original = try await s.repository.saveDraft(mismatched)
        let resumed = WorkoutViewModel(repository: s.repository, snapshot: original, timeZoneID: model.timeZoneID, now: { clock })
        do { try await resumed.beginMovement(movementID: id); Issue.record("Intro bypassed reviewed handling") }
        catch let error as EngineError { #expect(error.code == "handling_load_mismatch") }
        #expect(resumed.snapshot == original && resumed.visibleStep == original.draft?.flow?.forward)
        #expect(try await s.repository.snapshot(programID: resumed.programID) == original)
        try await resumed.confirmLoad(movementID: id, load: reviewed)
        try await resumed.beginMovement(movementID: id)
        #expect(resumed.visibleStep == .set(movementID: id, index: 0))
        await s.repository.close()
    }
    @Test func emptySetupReviewIntroductionAndExplicitSkipNeedNoActualLoad() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .strength)
        let clock = ISO8601DateFormatter().date(from: "2026-10-11T20:00:00Z")!
        let model = WorkoutViewModel(repository: s.repository, snapshot: s.initial, timeZoneID: "Pacific/Honolulu", now: { clock })
        try await model.start(easierToday: false)
        let row = try #require(model.snapshot.draft!.displayed.exercises.first { $0.kind == .setupReview && $0.sets.isEmpty })
        try await skipBefore(model, movementID: row.movementID)
        #expect(model.log(for: row.movementID)?.actualLoad == nil)
        try await model.beginMovement(movementID: row.movementID)
        #expect(model.visibleStep == .summary(movementID: row.movementID))
        try await model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        #expect(model.log(for: row.movementID)?.actualLoad == nil && model.log(for: row.movementID)?.actualSets.isEmpty == true)
        await s.repository.close()
    }
    @Test(arguments: [false, true], [false, true]) func unacknowledgedDeclaredStoppedSummaryCannotRelabel(emptyAcknowledgements: Bool, performed: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        var draft = try await s.draft(empty: true)
        for i in draft.logs.indices { draft.logs[i].status = .partial }
        draft.acknowledgedMovementIDs = emptyAcknowledgements ? [] : nil
        draft.logs[0].status = .stopped
        if performed { draft.logs[0].actualSets = s.firstEvent.exercises[0].actualSets }
        draft.workingSetsStarted = performed
        let original = try await s.repository.saveDraft(draft)
        let clock = ISO8601DateFormatter().date(from: "2026-10-04T20:00:00Z")!
        let model = WorkoutViewModel(repository: s.repository, snapshot: original, timeZoneID: "Pacific/Honolulu", now: { clock })
        try await model.resumeGuidedWorkout()
        #expect(model.snapshot == original && model.log(for: draft.logs[0].movementID)?.problem == Problem.none)
        let id = draft.logs[0].movementID
        for status in [performed ? LogStatus.completed : .skipped, .partial] {
            do { try await model.confirmMovementSummary(movementID: id, effort: .onTarget, status: status, reviewing: false); Issue.record("Declared stopped work relabelled") }
            catch let error as EngineError { #expect(error.code == "movement_stopped") }
            #expect(model.snapshot == original)
            #expect(try await s.repository.snapshot(programID: model.programID) == original)
        }
        try await model.confirmMovementSummary(movementID: id, effort: .onTarget, status: .stopped, reviewing: false)
        #expect(model.log(for: id)?.status == .stopped && model.log(for: id)?.actualSets == draft.logs[0].actualSets)
        #expect(model.log(for: id)?.problem == Problem.none && model.log(for: id)?.effortScope == draft.logs[0].effortScope)
        #expect(model.snapshot.draft?.acknowledgedMovementIDs?.contains(id) == true)
        #expect(model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.contains(id) == true)
        await s.repository.close()
    }
    @Test func setRestSummaryAndBackAreExactlyOnce() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let model = f.model, row = try #require(model.snapshot.draft?.displayed.exercises.first)
        #expect(model.visibleStep == .introduction(movementID: row.movementID))
        try await confirmLoad(model, row: row)
        try await model.beginMovement(movementID: row.movementID)
        let observed = actual(model, row: row, index: 0)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: observed)
        let saved = try #require(model.snapshot.draft)
        #expect(saved.logs[0].actualSets.count == 1)
        #expect(saved.flow?.forward == .rest(sourceMovementID: row.movementID, sourceSetIndex: 0, destination: .set(movementID: row.movementID, index: 1)))
        model.reviewStep = .set(movementID: row.movementID, index: 0)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: observed)
        #expect(model.snapshot.draft == saved)
        model.reviewStep = nil
        try await model.advanceRest()
        for index in row.sets.indices.dropFirst() { try await model.skipSet(movementID: row.movementID, index: index) }
        #expect(model.snapshot.draft?.flow?.forward == .summary(movementID: row.movementID))
        #expect(model.snapshot.draft?.restDeadline == saved.restDeadline)
        try await model.confirmMovementSummary(movementID: row.movementID, effort: .unknown, status: .partial, reviewing: false)
        #expect(model.snapshot.draft?.restDeadline == saved.restDeadline)
        #expect(model.snapshot.draft?.flow?.reviewedSummaryMovementIDs == [row.movementID])
        await f.repository.close()
    }
    @Test func anyBelowGoalSideRequiresReasonAndNeverCompletes() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let row = try #require(f.model.snapshot.draft?.displayed.exercises.first { f.model.movement(for: $0).repCounting == .perSide })
        try await confirmLoad(f.model, row: row)
        do { try await f.model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 8, leftReps: 8, rightReps: 6)); Issue.record("Side shortfall accepted without reason") } catch {}
        #expect(f.model.log(for: row.movementID)?.actualSets.isEmpty == true)
        try await f.model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 8, leftReps: 8, rightReps: 6, missedGoalReason: .effortLimit))
        do { try await f.model.recordStatus(movementID: row.movementID, status: .completed); Issue.record("Unequal set completed") } catch {}
        await f.repository.close()
    }
    @Test func allSkippedHasNoTimerOrRequiredEffort() async throws {
        let f = try await GuidedWorkoutFixture.make()
        for row in f.model.snapshot.draft!.displayed.exercises {
            try await confirmLoad(f.model, row: row)
            try await f.model.beginMovement(movementID: row.movementID)
            for index in row.sets.indices { try await f.model.skipSet(movementID: row.movementID, index: index) }
            #expect(f.model.visibleStep == .summary(movementID: row.movementID))
            try await f.model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        }
        #expect(f.model.visibleStep == .workoutReview)
        #expect(f.model.snapshot.draft?.restDeadline == nil)
        _ = try await f.model.finish()
        #expect(f.model.finished)
        await f.repository.close()
    }
    @Test func correctionFromReviewOpensSummaryWithoutRewind() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let model = f.model, row = model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(model, row: row)
        try await model.beginMovement(movementID: row.movementID)
        for index in row.sets.indices {
            try await model.recordSet(movementID: row.movementID, index: index, actual: actual(model, row: row, index: index))
            if index != row.sets.indices.last { try await model.advanceRest() }
        }
        try await model.confirmMovementSummary(movementID: row.movementID, effort: .onTarget, status: .completed, reviewing: false)
        for other in model.snapshot.draft!.displayed.exercises.dropFirst() {
            try await model.recordStatus(movementID: other.movementID, status: .skipped)
            try await model.confirmMovementSummary(movementID: other.movementID, effort: nil, status: .skipped, reviewing: false)
        }
        let deadline = model.snapshot.draft?.restDeadline
        let id = UUID(), replacement = actual(model, row: row, index: 0, reps: 9)
        try await model.correctSet(movementID: row.movementID, index: 0, replacement: replacement, operationID: id)
        #expect(model.snapshot.draft?.flow?.forward == .workoutReview)
        #expect(model.visibleStep == .summary(movementID: row.movementID))
        #expect(model.snapshot.draft?.restDeadline == deadline)
        do { _ = try await model.finish(); Issue.record("Unreviewed correction finished") } catch {}
        try await model.correctSet(movementID: row.movementID, index: 0, replacement: replacement, operationID: id)
        #expect(model.snapshot.draft?.observationAudit?.corrections.count == 1)
        try await model.confirmMovementSummary(movementID: row.movementID, effort: .onTarget, status: .completed, reviewing: true)
        #expect(model.visibleStep == .workoutReview)
        _ = try await model.finish()
        await f.repository.close()
    }
    @Test func earlyStopPreservesRawExemptionAndPermanentOutcome() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        try await f.model.recordProblem(movementID: row.movementID, problem: .pain, pendingActual: ActualSet(reps: 0))
        #expect(f.model.visibleStep == .summary(movementID: row.movementID))
        #expect(f.model.snapshot.draft?.restDeadline == nil)
        #expect(f.model.log(for: row.movementID)?.actualSets.first?.reps == 0)
        do { try await f.model.confirmMovementSummary(movementID: row.movementID, effort: .unknown, status: .partial, reviewing: false); Issue.record("Safety stop promoted") } catch {}
        try await f.model.confirmMovementSummary(movementID: row.movementID, effort: .unknown, status: .stopped, reviewing: false)
        do { try await f.model.beginMovement(movementID: row.movementID); Issue.record("Safety stop reopened") } catch {}
        await f.repository.close()
    }
    @Test func stoppedRawCorrectionPreservesNilLoadMissingSideZeroAndCursor() async throws {
        let f = try await GuidedWorkoutFixture.make(schemaVersion: 3)
        let model = f.model
        let row = try #require(model.snapshot.draft!.displayed.exercises.first { model.movement(for: $0).repCounting == .perSide })
        try await skipBefore(model, movementID: row.movementID)
        try await model.recordProblem(movementID: row.movementID, problem: .controlLost, pendingActual: ActualSet(reps: 7, leftReps: 7))
        let before = try #require(model.snapshot.draft)
        try await model.correctSet(movementID: row.movementID, index: 0, replacement: ActualSet(reps: 0, leftReps: 0), operationID: UUID())
        let log = try #require(model.log(for: row.movementID))
        #expect(log.status == .stopped && log.problem == .controlLost && log.actualLoad == nil)
        #expect(log.actualSets.first?.reps == 0 && log.actualSets.first?.leftReps == 0 && log.actualSets.first?.rightReps == nil)
        #expect(log.actualSets.first?.missedGoalReason == nil)
        #expect(model.snapshot.draft?.displayed == before.displayed && model.snapshot.draft?.flow?.forward == before.flow?.forward)
        #expect(model.snapshot.draft?.restDeadline == before.restDeadline)
        do { try await model.beginMovement(movementID: row.movementID); Issue.record("Stopped correction reopened working sets") } catch {}
        try await model.confirmMovementSummary(movementID: row.movementID, effort: .unknown, status: .stopped, reviewing: true)
        #expect(model.log(for: row.movementID)?.status == .stopped)
        await f.repository.close()
    }
    @Test func failedTransitionsKeepCursorAndCorrectionReviewVisible() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(f.model, row: row)
        let original = f.model.snapshot
        await f.repository.failNextSave()
        do { try await f.model.beginMovement(movementID: row.movementID); Issue.record("Expected failed save") } catch {}
        #expect(f.model.snapshot == original)
        #expect(f.model.visibleStep == original.draft?.flow?.forward)
        await f.repository.close()
    }
    @Test func summaryRequiresExplicitAggregateEffortAndReviewCannotAppend() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let model = f.model, row = model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(model, row: row)
        try await model.beginMovement(movementID: row.movementID)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: actual(model, row: row, index: 0))
        let saved = model.snapshot
        model.reviewStep = .set(movementID: row.movementID, index: 0)
        do { try await model.recordSet(movementID: row.movementID, index: 1, actual: actual(model, row: row, index: 1)); Issue.record("Back appended work") } catch {}
        do { try await model.advanceRest(); Issue.record("Back advanced forward") } catch {}
        #expect(model.snapshot == saved)
        model.reviewStep = nil
        try await model.recordStatus(movementID: row.movementID, status: .partial)
        let summary = model.snapshot
        do { try await model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .partial, reviewing: false); Issue.record("Missing explicit effort") }
        catch let error as EngineError { #expect(error.code == "effort_required") }
        #expect(model.snapshot == summary)
        await f.repository.failNextSave()
        do { try await model.confirmMovementSummary(movementID: row.movementID, effort: .unknown, status: .partial, reviewing: false); Issue.record("Summary save should fail") } catch {}
        #expect(model.snapshot == summary)
        await f.repository.close()
    }
    @Test func failedRestAndCorrectionRetainSnapshotAndPage() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let model = f.model, row = model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(model, row: row)
        try await model.beginMovement(movementID: row.movementID)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: actual(model, row: row, index: 0))
        let before = model.snapshot
        await f.repository.failNextSave()
        do { try await model.advanceRest(); Issue.record("Rest save should fail") } catch {}
        #expect(model.snapshot == before && model.visibleStep == before.draft?.flow?.forward)
        model.reviewStep = .set(movementID: row.movementID, index: 0)
        await f.repository.failNextSave()
        do { try await model.correctSet(movementID: row.movementID, index: 0, replacement: actual(model, row: row, index: 0, reps: 9), operationID: UUID()); Issue.record("Correction save should fail") } catch {}
        #expect(model.snapshot == before && model.reviewStep == .set(movementID: row.movementID, index: 0))
        await f.repository.close()
    }
    @Test func resumePresentsSharedRestrictedDraftWithoutNewExposure() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let original = f.model.snapshot
        let config = try selectStarterProgram(choice: .upperBody, goal: .size, programID: UUID())
        let first = try WorkoutScheduler.nextSlot(onOrAfter: original.draft!.date, config: config)
        let second = try await f.repository.initialize(config: config, rules: RulesetCatalog.starter(.upperBody), firstWorkout: first)
        let other = WorkoutViewModel(repository: f.repository, snapshot: second, timeZoneID: f.model.timeZoneID, now: f.model.now)
        try await other.start(easierToday: false)
        let row = original.draft!.displayed.exercises[0]
        let stopped = try #require(other.snapshot.draft?.displayed.exercises.first { $0.baseMovementID == row.baseMovementID })
        try await other.recordProblem(movementID: stopped.movementID, problem: .pain)
        let resumed = WorkoutViewModel(repository: f.repository, snapshot: original, timeZoneID: f.model.timeZoneID, now: f.model.now)
        try await resumed.resumeGuidedWorkout()
        #expect(resumed.snapshot == original)
        do { try await resumed.beginMovement(movementID: row.movementID); Issue.record("Shared pause bypass") }
        catch let error as EngineError { #expect(error.code == "retained_safety_restriction") }
        #expect(resumed.snapshot == original)
        try await resumed.recordStatus(movementID: row.movementID, status: .skipped)
        try await resumed.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        await f.repository.close()
    }
    @Test func newWritesKeepMainActorHeartbeatAlive() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let model = f.model, row = model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(model, row: row)
        let probe = GuidedCommitProbe()
        await f.repository.observeCommits { probe.observe($0) }
        let begin = Task { @MainActor in await model.run { try await model.beginMovement(movementID: row.movementID) } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.busy && model.visibleStep == .introduction(movementID: row.movementID))
        await begin.value
        #expect(model.errorText == nil)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: actual(model, row: row, index: 0))
        let before = model.snapshot
        let correction = Task { @MainActor in await model.run {
            try await model.correctSet(movementID: row.movementID, index: 0, replacement: actual(model, row: row, index: 0, reps: 9), operationID: UUID())
        } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.busy && model.snapshot == before)
        await correction.value
        #expect(model.errorText == nil)
        model.reviewStep = nil
        for other in model.snapshot.draft!.displayed.exercises {
            try await model.recordStatus(movementID: other.movementID, status: other.movementID == row.movementID ? .partial : .skipped)
        }
        try await model.confirmHandledSummariesForTesting()
        let finish = Task { @MainActor in await model.run { _ = try await model.finish() } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.busy && !model.finished)
        await finish.value
        #expect(model.errorText == nil && model.finished)
        #expect(!probe.savedOnMain && probe.saveCount >= 5)
        await f.repository.observeCommits(nil)
        await f.repository.close()
    }
    @Test func dateChoiceResumeRetainsDraftAndSafetyStopStillSavesRaw() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let before = f.model.snapshot
        let resumed = WorkoutViewModel(repository: f.repository, snapshot: before, timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 2_000_000_000) })
        try await resumed.resumeGuidedWorkout()
        #expect(resumed.snapshot == before && resumed.needsDateChoice)
        let row = before.draft!.displayed.exercises[0]
        do { try await resumed.beginMovement(movementID: row.movementID); Issue.record("Date choice bypass") }
        catch let error as EngineError { #expect(error.code == "date_choice_required") }
        try await resumed.recordProblem(movementID: row.movementID, problem: .controlLost, pendingActual: ActualSet(reps: 0))
        #expect(resumed.snapshot.draft?.date == before.draft?.date)
        #expect(resumed.visibleStep == .summary(movementID: row.movementID))
        await f.repository.close()
    }
    @Test func parkedLegacyResumeAllowsOnlyExplicitReconciledActions() async throws {
        for stopped in [false, true] {
            let scenario = try await RepositoryTestHarness.make(goal: .size)
            var draft = try await scenario.draft(empty: true)
            // The repository helper deliberately retains completed outcomes;
            // this continuation fixture represents genuinely unfinished work.
            for i in draft.logs.indices { draft.logs[i].status = .partial }
            if stopped { draft.logs[0].problem = .pain; draft.logs[0].status = .stopped; draft.workingSetsStarted = true }
            _ = try await scenario.repository.saveDraft(draft)
            let snapshot = try await scenario.repository.snapshot(programID: scenario.programID)
            let model = WorkoutViewModel(repository: scenario.repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu",
                now: { ISO8601DateFormatter().date(from: "2026-10-05T20:00:00Z")! })
            try await model.resumeGuidedWorkout()
            #expect(model.snapshot == snapshot && model.snapshot.draft?.flow == nil)
            #expect(model.needsDateChoice)
            try await model.resolveDateChange(keepOriginal: true)
            if stopped {
                try await model.confirmMovementSummary(movementID: draft.logs[0].movementID, effort: nil, status: .stopped, reviewing: false)
                #expect(model.log(for: draft.logs[0].movementID)?.problem == .pain)
                #expect(model.log(for: draft.logs[0].movementID)?.effortScope == nil)
            } else {
                try await model.beginMovement(movementID: draft.logs[0].movementID)
                try await model.recordProblem(movementID: draft.logs[0].movementID, problem: .pain, pendingActual: ActualSet(reps: 0))
                #expect(model.visibleStep == .summary(movementID: draft.logs[0].movementID))
            }
            #expect(model.snapshot.draft?.flow != nil && model.snapshot.draft?.date == draft.date)
            await scenario.repository.close()
        }
    }
    @Test func staleModelCannotReplaceSavedRestWithDuplicateObservation() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(f.model, row: row)
        try await f.model.beginMovement(movementID: row.movementID)
        let stale = WorkoutViewModel(repository: f.repository, snapshot: f.model.snapshot, timeZoneID: f.model.timeZoneID,
            now: { f.model.now().addingTimeInterval(300) })
        let observed = actual(f.model, row: row, index: 0)
        try await f.model.recordSet(movementID: row.movementID, index: 0, actual: observed)
        let saved = f.model.snapshot
        do { try await stale.recordSet(movementID: row.movementID, index: 0, actual: observed); Issue.record("Stale observation replaced cursor/deadline") } catch {}
        #expect(try await f.repository.snapshot(programID: f.model.programID) == saved)
        await f.repository.close()
    }
    @Test(arguments: [false, true]) func parkedLegacySetEntryReconcilesOnlyOnAuthorizedAction(skipping: Bool) async throws {
        let f = try await GuidedWorkoutFixture.make()
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(f.model, row: row)
        var legacy = try #require(f.model.snapshot.draft)
        legacy.flow = nil
        var observed = actual(f.model, row: row, index: 0); observed.setIndex = 0
        legacy.logs[0].actualSets = [observed]; legacy.workingSetsStarted = true
        legacy.restDeadline = f.model.now().addingTimeInterval(TimeInterval(row.restSeconds))
        let saved = try await f.repository.saveDraft(legacy)
        let model = WorkoutViewModel(repository: f.repository, snapshot: saved, timeZoneID: f.model.timeZoneID,
            now: { f.model.now().addingTimeInterval(86_400) })
        try await model.resumeGuidedWorkout()
        #expect(model.snapshot == saved && model.snapshot.draft?.flow == nil && model.needsDateChoice)
        #expect(model.visibleStep == .set(movementID: row.movementID, index: 1))
        do { try await model.recordSet(movementID: row.movementID, index: 1, actual: actual(model, row: row, index: 1)); Issue.record("Date choice bypass") }
        catch let error as EngineError { #expect(error.code == "date_choice_required") }
        #expect(model.snapshot == saved)
        try await model.resolveDateChange(keepOriginal: true)
        if skipping {
            try await model.skipSet(movementID: row.movementID, index: 1)
            #expect(model.visibleStep == .set(movementID: row.movementID, index: 2))
            #expect(model.snapshot.draft?.restDeadline == legacy.restDeadline)
            #expect(model.log(for: row.movementID)?.actualSets == [observed])
            #expect(model.log(for: row.movementID)?.skippedSetIndices == [1])
        } else {
            try await model.recordSet(movementID: row.movementID, index: 1, actual: actual(model, row: row, index: 1))
            #expect(model.visibleStep == .rest(sourceMovementID: row.movementID, sourceSetIndex: 1, destination: .set(movementID: row.movementID, index: 2)))
            #expect(model.log(for: row.movementID)?.actualSets.count == 2)
            #expect(model.snapshot.draft?.restDeadline != legacy.restDeadline)
        }
        #expect(model.snapshot.draft?.flow != nil && model.snapshot.draft?.date == legacy.date)
        #expect(model.snapshot.draft?.acknowledgedMovementIDs == legacy.acknowledgedMovementIDs)
        #expect(model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.isEmpty == true)
        #expect(try await f.repository.snapshot(programID: model.programID) == model.snapshot)
        await f.repository.close()
    }
    @Test func summaryAndOutcomeRetriesDoNotRewindForwardOrRestartRest() async throws {
        let f = try await GuidedWorkoutFixture.make()
        let row = f.model.snapshot.draft!.displayed.exercises[0]
        try await f.model.recordStatus(movementID: row.movementID, status: .skipped)
        try await f.model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        let saved = f.model.snapshot
        try await f.model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        try await f.model.recordStatus(movementID: row.movementID, status: .skipped)
        #expect(f.model.snapshot == saved)
        await f.repository.close()
    }
    @Test(arguments: [false, true]) func unacknowledgedCorrectionReviewPreservesForwardWork(atSet: Bool) async throws {
        let f = try await GuidedWorkoutFixture.make()
        let model = f.model, row = model.snapshot.draft!.displayed.exercises[0]
        try await confirmLoad(model, row: row)
        try await model.beginMovement(movementID: row.movementID)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: actual(model, row: row, index: 0))
        if atSet { try await model.advanceRest() }
        let working = try #require(model.snapshot.draft)
        try await model.correctSet(movementID: row.movementID, index: 0, replacement: actual(model, row: row, index: 0, reps: 9), operationID: UUID())
        let corrected = try #require(model.snapshot.draft)
        #expect(corrected.flow == working.flow && corrected.restDeadline == working.restDeadline)
        #expect(model.visibleStep == .summary(movementID: row.movementID))
        do { try await model.confirmMovementSummary(movementID: row.movementID, effort: .unknown, status: .stopped, reviewing: true); Issue.record("Backward review ended unfinished work") } catch {}
        #expect(model.snapshot.draft == corrected)
        do { try await model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .partial, reviewing: true); Issue.record("Missing aggregate effort accepted") } catch {}
        #expect(model.snapshot.draft == corrected)
        try await model.confirmMovementSummary(movementID: row.movementID, effort: .tooEasy, status: .partial, reviewing: true)
        var expected = corrected; expected.logs[0].finalEffort = .tooEasy
        #expect(model.snapshot.draft == expected)
        #expect(model.snapshot.draft?.acknowledgedMovementIDs == working.acknowledgedMovementIDs)
        #expect(model.snapshot.draft?.flow?.reviewedSummaryMovementIDs == working.flow?.reviewedSummaryMovementIDs)
        #expect(model.reviewStep == nil && model.visibleStep == working.flow?.forward)
        #expect(model.log(for: row.movementID)?.actualSets.count == 1)
        if !atSet { try await model.advanceRest() }
        for index in row.sets.indices.dropFirst() {
            try await model.recordSet(movementID: row.movementID, index: index, actual: actual(model, row: row, index: index))
            if index != row.sets.indices.last { try await model.advanceRest() }
        }
        let finalDeadline = model.snapshot.draft?.restDeadline
        #expect(model.visibleStep == .summary(movementID: row.movementID))
        try await model.confirmMovementSummary(movementID: row.movementID, effort: .onTarget, status: .completed, reviewing: false)
        #expect(model.snapshot.draft?.acknowledgedMovementIDs?.contains(row.movementID) == true)
        #expect(model.snapshot.draft?.flow?.reviewedSummaryMovementIDs.contains(row.movementID) == true)
        #expect(model.snapshot.draft?.restDeadline == finalDeadline)
        #expect(model.log(for: row.movementID)?.actualSets.count == row.sets.count)
        await f.repository.close()
    }
    @Test func resumeDoesNotStartOrMutateFrozenPausedDraft() async throws {
        let f = try await GuidedWorkoutFixture.make()
        for row in f.model.snapshot.draft!.displayed.exercises {
            try await f.model.recordStatus(movementID: row.movementID, status: .skipped)
            try await f.model.confirmMovementSummary(movementID: row.movementID, effort: nil, status: .skipped, reviewing: false)
        }
        let draft = try #require(f.model.snapshot.draft)
        var event = CompletedWorkout(eventID: draft.id.uuidString.lowercased(), date: draft.date, slotID: draft.displayed.slotID, prescriptionID: draft.displayed.id, plannedPrescriptionID: draft.planned.id, sessionMode: draft.sessionMode, exercises: draft.logs)
        event.timing = SessionTiming(plannedDate: draft.planned.date, startedAtMilliseconds: draft.startedAtMilliseconds!, finishedAtMilliseconds: draft.startedAtMilliseconds!, timeZoneID: draft.timeZoneID)
        let next = try WorkoutScheduler.nextRotation(after: max(draft.date, draft.planned.date), consumedSlotID: draft.planned.slotID, config: f.model.snapshot.state.config)
        let frozen = try await f.repository.freezeDraftFinish(programID: f.model.programID, expectedDraftHash: BackupService.hash(draft), submission: PendingWorkoutFinish(event: event, next: next, expectedRevision: draft.expectedRevision))
        let resumed = WorkoutViewModel(repository: f.repository, snapshot: frozen, timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 2_000_000_000) })
        try await resumed.resumeGuidedWorkout()
        #expect(resumed.snapshot == frozen)
        #expect(resumed.hasAmbiguousFinish && !resumed.needsDateChoice)
        await f.repository.close()
    }
}

/// Existing owning suites now perform the explicit user Summary confirmations.
/// This helper never manufactures outcomes or reviews a malformed legacy draft.
@MainActor extension WorkoutViewModel {
    func confirmHandledSummariesForTesting() async throws {
        guard !busy, !hasAmbiguousFinish, let draft = snapshot.draft, let flow = draft.flow,
              Set(draft.acknowledgedMovementIDs ?? []) == Set(draft.logs.map(\.movementID)) else { return }
        let pending = draft.logs.filter { !flow.reviewedSummaryMovementIDs.contains($0.movementID) }
        for log in pending {
            let forward = snapshot.draft?.flow?.forward == .summary(movementID: log.movementID)
            if !forward { reviewStep = .summary(movementID: log.movementID) }
            try await confirmMovementSummary(movementID: log.movementID, effort: log.actualSets.isEmpty ? nil : log.finalEffort,
                status: log.status, reviewing: !forward)
        }
    }
}

private final class GuidedCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var main = false
    var savedOnMain: Bool { lock.withLock { main } }
    var saveCount: Int { lock.withLock { count } }
    func observe(_ stage: String) {
        guard stage == "before_save" else { return }
        lock.withLock { count += 1; main = main || Thread.isMainThread }
        // Reuses the existing 150ms synthetic save delay, with no new latency SLA.
        Thread.sleep(forTimeInterval: 0.15)
    }
}

@MainActor extension GuidedWorkoutModelTests {
    @Test func pendingCorrectionSummaryFinishGuidanceIsActionable() async throws {
        let f = try await GuidedWorkoutFixture.make()
        var draft = try #require(f.model.snapshot.draft)
        for i in draft.logs.indices { draft.logs[i].status = .skipped }
        let id = draft.logs[0].movementID
        draft.logs[0].status = .partial
        draft.logs[0].actualSets = [ActualSet(reps: 7, setIndex: 0, missedGoalReason: .effortLimit)]
        draft.logs[0].actualLoad = f.model.movement(for: draft.displayed.exercises[0]).availableLoads.first
        draft.logs[0].finalEffort = .unknown
        draft.workingSetsStarted = true
        draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
        draft.flow = WorkoutFlow(forward: .workoutReview, reviewedSummaryMovementIDs: draft.logs.map(\.movementID))
        let saved = try await f.repository.saveDraft(draft)
        let model = WorkoutViewModel(repository: f.repository, snapshot: saved, timeZoneID: f.model.timeZoneID, now: f.model.now)
        try await model.correctSet(movementID: id, index: 0, replacement: ActualSet(reps: 8, setIndex: 0), operationID: UUID())
        let before = model.snapshot
        await model.run { _ = try await model.finish() }
        #expect(model.errorText == "Confirm the pending movement summaries in Workout review before finishing.")
        #expect(model.snapshot == before && model.snapshot.draft?.logs[0].status == .partial)
        #expect(model.snapshot.draft?.pendingFinish == nil)
        await f.repository.close()
    }
}

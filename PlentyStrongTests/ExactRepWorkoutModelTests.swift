import XCTest
import TrainingCore
@testable import PlentyStrong

@MainActor final class ExactRepWorkoutModelTests: XCTestCase {
    private func makeExact(goal: Goal = .size, date: String = "2026-10-08") async throws -> (WorkoutViewModel, TrainingRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("training.store")
        let repository = try TrainingRepository.open(at: url)
        let config = try selectFixedProgram(goal: goal, programID: UUID())
        let first = try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: date), config: config)
        let snapshot = try await repository.initialize(config: config, rules: RulesetCatalog.exactV1(), firstWorkout: first)
        let model = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "\(date)T20:00:00Z")! })
        return (model, repository, url)
    }
    private func confirm(_ row: ExercisePrescription, model: WorkoutViewModel) async throws {
        if model.movement(for: row).loadingMode == .externalLoad {
            try await model.confirmLoad(movementID: row.movementID, load: XCTUnwrap(model.movement(for: row).availableLoads.first))
        }
    }
    func testActualsRemainEmptyUntilRecorded() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let draft = try XCTUnwrap(model.snapshot.draft)
        XCTAssertEqual(draft.displayed.exercises.first?.sets.compactMap(\.targetReps), [8,8,8])
        XCTAssertTrue(draft.logs.allSatisfy { $0.actualSets.isEmpty && $0.actualLoad == nil })
        XCTAssertTrue(draft.logs.allSatisfy { $0.effortScope == .allWorkingSets })
        await repository.close()
    }
    func testOrdinaryShortfallRequiresExplicitReason() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = try XCTUnwrap(model.snapshot.draft?.displayed.exercises.first)
        try await confirm(row, model: model)
        do {
            try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 7))
            XCTFail("Ordinary exact shortfall must require a reason")
        } catch let error as EngineError { XCTAssertEqual(error.code, "missed_goal_reason_required") }
        XCTAssertTrue(model.log(for: row.movementID)!.actualSets.isEmpty)
        await repository.close()
    }
    private func finishRemaining(_ model: WorkoutViewModel, firstStatus: LogStatus) async throws -> FinalizationReceipt {
        let rows = model.snapshot.draft!.displayed.exercises
        try await model.recordStatus(movementID: rows[0].movementID, status: firstStatus)
        for row in rows.dropFirst() { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        return try await model.finish()
    }
    func testSkippedMiddleSetSurvivesReopen() async throws {
        let (model, repository, url) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await confirm(row, model: model)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 10))
        try await model.skipSet(movementID: row.movementID, index: 1)
        XCTAssertFalse(model.handled(row.movementID))
        XCTAssertEqual(model.nextSetIndex(for: row.movementID), 2)
        XCTAssertFalse(model.canChangePreparation)
        do { try await model.start(easierToday: true); XCTFail("Skip retains working lock") } catch {}
        try await model.recordSet(movementID: row.movementID, index: 2, actual: ActualSet(reps: 9))
        let saved = model.snapshot.draft!
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let snapshot = try await reopened.snapshot(programID: model.programID)
        let resumed = WorkoutViewModel(repository: reopened, snapshot: snapshot, timeZoneID: model.timeZoneID, now: model.now)
        XCTAssertEqual(snapshot.draft, saved)
        XCTAssertEqual(resumed.log(for: row.movementID)?.actualSets.map(\.setIndex), [0,2])
        XCTAssertEqual(resumed.log(for: row.movementID)?.actualSets.map(\.reps), [10,9])
        XCTAssertEqual(resumed.log(for: row.movementID)?.skippedSetIndices, [1])
        XCTAssertNil(resumed.nextSetIndex(for: row.movementID))
        do { try await resumed.recordStatus(movementID: row.movementID, status: .completed); XCTFail("Skipped slot must remain partial") } catch {}
        let receipt = try await finishRemaining(resumed, firstStatus: .partial)
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises[0].actualSets, saved.logs[0].actualSets)
        XCTAssertEqual(event.exercises[0].skippedSetIndices, [1])
        XCTAssertEqual(event.exercises[0].status, .partial)
        await reopened.close()
    }
    func testSkipOnlyLocksPreparationAndImmutableMetadata() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let id = model.snapshot.draft!.logs[0].movementID
        try await model.skipSet(movementID: id, index: 0)
        try await model.skipSet(movementID: id, index: 0)
        XCTAssertEqual(model.log(for: id)?.skippedSetIndices, [0])
        XCTAssertTrue(model.snapshot.draft!.hasObservations)
        XCTAssertFalse(model.canChangePreparation)
        var changed = model.snapshot.draft!
        changed.logs[0].skippedSetIndices = []
        do { try await repository.saveDraft(changed); XCTFail("Cannot remove skip") } catch {}
        changed = model.snapshot.draft!; changed.logs[0].actualSets = [ActualSet(reps: 8, setIndex: 0)]
        do { try await repository.saveDraft(changed); XCTFail("Cannot perform skipped slot") } catch {}
        await repository.close()
    }
    func testPainWithPendingShortfallNeedsNoReason() async throws {
        let (model, repository, url) = try await makeExact(date: "2026-10-06")
        try await model.start(easierToday: false)
        let row = try XCTUnwrap(model.snapshot.draft!.displayed.exercises.first { model.movement(for: $0).repCounting == .perSide })
        try await model.skipSet(movementID: row.movementID, index: 0)
        let raw = ActualSet(reps: 0, leftReps: 3)
        try await model.recordProblem(movementID: row.movementID, problem: .pain, pendingActual: raw)
        let log = model.log(for: row.movementID)!
        XCTAssertEqual(log.actualSets, [ActualSet(reps: 0, leftReps: 3, setIndex: 1)])
        XCTAssertNil(log.actualLoad); XCTAssertEqual(log.status, .stopped)
        for other in model.snapshot.draft!.displayed.exercises where other.movementID != row.movementID { try await model.recordStatus(movementID: other.movementID, status: .skipped) }
        let receipt = try await model.finish()
        XCTAssertEqual(receipt.snapshot.state.baseSafety?[row.baseMovementID!]?.paused, true)
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let snapshot = try await reopened.snapshot(programID: model.programID)
        guard case let .workout(event, _) = snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises.first { $0.movementID == row.movementID }, log)
        await reopened.close()
    }
    func testMixedLoadsPreservePartialWithoutAveraging() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        XCTAssertNil(model.log(for: row.movementID)?.actualLoad)
        try await model.recordMixedLoads(movementID: row.movementID)
        try await model.recordMixedLoads(movementID: row.movementID)
        XCTAssertNil(model.log(for: row.movementID)?.actualLoad)
        XCTAssertTrue(model.snapshot.draft!.hasObservations)
        XCTAssertFalse(model.canChangePreparation)
        XCTAssertEqual(model.log(for: row.movementID)?.mixedLoads, true)
        XCTAssertEqual(model.log(for: row.movementID)?.status, .partial)
        XCTAssertTrue(model.handled(row.movementID))
        var changed = model.snapshot.draft!; changed.logs[0].mixedLoads = false
        do { try await repository.saveDraft(changed); XCTFail("Cannot erase mixed load") } catch {}
        let receipt = try await finishRemaining(model, firstStatus: .partial)
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises[0].mixedLoads, true)
        XCTAssertNil(event.exercises[0].actualLoad)
        XCTAssertTrue(event.exercises[0].actualSets.isEmpty)
        await repository.close()
    }
    func testExplicitZeroAndUnknownReasonRemainPartial() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await confirm(row, model: model)
        for i in 0..<3 { try await model.recordSet(movementID: row.movementID, index: i, actual: ActualSet(reps: i == 0 ? 0 : 8, missedGoalReason: i == 0 ? .otherUnknown : nil)) }
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets.map(\.reps), [0,8,8])
        do { try await model.recordStatus(movementID: row.movementID, status: .completed); XCTFail("Zero performed reps cannot qualify") } catch {}
        let receipt = try await finishRemaining(model, firstStatus: .partial)
        XCTAssertEqual(receipt.snapshot.state.exercises[row.movementID]?.exactRepState?.shortfallStreak, 0)
        await repository.close()
    }
    func testRawInputRejectsNegativeAndConflictingOrExtremeIndices() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await confirm(row, model: model)
        for (index, actual) in [(-1, ActualSet(reps: 8)), (Int.max, ActualSet(reps: 8)), (3, ActualSet(reps: 8)), (0, ActualSet(reps: -1)), (0, ActualSet(reps: 8, setIndex: 1)), (0, ActualSet(reps: 8, leftReps: -1))] {
            do { try await model.recordSet(movementID: row.movementID, index: index, actual: actual); XCTFail("Malformed input must be rejected") } catch {}
        }
        XCTAssertTrue(model.log(for: row.movementID)!.actualSets.isEmpty)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 11))
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 11))
        do { try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 12)); XCTFail("Cannot rewrite indexed actual") } catch {}
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets, [ActualSet(reps: 11, setIndex: 0)])
        for index in [-1, 3, Int.max] { do { try await model.skipSet(movementID: row.movementID, index: index); XCTFail("Invalid skip") } catch {} }
        await repository.close()
    }
    func testUnequalSidesCannotCompleteAndRemainRaw() async throws {
        let (model, repository, _) = try await makeExact(date: "2026-10-06")
        try await model.start(easierToday: false)
        let row = try XCTUnwrap(model.snapshot.draft!.displayed.exercises.first { model.movement(for: $0).repCounting == .perSide })
        try await confirm(row, model: model)
        for i in 0..<3 { try await model.recordSet(movementID: row.movementID, index: i, actual: ActualSet(reps: 8, leftReps: 8, rightReps: 7)) }
        do { try await model.recordStatus(movementID: row.movementID, status: .completed); XCTFail("Unequal sides") } catch {}
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets.last?.rightReps, 7)
        await repository.close()
    }
    func testExplicitPartialPendingShortfallCannotPromoteOrRewrite() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await model.recordStatus(movementID: row.movementID, status: .partial, pendingActual: ActualSet(reps: 5))
        let original = model.snapshot.draft!
        XCTAssertEqual(original.logs[0].actualSets, [ActualSet(reps: 5, setIndex: 0)])
        XCTAssertNil(original.logs[0].actualLoad)
        do { try await model.recordStatus(movementID: row.movementID, status: .completed); XCTFail("Explicit stop is final") } catch {}
        do { try await model.recordSet(movementID: row.movementID, index: 1, actual: ActualSet(reps: 8)); XCTFail("No working append after stop") } catch {}
        var changed = original; changed.logs[0].status = .completed
        do { try await repository.saveDraft(changed); XCTFail("Repository prevents promotion") } catch {}
        changed = original; changed.logs[0].actualSets.append(ActualSet(reps: 8, setIndex: 1))
        do { try await repository.saveDraft(changed); XCTFail("Repository prevents handled append") } catch {}
        changed = original; changed.acknowledgedMovementIDs = []
        do { try await repository.saveDraft(changed); XCTFail("Cannot unhandle retained observations") } catch {}
        await repository.close()
    }
    func testMissReasonChangesOnlyFuturePolicy() async throws {
        for reason in [MissedGoalReason.effortLimit, .timeInterruption, .otherUnknown] {
            let (warmup, repository, url) = try await makeExact()
            try await warmup.start(easierToday: false)
            let first = warmup.snapshot.draft!.displayed.exercises[0]
            try await confirm(first, model: warmup)
            for i in 0..<3 { try await warmup.recordSet(movementID: first.movementID, index: i, actual: ActualSet(reps: 8)) }
            try await warmup.recordEffort(movementID: first.movementID, effort: .onTarget)
            let confirmed = try await finishRemaining(warmup, firstStatus: .completed)
            let initial = WorkoutViewModel(repository: repository, snapshot: confirmed.snapshot, timeZoneID: warmup.timeZoneID, now: { ISO8601DateFormatter().date(from: "2026-10-11T20:00:00Z")! })
            try await initial.start(easierToday: false)
            try await confirm(initial.snapshot.draft!.displayed.exercises[0], model: initial)
            for i in 0..<3 { try await initial.recordSet(movementID: first.movementID, index: i, actual: ActualSet(reps: 10)) }
            try await initial.recordEffort(movementID: first.movementID, effort: .onTarget)
            let baseline = try await finishRemaining(initial, firstStatus: .completed)
            XCTAssertEqual(baseline.snapshot.state.exercises[first.movementID]?.exactRepState?.normalTargets, [10,10,10])
            // Consume the intervening rotation before revisiting Thursday's movement.
            let tuesday = WorkoutViewModel(repository: repository, snapshot: baseline.snapshot, timeZoneID: initial.timeZoneID, now: { ISO8601DateFormatter().date(from: "2026-10-13T20:00:00Z")! })
            try await tuesday.start(easierToday: false)
            XCTAssertEqual(tuesday.snapshot.draft?.planned.slotID, "TUE")
            for row in tuesday.snapshot.draft!.displayed.exercises { try await tuesday.recordStatus(movementID: row.movementID, status: .skipped) }
            let handledTuesday = try await tuesday.finish()
            XCTAssertEqual(handledTuesday.snapshot.state.activePrescription.slotID, "THU")
            let model = WorkoutViewModel(repository: repository, snapshot: handledTuesday.snapshot, timeZoneID: initial.timeZoneID, now: { ISO8601DateFormatter().date(from: "2026-10-15T20:00:00Z")! })
            try await model.start(easierToday: false)
            try await confirm(model.snapshot.draft!.displayed.exercises[0], model: model)
            for i in 0..<3 { try await model.recordSet(movementID: first.movementID, index: i, actual: ActualSet(reps: i == 2 ? 9 : 10, missedGoalReason: i == 2 ? reason : nil)) }
            try await model.recordEffort(movementID: first.movementID, effort: .onTarget)
            let raw = model.log(for: first.movementID)!
            await repository.close()
            let reopened = try TrainingRepository.open(at: url)
            let saved = try await reopened.snapshot(programID: model.programID)
            let resumed = WorkoutViewModel(repository: reopened, snapshot: saved, timeZoneID: model.timeZoneID, now: model.now)
            XCTAssertEqual(resumed.log(for: first.movementID), raw)
            try await resumed.recordStatus(movementID: first.movementID, status: .completed)
            for row in saved.draft!.displayed.exercises.dropFirst() { try await resumed.recordStatus(movementID: row.movementID, status: .skipped) }
            await reopened.failNextSave()
            do { _ = try await resumed.finish(); XCTFail("Injected save failure") } catch {}
            XCTAssertTrue(resumed.hasAmbiguousFinish)
            do { try await resumed.recordEffort(movementID: first.movementID, effort: .tooEasy); XCTFail("Frozen finish") } catch {}
            let receipt = try await resumed.finish()
            _ = try await resumed.finish()
            guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
            var expected = raw; expected.status = .completed
            XCTAssertEqual(event.exercises[0], expected)
            XCTAssertEqual(receipt.snapshot.state.exercises[first.movementID]?.exactRepState?.shortfallStreak, reason == .effortLimit ? 1 : 0)
            XCTAssertEqual(receipt.snapshot.state.activePrescription.exercises[0].sets.compactMap(\.targetReps), [10,10,10])
            XCTAssertEqual(receipt.snapshot.history.filter { $0.eventID == event.eventID }.count, 1)
            await reopened.close()
        }
    }
    func testEffortScopeAndLegacyDraft() async throws {
        let (exact, repository, _) = try await makeExact()
        try await exact.start(easierToday: false)
        let id = exact.snapshot.draft!.logs[0].movementID
        try await exact.recordEffort(movementID: id, effort: .tooHard)
        XCTAssertEqual(exact.log(for: id)?.effortScope, .allWorkingSets)
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        let old = try await scenario.draft(empty: true)
        try await scenario.repository.saveDraft(old)
        let reopened = try await scenario.reopened()
        let snapshot = try await reopened.snapshot(programID: scenario.programID)
        let legacy = WorkoutViewModel(repository: reopened, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "2026-10-04T20:00:00Z")! }, activatesExactPolicy: true)
        try await legacy.start(easierToday: false)
        try await legacy.recordEffort(movementID: old.logs[0].movementID, effort: .onTarget)
        XCTAssertEqual(legacy.snapshot.state.schemaVersion, 2)
        XCTAssertNil(legacy.log(for: old.logs[0].movementID)?.effortScope)
        XCTAssertEqual(legacy.snapshot.draft?.displayed, old.displayed)
        XCTAssertTrue(legacy.snapshot.draft!.displayed.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps == nil } })
        for row in old.displayed.exercises { try await legacy.recordStatus(movementID: row.movementID, status: .skipped) }
        let receipt = try await legacy.finish()
        XCTAssertEqual(receipt.snapshot.state.schemaVersion, 2)
        await reopened.close(); await repository.close()
    }
    func testMalformedSetCountsAndDraftReasonAdmissionFailClosed() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let draft = model.snapshot.draft!
        let id = draft.logs[0].movementID
        for count in [0, Int.max] {
            var state = model.snapshot.state
            state.exercises[id]!.normalSets = count
            XCTAssertThrowsError(try BackupService.validateDraft(draft, state: state, rules: RulesetCatalog.exactV1()))
        }
        for status in [LogStatus.partial, .completed] {
            var malformed = draft
            malformed.logs[0].actualSets = [ActualSet(reps: 7, setIndex: 0)]
            malformed.logs[0].status = status
            XCTAssertThrowsError(try BackupService.validateDraft(malformed, state: model.snapshot.state, rules: RulesetCatalog.exactV1()))
            do { try await repository.saveDraft(malformed); XCTFail("Ordinary draft requires reason") } catch {}
        }
        for sets in [[ActualSet(reps: 8, setIndex: 0), ActualSet(reps: 8, setIndex: 0)], [ActualSet(reps: 8, setIndex: Int.max)]] {
            var malformed = draft; malformed.logs[0].actualSets = sets
            XCTAssertThrowsError(try BackupService.validateDraft(malformed, state: model.snapshot.state, rules: RulesetCatalog.exactV1()))
        }
        await repository.close()
    }
    func testConcurrentSaveFinishAndActivation() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await model.operations.perform { _ in
            do { try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 8)); XCTFail("Save lease") } catch let error as EngineError { XCTAssertEqual(error.code, "operation_in_progress") }
            do { _ = try await model.finish(); XCTFail("Finish lease") } catch let error as EngineError { XCTAssertEqual(error.code, "operation_in_progress") }
            do { try await model.start(easierToday: true); XCTFail("Activation/preparation lease") } catch let error as EngineError { XCTAssertEqual(error.code, "operation_in_progress") }
        }
        for row in model.snapshot.draft!.displayed.exercises { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        let draft = model.snapshot.draft!
        let one = Task { try await model.finish() }
        let two = Task { try await model.finish() }
        let receipt = try await one.value
        _ = try await two.value
        XCTAssertEqual(receipt.snapshot.history.filter { $0.eventID == draft.id.uuidString.lowercased() }.count, 1)
        XCTAssertEqual(receipt.snapshot.state.schemaVersion, 3)
        await repository.close()
    }
    func testRepairProofCannotPromoteFinalPartialObservation() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await confirm(row, model: model)
        for i in 0..<3 { try await model.recordSet(movementID: row.movementID, index: i, actual: ActualSet(reps: 8)) }
        try await model.recordStatus(movementID: row.movementID, status: .partial)
        let original = model.snapshot.draft!
        var promoted = original; promoted.logs[0].status = .completed
        do { try await repository.saveDraft(promoted, expectedExistingDraft: original); XCTFail("Repair proof permits only demotion, never promotion") } catch {}
        let retained = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(retained.draft, original)
        // A later explicit safety flag can still stop an already handled movement.
        try await model.recordProblem(movementID: row.movementID, problem: .controlLost)
        XCTAssertEqual(model.log(for: row.movementID)?.status, .stopped)
        await repository.close()
    }
    func testMixedLoadsRetainConfirmedLoadAndPerformedPrefix() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await confirm(row, model: model)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 11))
        let original = model.log(for: row.movementID)!
        try await model.recordMixedLoads(movementID: row.movementID)
        try await model.recordMixedLoads(movementID: row.movementID)
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets, original.actualSets)
        XCTAssertEqual(model.log(for: row.movementID)?.actualLoad, original.actualLoad)
        XCTAssertNil(model.nextSetIndex(for: row.movementID))
        let receipt = try await finishRemaining(model, firstStatus: .partial)
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises[0].actualSets, original.actualSets)
        XCTAssertEqual(event.exercises[0].actualLoad, original.actualLoad)
        XCTAssertEqual(event.exercises[0].mixedLoads, true)
        XCTAssertEqual(event.exercises[0].status, .partial)
        await repository.close()
    }
    func testSkippedIndexOrderIsImmutableBeforeMovementHandling() async throws {
        let (model, repository, _) = try await makeExact()
        try await model.start(easierToday: false)
        let id = model.snapshot.draft!.logs[0].movementID
        try await model.skipSet(movementID: id, index: 0)
        try await model.skipSet(movementID: id, index: 1)
        XCTAssertFalse(model.handled(id))
        var changed = model.snapshot.draft!
        changed.logs[0].skippedSetIndices = [1,0]
        do { try await repository.saveDraft(changed); XCTFail("Saved skipped-index prefix order cannot change") } catch {}
        let retained = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(retained.draft?.logs[0].skippedSetIndices, [0,1])
        await repository.close()
    }
}

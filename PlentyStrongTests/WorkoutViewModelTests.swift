import XCTest
import TrainingCore
@testable import PlentyStrong

@MainActor final class WorkoutViewModelTests: XCTestCase {
    private func make(goal: Goal = .size, date: String = "2026-10-06") async throws -> (WorkoutViewModel, TrainingRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("training.store")
        let repository = try TrainingRepository.open(at: url)
        let config = try selectFixedProgram(goal: goal, programID: UUID())
        let first = try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: date), config: config)
        let snapshot = try await repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        let model = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "\(date)T20:00:00Z")! })
        return (model, repository, url)
    }
    func testLegacySlotSelectionAndMalformedIndexKeepOriginalSemantics() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        if model.movement(for: row).loadingMode == .externalLoad {
            try await model.confirmLoad(movementID: row.movementID, load: XCTUnwrap(model.movement(for: row).availableLoads.first))
        }
        XCTAssertEqual(model.nextSetIndex(for: row.movementID), 0)
        for index in [-1, Int.max] {
            do { try await model.recordSet(movementID: row.movementID, index: index, actual: ActualSet(reps: 8)); XCTFail("Malformed legacy index") } catch {}
        }
        do { try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 0)); XCTFail("Legacy ordinary logging remains positive-only") } catch {}
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 7))
        XCTAssertEqual(model.nextSetIndex(for: row.movementID), 1)
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets, [ActualSet(reps: 7)])
        XCTAssertNil(model.log(for: row.movementID)?.effortScope)
        await repository.close()
    }
    func testAllGoalsStartWithUnknownLoadsAndFixedDose() async throws {
        for goal in Goal.allCases {
            let (model, repository, _) = try await make(goal: goal)
            try await model.start(easierToday: false)
            let draft = try XCTUnwrap(model.snapshot.draft)
            XCTAssertEqual(draft.date.iso8601, "2026-10-06")
            XCTAssertTrue(draft.logs.allSatisfy { $0.actualSets.isEmpty && $0.actualLoad == nil })
            XCTAssertEqual(draft.displayed.exercises.first?.sets.count, goal == .fatLoss || goal == .maintenance ? 2 : 3)
            XCTAssertEqual(model.snapshot.state.config.weeklySlots.compactMap(\.weekday), [0, 2, 4])
            await repository.close()
        }
    }
    func testEasierBeforeSetsChangesDoseAndLocksAfterObservation() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        try await model.start(easierToday: true)
        let row = try XCTUnwrap(model.snapshot.draft?.displayed.exercises.first)
        XCTAssertEqual(row.sets.count, 2)
        XCTAssertTrue(row.sets[0].effortInstruction.contains("4 good reps"))
        try await model.confirmLoad(movementID: row.movementID, load: model.movement(for: row).availableLoads[0])
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 5))
        do { try await model.start(easierToday: false); XCTFail("Must lock easier") } catch {}
        XCTAssertEqual(model.snapshot.draft?.sessionMode, .easier)
        await repository.close()
    }
    func testMissingRowsCannotFinishAndBlankRepsAreNotInvented() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        do { _ = try await model.finish(); XCTFail("Missing rows") } catch {}
        XCTAssertTrue(model.snapshot.draft!.logs.allSatisfy { $0.actualSets.isEmpty })
        await repository.close()
    }
    func testUnequalSidesStayPartialWithOriginalsAfterReopen() async throws {
        let (model, repository, url) = try await make()
        try await model.start(easierToday: false)
        let row = try XCTUnwrap(model.snapshot.draft?.displayed.exercises.first { model.movement(for: $0).repCounting == .perSide })
        if model.movement(for: row).loadingMode == .externalLoad { try await model.confirmLoad(movementID: row.movementID, load: model.movement(for: row).availableLoads[0]) }
        let original = ActualSet(reps: 9, leftReps: 9, rightReps: 6)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: original)
        do { try await model.recordStatus(movementID: row.movementID, status: .completed); XCTFail("Unequal sides cannot be complete") } catch {}
        try await model.recordStatus(movementID: row.movementID, status: .partial)
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let snapshot = try await reopened.snapshot(programID: UUID(uuidString: model.snapshot.state.config.programID)!)
        XCTAssertEqual(snapshot.draft?.logs.first { $0.movementID == row.movementID }?.actualSets, [original])
        XCTAssertEqual(snapshot.draft?.logs.first { $0.movementID == row.movementID }?.status, .partial)
        await reopened.close()
    }
    func testLiveProblemPreservesSetsStopsEntryAndFinalizesPause() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        if model.movement(for: row).loadingMode == .externalLoad { try await model.confirmLoad(movementID: row.movementID, load: model.movement(for: row).availableLoads[0]) }
        let raw = ActualSet(reps: 3)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: raw)
        try await model.recordProblem(movementID: row.movementID, problem: .pain)
        do { try await model.recordSet(movementID: row.movementID, index: 1, actual: raw); XCTFail("Stopped") } catch {}
        for other in model.snapshot.draft!.displayed.exercises.dropFirst() { try await model.recordStatus(movementID: other.movementID, status: .skipped) }
        let receipt = try await model.finish()
        XCTAssertEqual(receipt.snapshot.state.baseSafety?[row.baseMovementID!]?.paused, true)
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises[0].actualSets, [raw])
        XCTAssertEqual(event.exercises[0].problem, .pain)
        await repository.close()
    }
    func testSetupBaselineOpaqueTextSelectionCorrectionAndWorkingLock() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        let base = row.baseMovementID!
        let old = model.snapshot.state.exercises[row.movementID]!
        try await model.changeSetup(.create(baseMovementID: base, variantID: "opaque-test", modifications: "+25 lb"))
        XCTAssertEqual(model.snapshot.state.config.variants?["opaque-test"]?.modifications, "+25 lb")
        XCTAssertNil(model.snapshot.state.exercises["opaque-test"]?.load)
        XCTAssertEqual(model.snapshot.state.exercises["opaque-test"]?.mode, .baseline)
        try await model.changeSetup(.correctDescription(variantID: "opaque-test", modifications: "+25 lbs"))
        XCTAssertEqual(model.snapshot.state.exercises["opaque-test"]?.ceilingStreak, 0)
        try await model.changeSetup(.select(baseMovementID: base, variantID: row.movementID))
        XCTAssertEqual(model.snapshot.state.exercises[row.movementID], old)
        try await model.recordStatus(movementID: row.movementID, status: .skipped)
        try await model.recordProblem(movementID: row.movementID, problem: .controlLost)
        do { try await model.changeSetup(.select(baseMovementID: base, variantID: "opaque-test")); XCTFail("Problem locks") } catch {}
        await repository.close()
    }
    func testExplicitLoadCorrectionKeepsOriginalsAndCannotQualify() async throws {
        let (model, repository, url) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises.first { model.movement(for: $0).loadingMode == .externalLoad }!
        let load = model.movement(for: row).availableLoads[0]
        try await model.confirmLoad(movementID: row.movementID, load: load)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 10))
        do { try await model.confirmLoad(movementID: row.movementID, load: model.movement(for: row).availableLoads[1]); XCTFail("Explicit correction required") } catch {}
        try await model.stopForLoadCorrection(movementID: row.movementID)
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let saved = try await reopened.snapshot(programID: UUID(uuidString: model.snapshot.state.config.programID)!)
        XCTAssertEqual(saved.draft?.logs.first { $0.movementID == row.movementID }?.actualLoad, load)
        XCTAssertEqual(saved.draft?.logs.first { $0.movementID == row.movementID }?.actualSets, [ActualSet(reps: 10)])
        XCTAssertEqual(saved.draft?.logs.first { $0.movementID == row.movementID }?.status, .partial)
        await reopened.close()
    }
    func testDoubleFinishReusesEventAndUnknownEffortIsHonest() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        for row in model.snapshot.draft!.displayed.exercises { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        let eventID = model.snapshot.draft!.id.uuidString.lowercased()
        let first = try await model.finish()
        let second = try await model.finish()
        XCTAssertEqual(first.snapshot.history.count, second.snapshot.history.count)
        XCTAssertEqual(second.snapshot.history.last?.eventID, eventID)
        await repository.close()
    }
    func testSaveFailureLeavesOriginalSnapshotVisible() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let before = model.snapshot
        await repository.failNextSave()
        do { try await model.recordStatus(movementID: before.draft!.logs[0].movementID, status: .skipped); XCTFail("Save should fail") } catch {}
        XCTAssertEqual(model.snapshot, before)
        await repository.close()
    }
    func testRestDeadlineSurvivesBackgroundTime() {
        let start = Date(timeIntervalSince1970: 1000)
        let timer = RestTimer(deadline: start.addingTimeInterval(120))
        XCTAssertEqual(timer.remaining(at: start), 120)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(90)), 30)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(200)), 0)
    }
}

extension WorkoutViewModelTests {
    private func fill(_ model: WorkoutViewModel) async throws {
        for row in model.snapshot.draft!.displayed.exercises {
            let movement = model.movement(for: row)
            if row.kind == .paused { try await model.recordStatus(movementID: row.movementID, status: .skipped); continue }
            if movement.loadingMode == .externalLoad { try await model.confirmLoad(movementID: row.movementID, load: movement.availableLoads[0]) }
            for index in row.sets.indices {
                let reps = row.sets[index].repCeiling
                try await model.recordSet(movementID: row.movementID, index: index, actual: ActualSet(reps: reps,
                    leftReps: movement.repCounting == .perSide ? reps : nil, rightReps: movement.repCounting == .perSide ? reps : nil))
            }
            try await model.recordEffort(movementID: row.movementID, effort: .onTarget)
            try await model.recordStatus(movementID: row.movementID, status: .completed)
        }
    }
    func testNormalCompletedWorkoutProducesTruthfulHistoryAndNextPrescription() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        try await fill(model)
        let original = model.snapshot.draft!
        let receipt = try await model.finish()
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises, original.logs)
        XCTAssertEqual(event.eventID, original.id.uuidString.lowercased())
        XCTAssertEqual(receipt.snapshot.state.activePrescription.date.iso8601, "2026-10-08")
        XCTAssertEqual(receipt.snapshot.state.exercises[original.logs[0].movementID]?.mode, .normal)
        await repository.close()
    }
    func testCompletedEasierWorkoutDoesNotQualifyBaseline() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: true)
        try await fill(model)
        let id = model.snapshot.draft!.logs[0].movementID
        let receipt = try await model.finish()
        XCTAssertEqual(receipt.snapshot.state.exercises[id]?.mode, .baseline)
        XCTAssertEqual(receipt.snapshot.state.exercises[id]?.ceilingStreak, 0)
        await repository.close()
    }
    func testCorrectedFullSetsCannotBeRelabeledCompleted() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await model.confirmLoad(movementID: row.movementID, load: model.movement(for: row).availableLoads[0])
        for i in row.sets.indices { try await model.recordSet(movementID: row.movementID, index: i, actual: ActualSet(reps: 12)) }
        try await model.recordEffort(movementID: row.movementID, effort: .onTarget)
        try await model.stopForLoadCorrection(movementID: row.movementID)
        do { try await model.recordStatus(movementID: row.movementID, status: .completed); XCTFail("Corrected work must remain partial") } catch {}
        for other in model.snapshot.draft!.displayed.exercises.dropFirst() { try await model.recordStatus(movementID: other.movementID, status: .skipped) }
        let receipt = try await model.finish()
        XCTAssertEqual(receipt.snapshot.state.exercises[row.movementID]?.mode, .baseline)
        XCTAssertEqual(receipt.snapshot.state.exercises[row.movementID]?.ceilingStreak, 0)
        await repository.close()
    }
    func testOldAndNewDraftMetadataBackupRoundTripsAndRejectsUnknownAcknowledgement() async throws {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        let old = try await scenario.draft(empty: true)
        let oldBytes = try BackupService.bytes(old)
        let oldObject = try JSONSerialization.jsonObject(with: oldBytes) as! [String: Any]
        XCTAssertNil(oldObject["acknowledgedMovementIDs"])
        XCTAssertNil(oldObject["restDeadline"])
        XCTAssertEqual(try JSONDecoder().decode(WorkoutDraft.self, from: oldBytes), old)
        try await scenario.repository.saveDraft(old)
        var modern = old
        modern.acknowledgedMovementIDs = [old.logs[0].movementID]
        modern.restDeadline = Date(timeIntervalSince1970: 1791316920)
        try await scenario.repository.saveDraft(modern)
        let backup = try await scenario.repository.exportBackup()
        _ = try BackupService.validate(backup)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutDraft.self, from: backup.drafts[0].bytes), modern)
        let restoredURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("training.store")
        try FileManager.default.createDirectory(at: restoredURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let restored = try TrainingRepository.open(at: restoredURL)
        _ = try await restored.importBackup(backup)
        let restoredSnapshot = try await restored.snapshot(programID: scenario.programID)
        XCTAssertEqual(restoredSnapshot.draft, modern)
        await restored.close()
        var invalid = modern; invalid.acknowledgedMovementIDs = ["unknown"]
        do { try await scenario.repository.saveDraft(invalid); XCTFail("Unknown ack") } catch {}
        invalid.acknowledgedMovementIDs = [old.logs[0].movementID, old.logs[0].movementID]
        do { try await scenario.repository.saveDraft(invalid); XCTFail("Duplicate ack") } catch {}
        let reopened = try await scenario.reopened()
        let reopenedSnapshot = try await reopened.snapshot(programID: scenario.programID)
        XCTAssertEqual(reopenedSnapshot.draft, modern)
        await reopened.close()
    }
    func testMidnightRetainUsesOriginalDateTimezoneIdentityAndRequiresChoice() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let old = model.snapshot.draft!
        let later = WorkoutViewModel(repository: repository, snapshot: model.snapshot, timeZoneID: "Pacific/Auckland", now: { Date(timeIntervalSince1970: 1791403200) })
        XCTAssertTrue(later.needsDateChoice)
        do { try await later.recordStatus(movementID: old.logs[0].movementID, status: .skipped); XCTFail("Must choose") } catch {}
        try await later.resolveDateChange(keepOriginal: true)
        for log in old.logs { try await later.recordStatus(movementID: log.movementID, status: .skipped) }
        let receipt = try await later.finish()
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.date, old.date)
        XCTAssertEqual(event.eventID, old.id.uuidString.lowercased())
        await repository.close()
    }
    func testMissedSuggestionRetainsRotationAndInterruptionIsExplicitWithoutInventedHistory() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false); try await fill(model)
        let receipt = try await model.finish()
        let later = WorkoutViewModel(repository: repository, snapshot: receipt.snapshot, timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1793736000) })
        try await later.prepareToday()
        XCTAssertEqual(later.snapshot.history.filter { if case .workout = $0.command { true } else { false } }.count, 1)
        XCTAssertFalse(later.snapshot.history.contains { if case .reschedule = $0.command { true } else { false } })
        XCTAssertEqual(later.snapshot.state.activePrescription.slotID, receipt.snapshot.state.activePrescription.slotID)
        XCTAssertEqual(later.snapshot.state.activePrescription.date, receipt.snapshot.state.activePrescription.date)
        XCTAssertTrue(later.snapshot.history.contains { if case .interruption = $0.command { true } else { false } })
        XCTAssertTrue(later.snapshot.state.exercises.values.contains { $0.interruptedReturn })
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testProblemSurvivesClosingReopenMidnightAndBlocksDiscard() async throws {
        let (model, repository, url) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await model.recordProblem(movementID: row.movementID, problem: .controlLost)
        let original = model.snapshot.draft!
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let snapshot = try await reopened.snapshot(programID: UUID(uuidString: original.programID)!)
        let later = WorkoutViewModel(repository: reopened, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1791403200) })
        do { try await later.resolveDateChange(keepOriginal: false); XCTFail("Cannot discard safety flag") } catch {}
        XCTAssertEqual(later.snapshot.draft, original)
        try await later.resolveDateChange(keepOriginal: true)
        for other in original.displayed.exercises.dropFirst() { try await later.recordStatus(movementID: other.movementID, status: .skipped) }
        let receipt = try await later.finish()
        XCTAssertEqual(receipt.snapshot.state.baseSafety?[row.baseMovementID!]?.paused, true)
        let next = WorkoutViewModel(repository: reopened, snapshot: receipt.snapshot, timeZoneID: "Pacific/Honolulu")
        try await next.changeSetup(.create(baseMovementID: row.baseMovementID!, variantID: "cannot-bypass", modifications: "New setup"))
        XCTAssertEqual(next.snapshot.state.exercises["cannot-bypass"]?.mode, .paused)
        XCTAssertEqual(next.snapshot.state.baseSafety?[row.baseMovementID!]?.sourceEventIDs, [original.id.uuidString.lowercased()])
        await reopened.close()
    }
}

extension WorkoutViewModelTests {
    func testProblemAtomicallyRetainsValidPendingSideObservationWithoutInventingOtherSideOrLoad() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises.first { model.movement(for: $0).repCounting == .perSide }!
        let raw = ActualSet(reps: 6, leftReps: 6, rightReps: nil)
        try await model.recordProblem(movementID: row.movementID, problem: .pain, pendingActual: raw)
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets, [raw])
        XCTAssertNil(model.log(for: row.movementID)?.actualLoad)
        XCTAssertEqual(model.log(for: row.movementID)?.status, .stopped)
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testBodyweightOpaqueNumberSetupKeepsNullLoadAndNoCatalog() async throws {
        let (model, repository, _) = try await make(date: "2026-10-04")
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises.first { model.movement(for: $0).loadingMode != .externalLoad }!
        try await model.changeSetup(.create(baseMovementID: row.baseMovementID!, variantID: "opaque-bodyweight", modifications: "+25 lb"))
        let changed = model.snapshot.draft!.displayed.exercises.first { $0.movementID == "opaque-bodyweight" }!
        XCTAssertNil(changed.load)
        XCTAssertNil(model.log(for: changed.movementID)?.actualLoad)
        XCTAssertTrue(model.movement(for: changed).availableLoads.isEmpty)
        await repository.close()
    }
    func testExplicitNoProblemMidnightDiscardRestartsNewIdentityWithoutInventingCompletion() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let original = model.snapshot.draft!
        let later = WorkoutViewModel(repository: repository, snapshot: model.snapshot, timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1791489600) })
        try await later.resolveDateChange(keepOriginal: false)
        try await later.start(easierToday: false)
        XCTAssertNotEqual(later.snapshot.draft?.id, original.id)
        XCTAssertEqual(later.snapshot.draft?.date.iso8601, "2026-10-08")
        XCTAssertTrue(later.snapshot.draft!.logs.allSatisfy { $0.actualSets.isEmpty })
        XCTAssertEqual(later.snapshot.history.filter { if case .workout = $0.command { true } else { false } }.count, 0)
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testHistoricalDescriptionCorrectionPreservesIdentityStateAndOriginalAcceptedLabel() async throws {
        let (model, repository, _) = try await make(date: "2026-10-04")
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        try await model.changeSetup(.create(baseMovementID: row.baseMovementID!, variantID: "saved-setup", modifications: "Altered setup"))
        try await fill(model)
        _ = try await model.finish()
        let acceptedState = model.snapshot.state.exercises["saved-setup"]!
        let next = WorkoutViewModel(repository: repository, snapshot: model.snapshot, timeZoneID: "Pacific/Honolulu")
        try await next.changeSetup(.correctDescription(variantID: "saved-setup", modifications: "Corrected setup"))
        XCTAssertEqual(next.snapshot.state.exercises["saved-setup"], acceptedState)
        guard case let .workout(event, _) = next.snapshot.history.first(where: { if case .workout = $0.command { true } else { false } })!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises.first?.modificationsSnapshot, "Altered setup")
        XCTAssertEqual(next.snapshot.state.config.variants?["saved-setup"]?.modifications, "Corrected setup")
        try await next.changeSetup(.select(baseMovementID: row.baseMovementID!, variantID: row.movementID))
        try await next.changeSetup(.select(baseMovementID: row.baseMovementID!, variantID: "saved-setup"))
        XCTAssertEqual(next.snapshot.state.exercises["saved-setup"], acceptedState)
        await repository.close()
    }
    func testConcurrentFinishUsesOneStoredEvent() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        for row in model.snapshot.draft!.displayed.exercises { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        let identity = model.snapshot.draft!.id.uuidString.lowercased()
        async let first = model.finish()
        async let second = model.finish()
        let receipts = try await [first, second]
        XCTAssertEqual(receipts[0].snapshot.history.last?.eventID, identity)
        XCTAssertEqual(receipts[1].snapshot.history.last?.eventID, identity)
        XCTAssertEqual(receipts[0].snapshot.history.count, receipts[1].snapshot.history.count)
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testExplicitPartialRetainsPendingActualInsteadOfSilentlyDiscardingIt() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        let observed = ActualSet(reps: 4)
        try await model.recordStatus(movementID: row.movementID, status: .partial, pendingActual: observed)
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets, [observed])
        XCTAssertEqual(model.log(for: row.movementID)?.status, .partial)
        XCTAssertNil(model.log(for: row.movementID)?.actualLoad)
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testIndependentProblemIsAvailableAtMidnightBeforeDateChoiceWithoutRebucketing() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let old = model.snapshot.draft!
        let later = WorkoutViewModel(repository: repository, snapshot: model.snapshot, timeZoneID: "Pacific/Honolulu", now: { Date(timeIntervalSince1970: 1791403200) })
        XCTAssertTrue(later.needsDateChoice)
        try await later.recordProblem(movementID: old.logs[0].movementID, problem: .pain)
        XCTAssertEqual(later.snapshot.draft?.id, old.id)
        XCTAssertEqual(later.snapshot.draft?.date, old.date)
        XCTAssertEqual(later.log(for: old.logs[0].movementID)?.problem, .pain)
        XCTAssertFalse(later.canDiscardDraft)
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testRestoredAcknowledgementsCannotSubstituteForMissingCompletedActuals() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        var malformed = model.snapshot.draft!
        malformed.acknowledgedMovementIDs = malformed.logs.map(\.movementID)
        for i in malformed.logs.indices { malformed.logs[i].status = .completed }
        try await repository.saveDraft(malformed)
        let snapshot = try await repository.snapshot(programID: UUID(uuidString: malformed.programID)!)
        let restored = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: model.now)
        do { _ = try await restored.finish(); XCTFail("Acknowledgements cannot replace completed actuals") }
        catch let error as EngineError { XCTAssertEqual(error.code, "invalid_sets") }
        XCTAssertFalse(restored.finished)
        let after = try await repository.snapshot(programID: UUID(uuidString: malformed.programID)!)
        XCTAssertEqual(after, snapshot)
        try await restored.recoverRejectedCompletion()
        XCTAssertTrue(restored.snapshot.draft!.logs.allSatisfy { $0.status == .skipped && $0.actualSets.isEmpty })
        let receipt = try await restored.finish()
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertTrue(event.exercises.allSatisfy { $0.status == .skipped && $0.actualSets.isEmpty })
        XCTAssertEqual(event.eventID, malformed.id.uuidString.lowercased())
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testPendingCorrectionStopRetainsBothSetsAfterReopenAndPartialAcceptance() async throws {
        let (model, repository, url) = try await make()
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        let load = model.movement(for: row).availableLoads[0]
        try await model.confirmLoad(movementID: row.movementID, load: load)
        let originals = [ActualSet(reps: 7), ActualSet(reps: 5)]
        try await model.recordSet(movementID: row.movementID, index: 0, actual: originals[0])
        try await model.stopForLoadCorrection(movementID: row.movementID, pendingActual: originals[1])
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let snapshot = try await reopened.snapshot(programID: model.programID)
        let resumed = WorkoutViewModel(repository: reopened, snapshot: snapshot, timeZoneID: model.timeZoneID, now: model.now)
        XCTAssertEqual(resumed.log(for: row.movementID)?.actualSets, originals)
        XCTAssertEqual(resumed.log(for: row.movementID)?.actualLoad, load)
        do { try await resumed.recordStatus(movementID: row.movementID, status: .completed); XCTFail("Correction must remain partial") } catch {}
        for other in snapshot.draft!.logs.dropFirst() { try await resumed.recordStatus(movementID: other.movementID, status: .skipped) }
        let receipt = try await resumed.finish()
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises[0].actualSets, originals)
        XCTAssertEqual(event.exercises[0].actualLoad, load)
        XCTAssertEqual(event.exercises[0].status, .partial)
        XCTAssertEqual(receipt.snapshot.state.exercises[row.movementID]?.mode, .baseline)
        await reopened.close()
    }
    func testExtremeRestDeadlinesAreRejectedBySaveAndImportWithoutChangingDraft() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let original = model.snapshot.draft!
        let backup = try await repository.exportBackup()
        for seconds in [Date.distantFuture.timeIntervalSince1970 + 1, Date.distantPast.timeIntervalSince1970 - 1] {
            var invalid = original; invalid.restDeadline = Date(timeIntervalSince1970: seconds)
            do { try BackupService.validateDraft(invalid, state: model.snapshot.state, rules: RulesetCatalog.fixedV1()); XCTFail("Extreme metadata must be rejected") } catch let error as EngineError { XCTAssertEqual(error.code, "integrity_conflict"); XCTAssertEqual(error.field, "draft_ui_metadata") }
            do { try await repository.saveDraft(invalid); XCTFail("Extreme deadline must be rejected") } catch let error as EngineError { XCTAssertEqual(error.code, "integrity_conflict"); XCTAssertEqual(error.field, "draft_ui_metadata") }
            var imported = backup; imported.drafts = [try BackupService.object(invalid, id: invalid.id.uuidString.lowercased())]
            do { _ = try await repository.importBackup(imported); XCTFail("Extreme imported deadline must be rejected") } catch let error as EngineError { XCTAssertEqual(error.code, "integrity_conflict"); XCTAssertEqual(error.field, "draft_ui_metadata") }
        }
        let after = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(after, model.snapshot)
        for seconds in [1e20, -1e20, Double.infinity, -Double.infinity, Double.nan] {
            var invalid = original; invalid.restDeadline = Date(timeIntervalSince1970: seconds)
            do { try BackupService.validateDraft(invalid, state: model.snapshot.state, rules: RulesetCatalog.fixedV1()); XCTFail("Nonrepresentable metadata") }
            catch let error as EngineError { XCTAssertEqual(error.field, "draft_ui_metadata") }
        }
        await repository.close()
    }
    func testRejectedCompletionExplicitRepairPreservesOriginalsReopensAndFinalizesPartialSafety() async throws {
        let (model, repository, url) = try await make()
        try await model.start(easierToday: false)
        var malformed = model.snapshot.draft!
        malformed.acknowledgedMovementIDs = malformed.logs.map(\.movementID)
        for i in malformed.logs.indices { malformed.logs[i].status = .completed }
        malformed.logs[0].actualLoad = model.movement(for: malformed.displayed.exercises[0]).availableLoads[0]
        malformed.logs[0].actualSets = [ActualSet(reps: 4)]
        malformed.logs[0].problem = .pain; malformed.logs[1].problem = .controlLost; malformed.workingSetsStarted = true
        try await repository.saveDraft(malformed)
        let before = try await repository.snapshot(programID: model.programID)
        let restored = WorkoutViewModel(repository: repository, snapshot: before, timeZoneID: model.timeZoneID, now: model.now)
        do { _ = try await restored.finish(); XCTFail("Must reject malformed completion") }
        catch let error as EngineError { XCTAssertEqual(error.code, "invalid_sets") }
        XCTAssertTrue(restored.canRecoverRejectedCompletion)
        await repository.failNextSave()
        do { try await restored.recoverRejectedCompletion(); XCTFail("Repair save failure") } catch {}
        XCTAssertTrue(restored.canRecoverRejectedCompletion)
        let failedSave = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(failedSave, before)
        do { try await restored.recordStatus(movementID: malformed.logs[1].movementID, status: .partial); XCTFail("Failed save must retain freeze") } catch {}
        try await restored.recoverRejectedCompletion()
        XCTAssertFalse(restored.canRecoverRejectedCompletion)
        let repaired = restored.snapshot.draft!
        XCTAssertEqual(repaired.id, malformed.id)
        for (raw, kept) in zip(malformed.logs, repaired.logs) {
            XCTAssertEqual(kept.actualSets, raw.actualSets); XCTAssertEqual(kept.actualLoad, raw.actualLoad)
            XCTAssertEqual(kept.problem, raw.problem)
            XCTAssertEqual(kept.status, raw.actualSets.isEmpty && raw.problem == .none ? .skipped : .partial)
        }
        do { try await restored.recordStatus(movementID: malformed.logs[2].movementID, status: .completed); XCTFail("No promotion after repair") } catch {}
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let snapshot = try await reopened.snapshot(programID: model.programID)
        XCTAssertEqual(snapshot.draft, repaired)
        let resumed = WorkoutViewModel(repository: reopened, snapshot: snapshot, timeZoneID: model.timeZoneID, now: model.now)
        let receipt = try await resumed.finish()
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises, repaired.logs)
        XCTAssertEqual(event.eventID, malformed.id.uuidString.lowercased())
        XCTAssertTrue(receipt.snapshot.state.baseSafety?[malformed.logs[0].baseMovementID!]?.paused == true)
        XCTAssertTrue(receipt.snapshot.state.baseSafety?[malformed.logs[1].baseMovementID!]?.paused == true)
        XCTAssertEqual(receipt.snapshot.state.exercises[malformed.logs[2].movementID]?.mode, .baseline)
        await reopened.close()
    }
}

extension WorkoutViewModelTests {
    func testRestTimerSafelyClampsExtremeAndNonfiniteDeadlineOrClockIntervals() {
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(RestTimer(deadline: Date(timeIntervalSince1970: 1e20)).remaining(at: epoch), Int.max)
        XCTAssertEqual(RestTimer(deadline: Date(timeIntervalSince1970: -1e20)).remaining(at: epoch), 0)
        XCTAssertEqual(RestTimer(deadline: epoch).remaining(at: Date(timeIntervalSince1970: -1e20)), Int.max)
        XCTAssertEqual(RestTimer(deadline: epoch).remaining(at: Date(timeIntervalSince1970: 1e20)), 0)
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertEqual(RestTimer(deadline: Date(timeIntervalSince1970: value)).remaining(at: epoch), 0)
            XCTAssertEqual(RestTimer(deadline: epoch).remaining(at: Date(timeIntervalSince1970: value)), 0)
        }
        XCTAssertEqual(RestTimer(deadline: epoch.addingTimeInterval(0.1)).remaining(at: epoch), 1)
        XCTAssertEqual(RestTimer(deadline: .distantPast).remaining(at: epoch), 0)
    }
    func testSupportedRestDeadlineBoundaryDatesSaveImportAndDisplaySafely() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        for date in [Date.distantPast, Date.distantFuture] {
            var draft = model.snapshot.draft!; draft.restDeadline = date
            try await repository.saveDraft(draft)
            let backup = try await repository.exportBackup()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("training.store")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let restored = try TrainingRepository.open(at: url)
            _ = try await restored.importBackup(backup)
            let snapshot = try await restored.snapshot(programID: model.programID)
            XCTAssertEqual(snapshot.draft?.restDeadline, date)
            XCTAssertGreaterThanOrEqual(RestTimer(deadline: snapshot.draft?.restDeadline).remaining(at: model.now()), 0)
            await restored.close()
        }
        await repository.close()
    }
    func testTransientFinishFailureRetainsFrozenPayloadAndCannotRepairOrDiscard() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        for row in model.snapshot.draft!.displayed.exercises { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        let original = model.snapshot.draft!
        await repository.failNextSave()
        do { _ = try await model.finish(); XCTFail("Injected transient save failure") }
        catch let error as EngineError { XCTAssertEqual(error.code, "injected_save_failure") }
        XCTAssertFalse(model.canRecoverRejectedCompletion)
        XCTAssertFalse(model.canDiscardDraft)
        do { try await model.recoverRejectedCompletion(); XCTFail("Transient failure is not a proven rejection") } catch {}
        do { try await model.resolveDateChange(keepOriginal: false); XCTFail("Frozen Finish cannot discard") } catch {}
        do { try await model.recordEffort(movementID: original.logs[0].movementID, effort: .tooHard); XCTFail("Payload frozen") } catch {}
        let unchanged = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(unchanged.draft, original)
        let receipt = try await model.finish()
        guard case let .workout(event, _) = receipt.snapshot.history.last!.command else { return XCTFail("Workout") }
        XCTAssertEqual(event.exercises, original.logs)
        XCTAssertEqual(event.eventID, original.id.uuidString.lowercased())
        XCTAssertEqual(receipt.snapshot.history.count, unchanged.history.count + 1)
        await repository.close()
    }
    func testRejectedRepairRechecksAuthoritativeDraftAndDoesNotClearFreezeOnChangedProof() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        var malformed = model.snapshot.draft!
        malformed.acknowledgedMovementIDs = malformed.logs.map(\.movementID)
        for i in malformed.logs.indices { malformed.logs[i].status = .completed }
        try await repository.saveDraft(malformed)
        let before = try await repository.snapshot(programID: model.programID)
        let restored = WorkoutViewModel(repository: repository, snapshot: before, timeZoneID: model.timeZoneID, now: model.now)
        do { _ = try await restored.finish(); XCTFail("Malformed") } catch {}
        XCTAssertTrue(restored.canRecoverRejectedCompletion)
        var changed = malformed; changed.logs[0].finalEffort = .tooEasy
        try await repository.saveDraft(changed)
        do { try await restored.recoverRejectedCompletion(); XCTFail("Proof changed") }
        catch let error as EngineError { XCTAssertEqual(error.code, "recovery_proof_changed") }
        do { try await restored.recordStatus(movementID: changed.logs[0].movementID, status: .partial); XCTFail("Freeze must remain") } catch {}
        let after = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(after.draft, changed)
        XCTAssertEqual(after.history, before.history)
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testAtomicRepairSaveRejectsChangedOrMissingExistingDraftBeforeWrites() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let original = model.snapshot.draft!
        var repaired = original; repaired.logs[0].status = .skipped
        var changed = original; changed.logs[0].finalEffort = .tooHard
        try await repository.saveDraft(changed)
        do { try await repository.saveDraft(repaired, expectedExistingDraft: original); XCTFail("Stale proof") }
        catch let error as EngineError { XCTAssertEqual(error.code, "integrity_conflict"); XCTAssertEqual(error.field, "draft_repair_proof_changed") }
        let unchanged = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(unchanged.draft, changed)
        try await repository.discardDraft(id: original.id)
        do { try await repository.saveDraft(repaired, expectedExistingDraft: original); XCTFail("Missing proof") }
        catch let error as EngineError { XCTAssertEqual(error.field, "draft_repair_proof_changed") }
        let missing = try await repository.snapshot(programID: model.programID)
        XCTAssertNil(missing.draft)
        XCTAssertEqual(missing.history, model.snapshot.history)
        await repository.close()
    }
    func testAtomicRepairProofUsesCanonicalBytesInsteadOfUnicodeEquivalentLabels() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let base = model.snapshot.draft!.displayed.exercises[0].baseMovementID!
        try await model.changeSetup(.create(baseMovementID: base, variantID: "unicode-proof", modifications: "Caf\u{00E9}"))
        let original = model.snapshot.draft!
        var equivalent = original
        equivalent.logs[0].modificationsSnapshot = "Cafe\u{0301}"
        XCTAssertEqual(equivalent, original) // Swift String equality intentionally normalizes.
        XCTAssertNotEqual(try BackupService.bytes(equivalent), try BackupService.bytes(original))
        var repaired = original; repaired.logs[0].status = .skipped
        do { try await repository.saveDraft(repaired, expectedExistingDraft: equivalent); XCTFail("Non-exact proof") }
        catch let error as EngineError { XCTAssertEqual(error.field, "draft_repair_proof_changed") }
        let after = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(after, model.snapshot)
        await repository.close()
    }
    func testAtomicRepairSaveRejectsOriginalEventAcceptedInAnotherProgram() async throws {
        let (model, repository, _) = try await make()
        try await model.start(easierToday: false)
        let original = model.snapshot.draft!
        let config = try selectFixedProgram(goal: .maintenance, programID: UUID())
        let first = try WorkoutScheduler.nextSlot(onOrAfter: original.date, config: config)
        let other = try await repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        let displayed = try prepareWorkout(state: other.state, rules: RulesetCatalog.fixedV1(), easierToday: false)
        let logs = displayed.exercises.map { ExerciseLog(movementID: $0.movementID, prescriptionID: displayed.id, status: .skipped, actualLoad: nil, actualSets: [], finalEffort: .unknown, problem: .none, baseMovementID: $0.baseMovementID, modificationsSnapshot: $0.modificationsSnapshot) }
        let event = CompletedWorkout(eventID: original.id.uuidString.lowercased(), date: displayed.date, slotID: displayed.slotID, prescriptionID: displayed.id, plannedPrescriptionID: other.state.activePrescription.id, sessionMode: .normal, exercises: logs)
        let next = try WorkoutScheduler.nextSlot(after: displayed.date, config: config)
        let receipt = try await repository.finalize(programID: UUID(uuidString: config.programID)!, expectedRevision: other.state.revision, event: event, next: next)
        if case .applied = receipt.result {} else { XCTFail("Synthetic other program should accept its own truthful skipped event") }
        var repaired = original; repaired.logs[0].status = .skipped
        do { try await repository.saveDraft(repaired, expectedExistingDraft: original); XCTFail("Globally accepted ID") }
        catch let error as EngineError { XCTAssertEqual(error.field, "draft_repair_proof_changed") }
        let after = try await repository.snapshot(programID: model.programID)
        XCTAssertEqual(after, model.snapshot)
        await repository.close()
    }
}

extension WorkoutViewModelTests {
    func testFractionalUIClockSavesExactPerformedSetWithCanonicalRestDeadlineAfterReopen() async throws {
        let (original, repository, url) = try await make()
        let instant = original.now().addingTimeInterval(0.125)
        let model = WorkoutViewModel(repository: repository, snapshot: original.snapshot, timeZoneID: original.timeZoneID, now: { instant })
        try await model.start(easierToday: false)
        let row = model.snapshot.draft!.displayed.exercises[0]
        let load = model.movement(for: row).availableLoads[0]
        try await model.confirmLoad(movementID: row.movementID, load: load)
        let actual = ActualSet(reps: 7)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: actual)
        let deadline = try XCTUnwrap(model.snapshot.draft?.restDeadline)
        XCTAssertEqual(model.now(), instant)
        XCTAssertEqual(model.snapshot.draft?.date, original.snapshot.state.activePrescription.date)
        XCTAssertEqual(RestTimer(deadline: deadline).remaining(at: instant), row.restSeconds + 1)
        XCTAssertEqual(deadline.timeIntervalSinceReferenceDate.rounded(), deadline.timeIntervalSinceReferenceDate)
        XCTAssertGreaterThanOrEqual(deadline.timeIntervalSince(instant), Double(row.restSeconds))
        XCTAssertLessThan(deadline.timeIntervalSince(instant), Double(row.restSeconds) + 1)
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        let snapshot = try await reopened.snapshot(programID: model.programID)
        XCTAssertEqual(snapshot.draft?.logs[0].actualSets, [actual])
        XCTAssertEqual(snapshot.draft?.logs[0].actualLoad, load)
        XCTAssertEqual(snapshot.draft?.restDeadline, deadline)
        _ = try BackupService.validate(try await reopened.exportBackup())
        await reopened.close()
    }
}

@MainActor final class HistorySettingsModelTests: XCTestCase {
    private func accepted(goal: Goal = .size, transform: (inout CompletedWorkout) -> Void = { _ in }) async throws -> (RepositoryScenario, StoreSnapshot) {
        let scenario = try await RepositoryTestHarness.make(goal: goal)
        var event = scenario.firstEvent; transform(&event)
        let receipt = try await scenario.repository.finalize(programID: scenario.programID, expectedRevision: scenario.initialRevision, event: event, next: scenario.next)
        if case let .rejected(_, errors) = receipt.result { XCTFail("Unexpected rejection: \(errors)") }
        return (scenario, receipt.snapshot)
    }
    private func model(_ scenario: RepositoryScenario, _ snapshot: StoreSnapshot) -> WorkoutViewModel {
        WorkoutViewModel(repository: scenario.repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "2026-10-06T20:00:00Z")! })
    }
    func testActualsAndStoredDecisionsSurviveGoalAndAffectedSetupReset() async throws {
        let (scenario, original) = try await accepted { event in event.exercises[0].actualSets = [10, 10, 9].map { ActualSet(reps: $0) } }
        let vm = model(scenario, original); let id = original.state.activePrescription.exercises[0].movementID
        let originalHistory = original.history
        let otherID = original.state.exercises.keys.first { $0 != id }!
        let other = original.state.exercises[otherID]
        try await vm.changeProgram(.resetSetup(variantID: id))
        XCTAssertEqual(vm.snapshot.state.exercises[otherID], other)
        XCTAssertEqual(vm.snapshot.history.prefix(originalHistory.count), originalHistory[...])
        XCTAssertEqual(vm.snapshot.state.exercises[id]?.load, original.state.exercises[id]?.load)
        try await vm.changeProgram(.goal(.maintenance))
        XCTAssertEqual(vm.snapshot.history.prefix(originalHistory.count), originalHistory[...])
        guard case let .workout(event, _) = original.history.last!.command else { return XCTFail("Expected original raw workout") }
        XCTAssertEqual(WorkoutDetailView.reps(event.exercises[0]), "10, 10, 9")
        XCTAssertEqual(original.state.exercises[event.exercises[0].movementID]?.repCeiling, 12)
        await scenario.repository.close()
    }
    func testPartialProblemAboveCeilingRawWorkAndCoverageRemainVisible() async throws {
        let (scenario, snapshot) = try await accepted { event in
            event.exercises[0].status = .partial; event.exercises[0].actualSets = [ActualSet(reps: 4)]
            event.exercises[1].status = .stopped; event.exercises[1].problem = .pain
            event.exercises[2].actualSets = [ActualSet(reps: 13), ActualSet(reps: 13), ActualSet(reps: 13)]
        }
        guard case let .workout(event, _) = snapshot.history.last!.command else { return XCTFail("Raw workout missing") }
        XCTAssertEqual(event.exercises[0].actualSets[0].reps, 4)
        XCTAssertEqual(event.exercises[1].problem, .pain)
        XCTAssertEqual(WorkoutDetailView.reps(event.exercises[2]), "13, 13, 13")
        XCTAssertTrue(WorkoutDetailView.coverage(event).contains("1 partial"))
        XCTAssertTrue(WorkoutDetailView.coverage(event).contains("1 stopped"))
        XCTAssertTrue(snapshot.decisions.contains { $0.explanationKey == "rep_ceiling_exceeded" })
        XCTAssertTrue(snapshot.decisions.contains { $0.explanationKey == "movement_paused" })
        await scenario.repository.close()
    }
    func testSidesAreShownSeparatelyAndMissingSideIsUnknown() {
        let log = ExerciseLog(movementID: "variant", prescriptionID: "p", status: .partial, actualLoad: nil, actualSets: [ActualSet(reps: 7, leftReps: 7, rightReps: nil)], finalEffort: .unknown, problem: .none)
        XCTAssertEqual(WorkoutDetailView.reps(log), "Left 7, right unrecorded")
    }
    func testStoredMaintenanceSuccessCopyAndStableWork() async throws {
        let (scenario, initial) = try await accepted(goal: .maintenance)
        var snapshot = initial
        for _ in 0..<3 {
            let event = RepositoryTestHarness.event(state: snapshot.state, reps: 12)
            let next = try WorkoutScheduler.nextSlot(after: event.date, config: snapshot.state.config)
            snapshot = try await scenario.repository.finalize(programID: scenario.programID, expectedRevision: snapshot.state.revision, event: event, next: next).snapshot
        }
        let decision = try XCTUnwrap(snapshot.history.last?.decisions.first { $0.explanationKey == "maintenance_success" })
        XCTAssertTrue(DecisionExplanationView.copy(for: decision.explanationKey).contains("maintenance success"))
        XCTAssertEqual(snapshot.state.exercises[decision.movementID!]?.repCeiling, 12)
        XCTAssertEqual(snapshot.state.exercises[decision.movementID!]?.load, initial.state.exercises[decision.movementID!]?.load)
        await scenario.repository.close()
    }
    func testCorrectionPreservesOriginalLabelsAndIndependentSavedSetup() async throws {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        let initial = try await scenario.repository.snapshot(programID: scenario.programID)
        let vm = model(scenario, initial); let base = initial.state.config.movements[0].id
        let original = initial.state.config.activeVariantIDs![base]!
        try await vm.changeSetup(.create(baseMovementID: base, variantID: "synthetic-opaque", modifications: "35 lb assistance"))
        XCTAssertNil(vm.snapshot.state.exercises["synthetic-opaque"]?.load)
        XCTAssertTrue(vm.snapshot.state.exercises["synthetic-opaque"]!.recentComparable.isEmpty)
        let event = RepositoryTestHarness.event(state: vm.snapshot.state, reps: 10)
        let accepted = try await scenario.repository.finalize(programID: scenario.programID, expectedRevision: vm.snapshot.state.revision, event: event, next: scenario.next).snapshot
        let historical = model(scenario, accepted)
        let performedState = accepted.state.exercises["synthetic-opaque"]
        try await historical.changeSetup(.correctDescription(variantID: "synthetic-opaque", modifications: "Corrected wording"))
        XCTAssertEqual(historical.snapshot.state.exercises["synthetic-opaque"], performedState)
        let envelope = try XCTUnwrap(historical.snapshot.history.first { if case .workout = $0.command { return true }; return false })
        guard case let .workout(raw, _) = envelope.command else { return XCTFail("Raw command") }
        XCTAssertEqual(raw.exercises.first { $0.movementID == "synthetic-opaque" }?.modificationsSnapshot, "35 lb assistance")
        XCTAssertEqual(historical.snapshot.state.config.variants?["synthetic-opaque"]?.modifications, "Corrected wording")
        try await historical.changeSetup(.select(baseMovementID: base, variantID: original))
        XCTAssertEqual(historical.snapshot.state.exercises[original], initial.state.exercises[original])
        XCTAssertEqual(historical.snapshot.state.exercises["synthetic-opaque"], performedState)
        await scenario.repository.close()
    }
    func testBasePauseCannotBeBypassedAndSafeResumeNeedsExplicitClearance() async throws {
        let (scenario, snapshot) = try await accepted { $0.exercises[0].problem = .pain; $0.exercises[0].status = .stopped }
        let vm = model(scenario, snapshot); let base = snapshot.state.config.movements[0].id
        let safety = snapshot.state.baseSafety![base]!
        try await vm.changeSetup(.create(baseMovementID: base, variantID: "paused-alternative", modifications: "+25 lb"))
        XCTAssertEqual(vm.snapshot.state.exercises["paused-alternative"]?.mode, .paused)
        try await vm.changeProgram(.resetSetup(variantID: "paused-alternative"))
        XCTAssertEqual(vm.snapshot.state.baseSafety![base], safety)
        let before = vm.snapshot
        do { try await vm.changeProgram(.safeResume(baseMovementID: base, externalClearanceConfirmed: false)); XCTFail("Requires confirmation") } catch {}
        XCTAssertEqual(vm.snapshot, before)
        try await vm.changeProgram(.safeResume(baseMovementID: base, externalClearanceConfirmed: true))
        XCTAssertFalse(vm.snapshot.state.baseSafety![base]!.paused)
        XCTAssertEqual(vm.snapshot.state.baseSafety![base]!.sourceEventIDs, safety.sourceEventIDs)
        XCTAssertEqual(vm.snapshot.state.baseSafety![base]!.minimumRir, safety.minimumRir)
        XCTAssertEqual(vm.snapshot.state.exercises["paused-alternative"]?.mode, .baseline)
        await scenario.repository.close()
    }
    func testActiveDraftRejectsProgramAndRestoreWithoutChangingOriginals() async throws {
        let (scenario, snapshot) = try await accepted(); let vm = model(scenario, snapshot)
        try await vm.start(easierToday: false)
        let before = vm.snapshot; let backup = try await scenario.repository.exportBackup()
        do { try await vm.changeProgram(.goal(.maintenance)); XCTFail("Draft lock") } catch {}
        do { _ = try await vm.restoreBackup(backup); XCTFail("Restore lock") } catch {}
        XCTAssertEqual(vm.snapshot, before)
        let stored = try await scenario.repository.snapshot(programID: scenario.programID)
        XCTAssertEqual(stored, before)
        await scenario.repository.close()
    }
    func testAcceptedFinishAllowsSettingsWhileRepeatedFinishRemainsIdempotent() async throws {
        let (scenario, snapshot) = try await accepted(); let vm = model(scenario, snapshot)
        try await vm.start(easierToday: false)
        for row in vm.snapshot.draft!.displayed.exercises { try await vm.recordStatus(movementID: row.movementID, status: .skipped) }
        _ = try await vm.finish()
        XCTAssertTrue(vm.canEditProgramSettings)
        _ = try await vm.finish()
        try await vm.changeProgram(.goal(.maintenance))
        XCTAssertEqual(vm.snapshot.state.config.goal, .maintenance)
        await scenario.repository.close()
    }
    func testEmptyStoreRestoresLocalFileAndCurrentStoreImportIsIdempotent() async throws {
        let (scenario, snapshot) = try await accepted()
        let vm = model(scenario, snapshot)
        let source = AppComposition(repository: scenario.repository, workout: vm)
        let file = try await source.exportBackupFile(); let bytes = try Data(contentsOf: file)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let targetRepository = try TrainingRepository.open(at: root.appendingPathComponent("training.store"))
        let target = AppComposition(repository: targetRepository)
        XCTAssertNil(target.workout)
        let receipt = try await target.restoreBackupData(bytes)
        XCTAssertEqual(receipt.accepted, snapshot.history.count)
        XCTAssertEqual(target.workout?.snapshot, snapshot)
        let again = try await target.restoreBackupData(bytes)
        XCTAssertEqual(again.accepted, 0); XCTAssertEqual(again.identical, snapshot.history.count)
        XCTAssertEqual(target.workout?.snapshot, snapshot)
        let restoredBackup = try await targetRepository.exportBackup()
        let originalBackup = try await scenario.repository.exportBackup()
        XCTAssertEqual(restoredBackup, originalBackup)
        await targetRepository.close(); await scenario.repository.close()
    }
    func testUnsupportedAndCorruptBackupPreserveStoreWithReadableError() async throws {
        let (scenario, snapshot) = try await accepted(); let vm = model(scenario, snapshot)
        let composition = AppComposition(repository: scenario.repository, workout: vm)
        let original = try await scenario.repository.exportBackup()
        var unsupported = original; unsupported.formatVersion = 99
        for bytes in [try BackupService.bytes(unsupported), Data("{broken".utf8)] {
            do { _ = try await composition.restoreBackupData(bytes); XCTFail("Invalid restore") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unsupported or corrupt")) }
            let retained = try await scenario.repository.exportBackup()
            XCTAssertEqual(retained, original)
            XCTAssertEqual(vm.snapshot, snapshot)
        }
        await scenario.repository.close()
    }
    func testConflictingSameProgramBackupQuarantinesWithoutReplacingOriginalHistory() async throws {
        let (scenario, snapshot) = try await accepted(); let vm = model(scenario, snapshot)
        let original = try await scenario.repository.exportBackup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let branch = try TrainingRepository.open(at: root.appendingPathComponent("training.store"))
        _ = try await branch.importBackup(original)
        let other = WorkoutViewModel(repository: branch, snapshot: snapshot, timeZoneID: "Pacific/Honolulu")
        try await other.changeProgram(.goal(.maintenance))
        try await vm.changeProgram(.goal(.strength))
        let localHistory = vm.snapshot.history
        let localState = vm.snapshot.state
        let incoming = try await branch.exportBackup()
        let composition = AppComposition(repository: scenario.repository, workout: vm)
        let receipt = try await composition.restoreBackupData(BackupService.bytes(incoming))
        XCTAssertGreaterThan(receipt.conflicted, 0); XCTAssertEqual(receipt.accepted, 0)
        XCTAssertTrue(localHistory.allSatisfy { original in vm.snapshot.history.contains { $0.envelopeHash == original.envelopeHash } }); XCTAssertEqual(vm.snapshot.history.count, localHistory.count + 1); XCTAssertEqual(vm.snapshot.state, localState)
        XCTAssertEqual(vm.snapshot.health, .integrityConflict)
        XCTAssertTrue(composition.workout === vm)
        let counts = try await scenario.repository.counts(); XCTAssertEqual(counts[4], 1)
        await branch.close(); await scenario.repository.close()
    }
    func testMultipleProgramBackupRejectsBeforeAnyWrite() async throws {
        let (scenario, snapshot) = try await accepted(); let (source, _) = try await accepted()
        let extra = try selectFixedProgram(goal: .maintenance, programID: UUID())
        let first = try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-04"), config: extra)
        _ = try await source.repository.initialize(config: extra, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        let document = try await source.repository.exportBackup()
        XCTAssertEqual(document.heads.count, 2)
        let original = try await scenario.repository.exportBackup()
        let composition = AppComposition(repository: scenario.repository, workout: model(scenario, snapshot))
        do { _ = try await composition.restoreBackupData(BackupService.bytes(document)); XCTFail("Multiple programs") }
        catch { XCTAssertTrue(error.localizedDescription.contains("exactly one program")) }
        let retained = try await scenario.repository.exportBackup(); XCTAssertEqual(retained, original)
        await scenario.repository.close(); await source.repository.close()
    }
    func testTransientFinishKeepsProgramAndImportFrozenUntilAuthoritativeRetry() async throws {
        let (scenario, snapshot) = try await accepted(); let vm = model(scenario, snapshot)
        try await vm.start(easierToday: false)
        for row in vm.snapshot.draft!.displayed.exercises { try await vm.recordStatus(movementID: row.movementID, status: .skipped) }
        let backup = try await scenario.repository.exportBackup(); let before = vm.snapshot
        await scenario.repository.failNextSave()
        do { _ = try await vm.finish(); XCTFail("Injected failure") } catch {}
        XCTAssertFalse(vm.canEditProgramSettings); XCTAssertFalse(vm.canChangePreparation)
        do { try await vm.changeProgram(.goal(.maintenance)); XCTFail("Frozen Finish") } catch {}
        do { _ = try await vm.restoreBackup(backup); XCTFail("Frozen restore") } catch {}
        XCTAssertEqual(vm.snapshot, before)
        _ = try await vm.finish()
        XCTAssertTrue(vm.finished); XCTAssertTrue(vm.canEditProgramSettings)
        await scenario.repository.close()
    }
    func testDifferentProgramRejectsBeforeAnyWrite() async throws {
        let (scenario, snapshot) = try await accepted(); let (foreign, _) = try await accepted()
        let composition = AppComposition(repository: scenario.repository, workout: model(scenario, snapshot))
        let original = try await scenario.repository.exportBackup()
        let document = try await foreign.repository.exportBackup()
        do { _ = try await composition.restoreBackupData(BackupService.bytes(document)); XCTFail("Different program") }
        catch { XCTAssertTrue(error.localizedDescription.contains("different program")) }
        let retained = try await scenario.repository.exportBackup()
        XCTAssertEqual(retained, original)
        await scenario.repository.close(); await foreign.repository.close()
    }
    func testEmptyRestoreSerializesConfirmationBeforeImportAndAfterCommit() async throws {
        let (source, original) = try await accepted { $0.exercises[0].actualSets = [10, 10, 9].map { ActualSet(reps: $0) } }
        let document = try await source.repository.exportBackup()
        for afterCommit in [false, true] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("training.store")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let repository = try TrainingRepository.open(at: url)
            let composition = AppComposition(repository: repository)
            let checkpoint = RestoreCheckpoint()
            if afterCommit { composition.restoreBeforeAdoptionForTesting = { await checkpoint.pause() } }
            else { composition.restoreBeforeImportForTesting = { await checkpoint.pause() } }
            let restore = Task { try await composition.restoreBackupData(BackupService.bytes(document)) }
            await checkpoint.waitUntilEntered()
            await composition.confirm(choice: .upperBody, goal: .strength)
            checkpoint.release()
            _ = try await restore.value
            let backup = try await repository.exportBackup()
            XCTAssertEqual(backup.heads.count, 1, "No competing initialization in phase afterCommit=\(afterCommit)")
            XCTAssertEqual(backup, document)
            XCTAssertEqual(composition.workout?.snapshot, original)
            XCTAssertNil(composition.workout?.snapshot.draft)
            await repository.close()
        }
        await source.repository.close()
    }
    func testExistingRestoreRejectsConfigurationAndStartAcrossCallableTabEntries() async throws {
        let (scenario, original) = try await accepted()
        let vm = model(scenario, original)
        let composition = AppComposition(repository: scenario.repository, workout: vm)
        let document = try await scenario.repository.exportBackup()
        let checkpoint = RestoreCheckpoint()
        composition.restoreBeforeImportForTesting = { await checkpoint.pause() }
        let restore = Task { try await composition.restoreBackupData(BackupService.bytes(document)) }
        await checkpoint.waitUntilEntered()
        do { try await vm.changeProgram(.goal(.maintenance)); XCTFail("Configuration must reject while restoring") }
        catch { XCTAssertEqual((error as? EngineError)?.code, "operation_in_progress") }
        do { try await vm.start(easierToday: false); XCTFail("Direct start must reject while restoring") }
        catch { XCTAssertEqual((error as? EngineError)?.code, "operation_in_progress") }
        await vm.run { try await vm.start(easierToday: true) }
        checkpoint.release()
        let receipt = try await restore.value
        XCTAssertEqual(receipt.accepted, 0); XCTAssertEqual(receipt.identical, original.history.count)
        let retained = try await scenario.repository.exportBackup()
        XCTAssertEqual(retained, document)
        let current = try await scenario.repository.snapshot(programID: scenario.programID)
        XCTAssertEqual(current, original); XCTAssertNil(current.draft)
        XCTAssertTrue(composition.workout === vm)
        await scenario.repository.close()
    }
    func testCommittedQuarantineRemainsLockedUntilAuthoritativeModelReload() async throws {
        let (scenario, original) = try await accepted()
        let vm = model(scenario, original)
        let branchURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("training.store")
        try FileManager.default.createDirectory(at: branchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let branch = try TrainingRepository.open(at: branchURL)
        _ = try await branch.importBackup(scenario.repository.exportBackup())
        let other = WorkoutViewModel(repository: branch, snapshot: original, timeZoneID: "Pacific/Honolulu")
        try await other.changeProgram(.goal(.maintenance))
        try await vm.changeProgram(.goal(.strength))
        let local = vm.snapshot
        let document = try await branch.exportBackup()
        let composition = AppComposition(repository: scenario.repository, workout: vm)
        let checkpoint = RestoreCheckpoint()
        vm.restoreBeforeAdoptionForTesting = { await checkpoint.pause() }
        let restore = Task { try await composition.restoreBackupData(BackupService.bytes(document)) }
        await checkpoint.waitUntilEntered()
        let committed = try await scenario.repository.snapshot(programID: scenario.programID)
        XCTAssertEqual(committed.health, .integrityConflict)
        XCTAssertEqual(committed.state.revision, local.state.revision)
        do { try await vm.changeProgram(.goal(.size)); XCTFail("Stale ready snapshot must not append configuration") }
        catch { XCTAssertEqual((error as? EngineError)?.code, "operation_in_progress") }
        do { try await vm.start(easierToday: false); XCTFail("No new draft before adoption") }
        catch { XCTAssertEqual((error as? EngineError)?.code, "operation_in_progress") }
        checkpoint.release()
        let receipt = try await restore.value
        XCTAssertGreaterThan(receipt.conflicted, 0)
        let current = try await scenario.repository.snapshot(programID: scenario.programID)
        XCTAssertEqual(current.state, local.state); XCTAssertTrue(local.history.allSatisfy { original in current.history.contains { $0.envelopeHash == original.envelopeHash } }); XCTAssertEqual(current.history.count, local.history.count + 1)
        XCTAssertEqual(current.health, .integrityConflict); XCTAssertNil(current.draft)
        XCTAssertEqual(vm.snapshot, current); XCTAssertTrue(composition.workout === vm)
        let backup = try await scenario.repository.exportBackup(); XCTAssertEqual(backup.heads.count, 1)
        let counts = try await scenario.repository.counts(); XCTAssertEqual(counts[4], 1)
        await branch.close(); await scenario.repository.close()
    }
    func testConcurrentSecondRestoreRejectsWithoutReplacingIdentityOrHistory() async throws {
        let (scenario, original) = try await accepted()
        let vm = model(scenario, original)
        let composition = AppComposition(repository: scenario.repository, workout: vm)
        let document = try await scenario.repository.exportBackup()
        let checkpoint = RestoreCheckpoint()
        vm.restoreBeforeAdoptionForTesting = { await checkpoint.pause() }
        let restore = Task { try await composition.restoreBackupData(BackupService.bytes(document)) }
        await checkpoint.waitUntilEntered()
        // Remove only the injection so a broken implementation cannot suspend the second call.
        vm.restoreBeforeAdoptionForTesting = nil
        do { _ = try await composition.restoreBackupData(BackupService.bytes(document)); XCTFail("Second composition restore must reject") }
        catch { XCTAssertEqual((error as? EngineError)?.code, "operation_in_progress") }
        do { _ = try await vm.restoreBackup(document); XCTFail("Direct model restore must reject") }
        catch { XCTAssertEqual((error as? EngineError)?.code, "operation_in_progress") }
        checkpoint.release(); _ = try await restore.value
        let backup = try await scenario.repository.exportBackup(); XCTAssertEqual(backup, document)
        XCTAssertEqual(vm.snapshot, original); XCTAssertTrue(composition.workout === vm)
        await scenario.repository.close()
    }
    func testFailedAndRejectedRestoreReleaseGuardForRealInitializationAndRetry() async throws {
        let (source, original) = try await accepted()
        let document = try await source.repository.exportBackup()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("training.store")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let repository = try TrainingRepository.open(at: url)
        let composition = AppComposition(repository: repository)
        await repository.failNextSave()
        do { _ = try await composition.restoreBackupData(BackupService.bytes(document)); XCTFail("Injected save must fail") } catch {}
        let empty = try await repository.exportBackup(); XCTAssertTrue(empty.heads.isEmpty)
        XCTAssertNil(composition.workout)
        var unsupported = document; unsupported.formatVersion = 99
        do { _ = try await composition.restoreBackupData(BackupService.bytes(unsupported)); XCTFail("Unsupported backup must reject") } catch {}
        _ = try await composition.restoreBackupData(BackupService.bytes(document))
        XCTAssertEqual(composition.workout?.snapshot, original)
        let backup = try await repository.exportBackup(); XCTAssertEqual(backup, document)
        try await composition.workout!.changeProgram(.goal(.maintenance))
        XCTAssertEqual(composition.workout?.snapshot.state.config.goal, .maintenance)
        XCTAssertEqual(composition.workout?.snapshot.history.prefix(original.history.count), original.history[...])
        await repository.close(); await source.repository.close()
    }

}


@MainActor private final class RestoreCheckpoint {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { paused = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { paused?.resume(); paused = nil }
}


extension WorkoutViewModelTests {
    func testLegacyStartPolicyActivationCommitsOffMain() async throws {
        let scenario = try await RepositoryTestHarness.make(goal: .size)
        let initial = try await scenario.repository.snapshot(programID: scenario.programID)
        let model = WorkoutViewModel(repository: scenario.repository, snapshot: initial,
            timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "2026-10-06T20:00:00Z")! }, activatesExactPolicy: true)
        let probe = ResponsiveSaveProbe()
        await scenario.repository.observeCommits { probe.observe($0) }
        try await model.start(easierToday: false)
        XCTAssertEqual(model.snapshot.state.schemaVersion, 3)
        XCTAssertFalse(probe.savedOnMain, "Legacy Start must move policy activation off the MainActor too")
        XCTAssertGreaterThanOrEqual(probe.saveCount, 3)
        await scenario.repository.observeCommits(nil)
        await scenario.repository.close()
    }
    func testStartAndConfirmLoadKeepMainActorResponsiveDuringDurableSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try await TrainingRepository.openInBackground(at: root.appendingPathComponent("training.store"))
        let composition = AppComposition(repository: repository)
        composition.now = { Date(timeIntervalSince1970: 1791583200) }
        composition.timeZoneID = "Pacific/Honolulu"
        let probe = ResponsiveSaveProbe()
        await repository.observeCommits { probe.observe($0) }
        let confirmProgram = Task { @MainActor in await composition.confirm(choice: .upperBody, goal: .size) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(composition.busy)
        XCTAssertNil(composition.workout)
        await confirmProgram.value
        XCTAssertNil(composition.errorText)
        let model = try XCTUnwrap(composition.workout)
        let start = Task { @MainActor in await model.run { try await model.start(easierToday: false) } }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.busy, "The MainActor must run while the serial writer saves")
        XCTAssertNil(model.snapshot.draft, "Adoption waits for durable completion")
        await start.value
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.busy)
        let row = try XCTUnwrap(model.snapshot.draft?.displayed.exercises.first { model.movement(for: $0).loadingMode == .externalLoad })
        let load = try XCTUnwrap(model.movement(for: row).availableLoads.first)
        let confirm = Task { @MainActor in await model.run { try await model.confirmLoad(movementID: row.movementID, load: load) } }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.busy)
        XCTAssertNil(model.log(for: row.movementID)?.actualLoad)
        await confirm.value
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.log(for: row.movementID)?.actualLoad, load)
        XCTAssertFalse(probe.savedOnMain)
        XCTAssertGreaterThanOrEqual(probe.saveCount, 2)
        await repository.observeCommits(nil)
        await repository.close()
    }
}

private final class ResponsiveSaveProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var main = false
    var savedOnMain: Bool { lock.withLock { main } }
    var saveCount: Int { lock.withLock { count } }
    func observe(_ stage: String) {
        guard stage == "before_save" else { return }
        lock.withLock { count += 1; main = main || Thread.isMainThread }
        // A deterministic synthetic slow disk: verify rendering can run while the
        // sole writer is inside its synchronous transaction, without timing the CPU.
        Thread.sleep(forTimeInterval: 0.15)
    }
}

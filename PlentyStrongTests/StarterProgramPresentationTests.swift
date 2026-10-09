import XCTest
import TrainingCore
@testable import PlentyStrong

final class StarterProgramPresentationTests: XCTestCase {
    func testEitherEmphasisCanPairWithEveryGoal() throws {
        for choice in StarterProgramChoice.allCases {
            for goal in Goal.allCases {
                let details = try StarterProgramPresentation.details(choice: choice, goal: goal)
                XCTAssertEqual(details.title, choice == .upperBody ? "Upper-body emphasis" : "Whole-body, glute emphasis")
                XCTAssertFalse(details.equipment.isEmpty)
                XCTAssertFalse(details.coverageRows.isEmpty)
            }
        }
    }
    func testUpperCuesReuseOnlyExactConsultationMovementIDs() throws {
        let glutes = try StarterProgramPresentation.details(choice: .wholeBodyGlutes, goal: .size)
        let upper = try StarterProgramPresentation.details(choice: .upperBody, goal: .size)
        let shared = Set(["db_romanian_deadlift", "db_lateral_raise", "suitcase_db_squat"])
        XCTAssertEqual(Set(upper.cuesByMovementID.keys), shared)
        for id in shared { XCTAssertEqual(upper.cuesByMovementID[id], glutes.cuesByMovementID[id]) }
        for id in ["incline_db_press_24", "chest_supported_db_row_38_neutral", "incline_db_press_30", "chest_supported_db_row_30_neutral"] {
            XCTAssertNil(upper.cuesByMovementID[id], "Different angles and IDs cannot borrow consultation cues")
        }
    }
    func testProgramPreviewMatchesDoseAndHonestCoverage() throws {
        let glutes = try StarterProgramPresentation.details(choice: .wholeBodyGlutes, goal: .size)
        XCTAssertEqual(glutes.duration, "Allow about 45–65 minutes; your time may vary.")
        XCTAssertEqual(glutes.coverageRows.first?.initialWork, "4 bridge sets + 8 compound sets")
        XCTAssertEqual(glutes.coverageRows.first?.establishedWork, "4 bridge sets + 11 compound sets")
        XCTAssertEqual(glutes.cuesByMovementID["dead_bug_heel_tap"]?.first, "Maintain a comfortable, stable lower-back position while alternating controlled heel taps. Log repetitions per side.")
        XCTAssertTrue(glutes.limitations.contains { $0.contains("Do not add") })
        XCTAssertFalse(glutes.equipment.contains { $0.localizedCaseInsensitiveContains("pull-up") })
        let upper = try StarterProgramPresentation.details(choice: .upperBody, goal: .strength)
        XCTAssertTrue(upper.duration.isEmpty)
        XCTAssertTrue(upper.equipment.contains { $0.localizedCaseInsensitiveContains("pull-up") })
        XCTAssertTrue(upper.limitations.contains("Pull-ups and chin-ups need a setup you can perform comfortably. A bar alone may not be sufficient."))
        XCTAssertTrue(upper.limitations.contains { $0.contains("once a week") })
    }
}

extension StarterProgramPresentationTests {
    @MainActor func testBridgeAndStrengthChecksCreateOnlyTypedReviewedSetup() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let model = WorkoutViewModel(repository: s.repository, snapshot: s.initial, timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "2026-10-11T20:00:00Z")! })
        try await model.start(easierToday: false)
        let base = "db_floor_glute_bridge"
        let externalID = model.snapshot.state.config.activeVariantIDs![base]!
        try await model.selectBridgeLoadingMode(variantID: externalID, mode: .bodyweight)
        let bodyID = model.snapshot.state.config.activeVariantIDs![base]!
        XCTAssertNotEqual(bodyID, externalID)
        let bodyRow = try XCTUnwrap(model.snapshot.draft?.displayed.exercises.first { $0.movementID == bodyID })
        XCTAssertEqual(model.movement(for: bodyRow).loadingMode, .bodyweight)
        XCTAssertEqual(model.movement(for: bodyRow).implementCount, 0)
        XCTAssertTrue(model.movement(for: bodyRow).availableLoads.isEmpty)
        XCTAssertNil(bodyRow.load)
        try await model.selectBridgeLoadingMode(variantID: bodyID, mode: .externalLoad)
        XCTAssertEqual(model.snapshot.state.config.activeVariantIDs![base], externalID)
        let externalRow = try XCTUnwrap(model.snapshot.draft?.displayed.exercises.first { $0.movementID == externalID })
        XCTAssertEqual(model.movement(for: externalRow).loadingMode, .externalLoad)
        XCTAssertEqual(model.movement(for: externalRow).implementCount, 1)
        XCTAssertTrue(model.movement(for: externalRow).availableLoads.allSatisfy { $0.basis == .total })
        try await model.selectBridgeLoadingMode(variantID: externalID, mode: .bodyweight)
        XCTAssertEqual(model.snapshot.state.config.activeVariantIDs![base], bodyID)
        let modifiedID = UUID().uuidString.lowercased()
        try await model.changeSetup(.create(baseMovementID: base, variantID: modifiedID, modifications: "Future dumbbell setup description"))
        let modified = try XCTUnwrap(model.snapshot.draft?.displayed.exercises.first { $0.movementID == modifiedID })
        XCTAssertEqual(model.movement(for: modified).loadingMode, .bodyweight)
        try await model.recordSet(movementID: modifiedID, index: 0, actual: ActualSet(reps: 10))
        try await model.recordSet(movementID: modifiedID, index: 1, actual: ActualSet(reps: 10))
        try await model.recordEffort(movementID: modifiedID, effort: .onTarget)
        try await model.recordStatus(movementID: modifiedID, status: .completed)
        for row in model.snapshot.draft!.displayed.exercises where row.movementID != modifiedID { try await model.recordStatus(movementID: row.movementID, status: .skipped) }
        let receipt = try await model.finish()
        let recorded = try XCTUnwrap(receipt.snapshot.history.last)
        let issued = try XCTUnwrap(MovementPrescriptionSummary.issuedWorkout(envelope: recorded, history: receipt.snapshot.history))
        try await model.changeStarterProgram(choice: .upperBody, goal: .size)
        XCTAssertTrue(model.snapshot.history.contains(recorded))
        XCTAssertEqual(MovementPrescriptionSummary.effectiveMovement(state: issued.state, variantID: modifiedID)?.loadingMode, .bodyweight)
        XCTAssertNil(recorded.returnedState.exercises[modifiedID]?.load)
        XCTAssertEqual(MovementPrescriptionSummary.goal(modified, policy: issued.policy, repCounting: .total), "10 / 10 reps")
        await s.repository.close()

        let t = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .strength)
        let strength = WorkoutViewModel(repository: t.repository, snapshot: t.initial, timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "2026-10-11T20:00:00Z")! })
        try await strength.start(easierToday: false)
        let id = strength.snapshot.state.config.activeVariantIDs!["incline_db_press_30"]!
        let load = Load(amount: "15", unit: .lb, basis: .perImplement)
        XCTAssertTrue(strength.snapshot.draft!.displayed.exercises.first { $0.movementID == id }!.sets.isEmpty)
        let before = try await t.repository.exportBackup()
        await t.repository.failNextSave()
        do { try await strength.reviewStrengthHandling(variantID: id, choice: .lowRep(load: load)); XCTFail("Save failure must roll back first-load review") } catch {}
        let rolledBack = try await t.repository.exportBackup()
        XCTAssertEqual(rolledBack, before)
        try await strength.reviewStrengthHandling(variantID: id, choice: .lowRep(load: load))
        XCTAssertEqual(strength.snapshot.state.exercises[id]?.load, load)
        XCTAssertEqual(strength.snapshot.draft?.displayed.exercises.first { $0.movementID == id }?.sets.compactMap(\.targetReps), [4, 4])
        XCTAssertNil(strength.log(for: id)?.actualLoad)
        do { try await strength.confirmLoad(movementID: id, load: Load(amount: "20", unit: .lb, basis: .perImplement)); XCTFail("Different load must not admit low-rep work") } catch let error as EngineError { XCTAssertEqual(error.code, "handling_load_mismatch") }
        try await strength.confirmLoad(movementID: id, load: load)
        try await strength.reviewStrengthHandling(variantID: id, choice: .standardRange)
        XCTAssertEqual(strength.snapshot.draft?.displayed.exercises.first { $0.movementID == id }?.sets.compactMap(\.targetReps), [8, 8])
        try await strength.confirmLoad(movementID: id, load: Load(amount: "20", unit: .lb, basis: .perImplement))
        let saved = try await t.repository.exportBackup()
        _ = try BackupService.validate(saved)
        await t.repository.close()
        let reopened = try TrainingRepository.open(at: t.storeURL)
        let reopenedSnapshot = try await reopened.snapshot(programID: t.programID)
        XCTAssertEqual(reopenedSnapshot.state, strength.snapshot.state)
        await reopened.close()
    }
    @MainActor func testDraftAndFrozenFinishGuardSettingsAndRawSides() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let model = WorkoutViewModel(repository: s.repository, snapshot: s.initial, timeZoneID: "Pacific/Honolulu", now: { ISO8601DateFormatter().date(from: "2026-10-11T20:00:00Z")! })
        try await model.start(easierToday: false)
        XCTAssertFalse(model.canEditProgramSettings)
        do { try await model.changeStarterProgram(choice: .upperBody, goal: .size); XCTFail("Empty draft protects settings") } catch {}
        let row = model.snapshot.draft!.displayed.exercises.last!
        let raw = ActualSet(reps: 6, leftReps: 6, rightReps: nil)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: raw)
        XCTAssertEqual(model.log(for: row.movementID)?.actualSets.first?.leftReps, 6)
        XCTAssertNil(model.log(for: row.movementID)?.actualSets.first?.rightReps)
        do { try await model.selectBridgeLoadingMode(variantID: model.snapshot.state.config.activeVariantIDs!["db_floor_glute_bridge"]!, mode: .bodyweight); XCTFail("Working observations protect setup") } catch {}
        try await model.recordStatus(movementID: row.movementID, status: .partial)
        for other in model.snapshot.draft!.displayed.exercises where other.movementID != row.movementID { try await model.recordStatus(movementID: other.movementID, status: .skipped) }
        await s.repository.failNextSave()
        do { _ = try await model.finish(); XCTFail("Synthetic failure") } catch {}
        XCTAssertTrue(model.hasAmbiguousFinish)
        do { try await model.changeStarterProgram(choice: .upperBody, goal: .size); XCTFail("Frozen Finish protects program") } catch {}
        _ = try await model.finish()
        try await model.changeStarterProgram(choice: .upperBody, goal: .maintenance)
        XCTAssertEqual(model.completedEnvelope?.returnedState.config.profileID, "starter-glute-v1")
        XCTAssertEqual(model.completedEnvelope?.returnedState.config.goal, .size)
        await s.repository.close()
    }
}

extension StarterProgramPresentationTests {
    @MainActor func testRestoreKeepsStoredEmphasisWithoutCreatingAnotherProgram() async throws {
        let source = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .maintenance)
        let document = try await source.repository.exportBackup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = try TrainingRepository.open(at: root.appendingPathComponent("training.store"))
        let composition = AppComposition(repository: destination)
        _ = try await composition.restoreBackupData(BackupService.bytes(document))
        XCTAssertEqual(composition.workout?.snapshot.state.config.profileID, "starter-glute-v1")
        XCTAssertEqual(composition.workout?.snapshot.state.config.goal, .maintenance)
        let restored = try await destination.exportBackup()
        XCTAssertEqual(restored, document)
        await destination.close(); await source.repository.close()
    }
}

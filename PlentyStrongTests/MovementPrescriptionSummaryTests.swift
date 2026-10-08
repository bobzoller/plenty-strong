import XCTest
import TrainingCore
@testable import PlentyStrong

final class MovementPrescriptionSummaryTests: XCTestCase {
    private func envelope(state: ProgramState, command: JournalCommand, parent: JournalEnvelope? = nil) throws -> JournalEnvelope {
        var value = JournalEnvelope(schemaVersion: state.schemaVersion, datasetID: parent?.datasetID ?? UUID().uuidString, programID: state.config.programID, eventID: UUID().uuidString, eventHash: try BackupService.eventHash(command), parentEnvelopeHash: parent?.envelopeHash, inputRevision: parent?.returnedState.revision ?? -1, inputStateHash: try parent.map { try BackupService.hash($0.returnedState) }, rulesetVersion: state.rulesetVersion, rulesetHash: state.rulesetHash, profileID: state.config.profileID!, profileHash: state.config.profileHash!, sourceProfileID: state.config.sourceProfileID!, sourceProfileHash: state.config.sourceProfileHash!, command: command, returnedState: state, returnedPrescription: state.activePrescription, decisions: [], envelopeHash: "")
        value.envelopeHash = try BackupService.envelopeHash(value)
        return value
    }
    private func root(legacy: Bool = false, load: String = "40", date: String = "2026-10-01", slotID: String = "THU") throws -> JournalEnvelope {
        var config = try selectFixedProgram(goal: .size, programID: UUID())
        config.initialLoads["incline_db_press_24"] = Load(amount: load, unit: .lb, basis: .perImplement)
        let slot = WorkoutSlot(date: try LocalDate(iso8601: date), slotID: slotID)
        let initial = try initializeProgram(config: config, rules: legacy ? RulesetCatalog.fixedV1() : RulesetCatalog.exactV1(), firstWorkout: slot)
        return try envelope(state: initial.state, command: .initialize(config: config, firstWorkout: slot))
    }
    private func record(_ parent: JournalEnvelope, reps: [Int] = [10,10,9], nextDate: String, nextSlot: String, easier: Bool = false, status: LogStatus = .completed, movementIndex: Int = 0, rawSets: [ActualSet]? = nil, skipped: [Int] = []) throws -> JournalEnvelope {
        let rules = try RulesetCatalog.resolve(version: parent.rulesetVersion, hash: parent.rulesetHash)
        let displayed = try prepareWorkout(state: parent.returnedState, rules: rules, easierToday: easier)
        let exact = parent.schemaVersion == 3
        let logs = displayed.exercises.enumerated().map { index, row in
            ExerciseLog(movementID: row.movementID, prescriptionID: displayed.id, status: index == movementIndex ? status : .skipped, actualLoad: index == movementIndex ? row.load : nil,
                actualSets: index == movementIndex ? rawSets ?? reps.enumerated().map { ActualSet(reps: $0.element, setIndex: exact ? $0.offset : nil) } : [], finalEffort: index == movementIndex ? .onTarget : .unknown, problem: .none, baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot, effortScope: exact ? .allWorkingSets : nil, skippedSetIndices: exact ? (index == movementIndex ? skipped : []) : nil, mixedLoads: exact ? false : nil)
        }
        let event = CompletedWorkout(eventID: UUID().uuidString, date: displayed.date, slotID: displayed.slotID, prescriptionID: displayed.id, plannedPrescriptionID: parent.returnedPrescription.id, sessionMode: easier ? .easier : .normal, exercises: logs)
        let next = WorkoutSlot(date: try LocalDate(iso8601: nextDate), slotID: nextSlot)
        guard case let .applied(state, _, _) = advanceProgram(AdvanceInput(state: parent.returnedState, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)) else { throw EngineError(code: "test_fixture_rejected", field: "event") }
        return try envelope(state: state, command: .workout(completedWorkout: event, next: next), parent: parent)
    }
    func testLastPerformanceIsVariantSpecificAndRaw() throws {
        let initial = try root()
        let baseline = try record(initial, nextDate: "2026-10-04", nextSlot: "SUN")
        let last = try record(baseline, nextDate: "2026-10-08", nextSlot: "THU")
        let state = last.returnedState
        let row = state.activePrescription.exercises[0]
        let summary = MovementPrescriptionSummary.make(row: row, state: state, history: [initial, baseline, last], draft: nil)
        XCTAssertEqual(summary.prior?.actualSets.map(\.reps), [10,10,9])
        XCTAssertEqual(summary.targetReps, [10,10,10])
        XCTAssertEqual(summary.prior?.actualLoad?.amount, "40")
        XCTAssertTrue(summary.isPriorComparable)
        var sibling = row; sibling.movementID = "other-setup"
        XCTAssertNil(MovementPrescriptionSummary.make(row: sibling, state: state, history: [initial, baseline, last], draft: nil).prior)
        let foreign = try root()
        let foreignLast = try record(foreign, reps: [12,12,12], nextDate: "2026-10-08", nextSlot: "THU")
        XCTAssertEqual(MovementPrescriptionSummary.make(row: row, state: state, history: [initial, baseline, last, foreign, foreignLast], draft: nil).prior?.actualSets.map(\.reps), [10,10,9])
    }
    func testDifferentLoadAndLegacyStayContext() throws {
        let initial = try root(load: "50")
        let last = try record(initial, reps: [12,12,12], nextDate: "2026-10-08", nextSlot: "THU")
        var row = last.returnedPrescription.exercises[0]; row.load = Load(amount: "55", unit: .lb, basis: .perImplement)
        row.sets = row.sets.map { var s = $0; s.targetReps = 8; return s }
        let summary = MovementPrescriptionSummary.make(row: row, state: last.returnedState, history: [initial, last], draft: nil)
        XCTAssertEqual(summary.prior?.actualSets.map(\.reps), [12,12,12])
        XCTAssertEqual(summary.targetReps, [8,8,8]); XCTAssertFalse(summary.isPriorComparable)
        let old = try root(legacy: true)
        let oldLast = try record(old, nextDate: "2026-10-08", nextSlot: "THU")
        let legacy = MovementPrescriptionSummary.make(row: oldLast.returnedPrescription.exercises[0], state: oldLast.returnedState, history: [old, oldLast], draft: nil)
        XCTAssertEqual(legacy.prior?.actualSets.map(\.reps), [10,10,9])
        XCTAssertNil(legacy.targetReps); XCTAssertFalse(legacy.isPriorComparable)
    }
    func testPartialSidesAndEasierStayVisible() throws {
        let initial = try root(date: "2026-10-06", slotID: "TUE")
        let raw = [ActualSet(reps: 8, leftReps: 8, rightReps: nil, setIndex: 0), ActualSet(reps: 6, leftReps: 6, rightReps: 5, setIndex: 2)]
        let last = try record(initial, nextDate: "2026-10-13", nextSlot: "TUE", status: .partial, movementIndex: 2, rawSets: raw, skipped: [1])
        let summary = MovementPrescriptionSummary.make(row: last.returnedPrescription.exercises[2], state: last.returnedState, history: [initial, last], draft: nil)
        XCTAssertEqual(summary.prior?.actualSets, raw)
        XCTAssertEqual(summary.prior?.skippedSetIndices, [1])
        XCTAssertEqual(MovementPrescriptionSummary.reps(raw, repCounting: .perSide), "Set 1: left 8, right unrecorded; Set 3: left 6, right 5")
        XCTAssertFalse(summary.isPriorComparable)
        let normal = try root()
        let easier = try record(normal, reps: [8,8], nextDate: "2026-10-08", nextSlot: "THU", easier: true)
        let easierSummary = MovementPrescriptionSummary.make(row: easier.returnedPrescription.exercises[0], state: easier.returnedState, history: [normal, easier], draft: nil)
        XCTAssertEqual(easierSummary.prior?.sessionMode, .easier); XCTAssertEqual(easierSummary.prior?.phase, .easier)
        XCTAssertFalse(easierSummary.isPriorComparable)
    }
    func testMissingOrMismatchedIssuedReferencesKeepRawActuals() throws {
        let initial = try root(); let last = try record(initial, nextDate: "2026-10-08", nextSlot: "THU")
        XCTAssertNil(MovementPrescriptionSummary.issuedWorkout(envelope: last, history: [last]))
        var changed = last
        guard case let .workout(original, next) = last.command else { return XCTFail("workout") }
        for planned in [true, false] {
            var event = original
            if planned { event.plannedPrescriptionID = "wrong" } else { event.prescriptionID = "wrong" }
            changed.command = .workout(completedWorkout: event, next: next)
            XCTAssertNil(MovementPrescriptionSummary.issuedWorkout(envelope: changed, history: [initial, changed]))
            let summary = MovementPrescriptionSummary.make(row: last.returnedPrescription.exercises[0], state: last.returnedState, history: [initial, changed], draft: nil)
            XCTAssertEqual(summary.prior?.actualSets.map(\.reps), [10,10,9]); XCTAssertNil(summary.prior?.phase)
            XCTAssertFalse(summary.isPriorComparable)
        }
        changed.rulesetHash = "unavailable"
        XCTAssertNil(MovementPrescriptionSummary.issuedWorkout(envelope: changed, history: [initial, changed]))
    }
    func testReserveRestPositionAndSetupMustMatch() throws {
        let initial = try root(); let baseline = try record(initial, nextDate: "2026-10-04", nextSlot: "SUN")
        let last = try record(baseline, nextDate: "2026-10-08", nextSlot: "THU")
        let state = last.returnedState; let original = state.activePrescription.exercises[0]
        var row = original; row.restSeconds += 30
        XCTAssertFalse(MovementPrescriptionSummary.make(row: row, state: state, history: [initial, baseline, last], draft: nil).isPriorComparable)
        row = original; row.sets[0].effortInstruction = "stricter reserve"
        XCTAssertFalse(MovementPrescriptionSummary.make(row: row, state: state, history: [initial, baseline, last], draft: nil).isPriorComparable)
        var revised = state; revised.exercises[row.movementID]!.setupRevision! += 1
        XCTAssertFalse(MovementPrescriptionSummary.make(row: original, state: revised, history: [initial, baseline, last], draft: nil).isPriorComparable)
        var reordered = state; reordered.activePrescription.exercises.swapAt(0, 1)
        XCTAssertFalse(MovementPrescriptionSummary.make(row: original, state: reordered, history: [initial, baseline, last], draft: nil).isPriorComparable)
    }
    func testConfirmedChangedActualLoadDoesNotRelabelPriorAsComparable() throws {
        let initial = try root(); let baseline = try record(initial, nextDate: "2026-10-04", nextSlot: "SUN")
        let last = try record(baseline, nextDate: "2026-10-08", nextSlot: "THU")
        let state = last.returnedState; let prescription = state.activePrescription
        let logs = prescription.exercises.enumerated().map { index, row in
            ExerciseLog(movementID: row.movementID, prescriptionID: prescription.id, status: .partial, actualLoad: index == 0 ? Load(amount: "50", unit: .lb, basis: .perImplement) : nil, actualSets: [], finalEffort: .unknown, problem: .none, baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
        }
        let draft = WorkoutDraft(id: UUID(), programID: state.config.programID, expectedRevision: state.revision, planned: prescription, displayed: prescription, date: prescription.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal, logs: logs, workingSetsStarted: false)
        let summary = MovementPrescriptionSummary.make(row: prescription.exercises[0], state: state, history: [initial, baseline, last], draft: draft)
        XCTAssertEqual(summary.prescribedLoad?.amount, "40"); XCTAssertEqual(summary.actualLoad?.amount, "50")
        XCTAssertEqual(summary.targetReps, [10,10,10]); XCTAssertEqual(summary.actualSets, [])
        XCTAssertFalse(summary.isPriorComparable)
    }
    func testUnknownPolicyDoesNotFabricateGoals() throws {
        let initial = try root(); var state = initial.returnedState; state.schemaVersion = 99
        let summary = MovementPrescriptionSummary.make(row: state.activePrescription.exercises[0], state: state, history: [], draft: nil)
        XCTAssertNil(summary.policy); XCTAssertNil(summary.targetReps)
    }
    func testNoHistoryHasGoalsButNoActuals() throws {
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let initial = try initializeProgram(config: config, rules: RulesetCatalog.exactV1(), firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-08"), slotID: "THU"))
        let summary = MovementPrescriptionSummary.make(row: initial.workout.exercises[0], state: initial.state, history: [], draft: nil)
        XCTAssertEqual(summary.targetReps, [8, 8, 8])
        XCTAssertNil(summary.prior)
        XCTAssertEqual(summary.actualSets, [])
        XCTAssertFalse(summary.isPriorComparable)
        XCTAssertEqual(summary.policy, .fixedExactV1)
    }
}

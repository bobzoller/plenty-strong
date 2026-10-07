import Foundation
import Testing
@testable import TrainingCore

func configurationInput(base: String = "banded_pullups") throws -> (ProgramState, Ruleset, WorkoutSlot, String) {
    let input = try appInput(base: base, ceilingStreak: 1)
    let slot = WorkoutSlot(date: input.state.activePrescription.date, slotID: input.state.activePrescription.slotID)
    return (input.state, input.rules, slot, input.state.config.activeVariantIDs![base]!)
}

struct ConfigurationTests {
    @Test func F09SetupResetMatchesArchivedExpectationAndFullState() throws {
        var (state, rules, slot, id) = try configurationInput()
        let p = state.activePrescription.exercises.first { $0.movementID == id }!
        state.exercises[id]!.recentComparable = [Exposure(eventID: "historic-event", date: try slot.date.adding(days: -2),
            movementID: id, baseMovementID: "banded_pullups", modificationsSnapshot: p.modificationsSnapshot,
            load: nil, plannedSetCount: 3, repFloor: 8, repCeiling: 12, actualSets: Array(repeating: ActualSet(reps: 12), count: 3),
            effort: .onTarget, problem: .none, sessionMode: .normal, phase: .normal, loadingMode: .bodyweight, setupRevision: 1, repCounting: .total)]
        state.exercises[id]!.strainStreak = 1
        state.exercises[id]!.repCeiling = 16
        state.exercises[id]!.lastCompletedDate = try slot.date.adding(days: -2)
        state.processedEvents = ["historic-event": "immutable-hash"]
        let original = state
        var expected = state
        expected.exercises[id] = ExerciseState(load: nil, mode: .baseline, normalSets: 3,
            repFloor: 8, repCeiling: 12, ceilingStreak: 0, strainStreak: 0,
            lastCompletedDate: state.exercises[id]!.lastCompletedDate, nextSetOverride: nil,
            interruptedReturn: false, recentComparable: [], setupRevision: 2)
        expected.revision += 1
        expected.activePrescription = try FixtureCompiler.expectedWorkout(state: expected, date: slot.date, slotID: slot.slotID)
        let decision = try FixtureCompiler.expectedDecision(id: id, action: .baseline, rules: [], key: "setup_reset",
            before: state.exercises[id]!, after: expected.exercises[id]!)
        let result = try reconfigureProgram(state: state, change: .resetSetup(variantID: id), rules: rules, nextWorkout: slot)
        #expect(result.state == expected)
        guard case .object(let projection) = try fixedSourceExample("F09"),
              case .object(let actual) = try FixtureCompiler.canonical(result.state.exercises[id]!) else { Issue.record("Expected F09 objects"); return }
        for (field, value) in projection { #expect(actual[field] == value) }
        #expect(result.workout == expected.activePrescription)
        #expect(result.decisions == [decision])
        #expect(state == original)
    }

    @Test func stricterRestrictionRebuildsInstructionsAndCannotRelax() throws {
        let (state, rules, slot, id) = try configurationInput()
        let result = try reconfigureProgram(state: state, change: .minimumRir(baseMovementID: "banded_pullups", value: 5), rules: rules, nextWorkout: slot)
        #expect(result.state.config.movements == state.config.movements)
        #expect(result.state.baseSafety!["banded_pullups"]!.minimumRir == 5)
        #expect(result.state.exercises[id]!.mode == .baseline)
        #expect(result.workout.exercises.first { $0.movementID == id }!.sets.allSatisfy { $0.effortInstruction.contains("5 good reps") })
        #expect(try prepareWorkout(state: result.state, rules: rules) == result.workout)
        #expect(throws: EngineError.self) { try reconfigureProgram(state: result.state, change: .minimumRir(baseMovementID: "banded_pullups", value: 2), rules: rules, nextWorkout: slot) }
    }

    @Test func resetAndGoalNeverBypassPauseAndResumeRequiresClearance() throws {
        var (state, rules, slot, id) = try configurationInput()
        state.baseSafety!["banded_pullups"] = MovementSafetyState(paused: true, minimumRir: 5, sourceEventIDs: ["pain"])
        state.exercises[id]!.mode = .paused
        state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: slot.date, slotID: slot.slotID)
        for change in [ConfigurationChange.resetSetup(variantID: id), .goal(.strength)] {
            let result = try reconfigureProgram(state: state, change: change, rules: rules, nextWorkout: slot)
            #expect(result.state.baseSafety == state.baseSafety)
            #expect(result.state.exercises[id]!.mode == .paused)
            #expect(try prepareWorkout(state: result.state, rules: rules, easierToday: true).exercises.first { $0.movementID == id }!.sets.isEmpty)
        }
        #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: .safeResume(baseMovementID: "banded_pullups", externalClearanceConfirmed: false), rules: rules, nextWorkout: slot) }
        let result = try reconfigureProgram(state: state, change: .safeResume(baseMovementID: "banded_pullups", externalClearanceConfirmed: true), rules: rules, nextWorkout: slot)
        #expect(result.state.baseSafety!["banded_pullups"] == MovementSafetyState(paused: false, minimumRir: 5, sourceEventIDs: ["pain"]))
        #expect(result.state.exercises[id]!.mode == .baseline)
        #expect(result.state.exercises[id]!.ceilingStreak == 0)
        #expect(result.state.processedEvents == state.processedEvents)
    }

    @Test func unknownTargetsAndTamperedEquipmentReject() throws {
        let (state, rules, slot, _) = try configurationInput()
        for change in [ConfigurationChange.resetSetup(variantID: "unknown"), .minimumRir(baseMovementID: "unknown", value: 4), .safeResume(baseMovementID: "unknown", externalClearanceConfirmed: true)] {
            #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: change, rules: rules, nextWorkout: slot) }
        }
        var bad = state
        bad.config.movements[0].availableLoads.removeLast()
        #expect(throws: EngineError.self) { try reconfigureProgram(state: bad, change: .goal(.strength), rules: rules, nextWorkout: slot) }
    }
}

extension ConfigurationTests {
    @Test func existingLoadedSetupRetainsKnownLoadOnResetResumeAndGoalChange() throws {
        var (state, rules, slot, id) = try configurationInput(base: "incline_db_press_24")
        let load = Load(amount: "50", unit: .lb, basis: .perImplement)
        state.exercises[id]!.load = load
        state.exercises[id]!.repCeiling = 18
        state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: slot.date, slotID: slot.slotID)
        for change in [ConfigurationChange.resetSetup(variantID: id), .goal(.strength), .safeResume(baseMovementID: "incline_db_press_24", externalClearanceConfirmed: true)] {
            let result = try reconfigureProgram(state: state, change: change, rules: rules, nextWorkout: slot)
            #expect(result.state.exercises[id]!.load == load)
            #expect(result.state.exercises[id]!.mode == .baseline)
            #expect(result.state.exercises[id]!.repFloor == (change == .goal(.strength) ? 4 : 8))
            #expect(result.state.exercises[id]!.repCeiling == (change == .goal(.strength) ? 6 : 12))
        }
    }

    @Test func resettingInactiveVariantAffectsOnlyItsRevisionAndComparisons() throws {
        let (state, rules, slot, oldID) = try configurationInput()
        let created = try changeMovementVariant(state: state, change: .create(baseMovementID: "banded_pullups", variantID: "saved", modifications: "Grip"), rules: rules, nextWorkout: slot)
        let result = try reconfigureProgram(state: created.state, change: .resetSetup(variantID: oldID), rules: rules, nextWorkout: slot)
        #expect(result.state.exercises[oldID]!.setupRevision == 2)
        #expect(result.state.exercises[oldID]!.ceilingStreak == 0)
        #expect(result.state.exercises["saved"] == created.state.exercises["saved"])
        #expect(result.state.config == created.state.config)
        for id in state.exercises.keys where id != oldID { #expect(result.state.exercises[id] == created.state.exercises[id]) }
    }
}

import Foundation
import Testing
@testable import TrainingCore

struct PreparationTests {
    private let programID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Test func normalC41ReturnsExactActivePrescriptionWithoutMutation() throws {
        let (state, rules, easier) = try FixtureCompiler.prepareInput(caseID: "C41")
        let original = state
        #expect(!easier)
        // Independently calculated from source JSON with Python hashlib.
        #expect(state.activePrescription.id == "96937feb34f979870c2188f03a3f966543458ffeb5409a45fbf831f63035ff85")
        #expect(try prepareWorkout(state: state, rules: rules) == original.activePrescription)
        #expect(state == original)
        #expect(try FixtureCompiler.canonical(state) == FixtureCompiler.canonical(original))
    }

    @Test(arguments: ["C17", "C46", "C47"])
    func sourceEasierCasesMatchCompleteIndependentPrescriptions(caseID: String) throws {
        let (state, rules, easier) = try FixtureCompiler.prepareInput(caseID: caseID)
        let original = state
        let prepared = try prepareWorkout(state: state, rules: rules, easierToday: easier)
        #expect(try prepared == FixtureCompiler.expectedEasier(state: state, rules: rules))
        #expect(state == original)
        #expect(try FixtureCompiler.canonical(state) == FixtureCompiler.canonical(original))
        #expect(try prepared == prepareWorkout(state: state, rules: rules, easierToday: easier))
        #expect(prepared.exercises[0].load == original.activePrescription.exercises[0].load)
    }

    @Test func easierPreparationReducesDoseWithoutChangingState() throws {
        let (state, rules, _) = try FixtureCompiler.prepareInput(caseID: "C41")
        let original = state
        let easier = try prepareWorkout(state: state, rules: rules, easierToday: true)
        #expect(easier.id == "aae6c3369970c9312b9e97672977186c6e52902531e4a83a74dd793641eb7a12")
        #expect(easier.exercises[0].sets == Array(repeating: SetPrescription(repFloor: 0, repCeiling: 8,
            effortInstruction: "Stop with at least 4 good reps left; stop earlier for pain or loss of control."), count: 2))
        #expect(state == original)
        #expect(easier.exercises[0].load == state.activePrescription.exercises[0].load)
        #expect(easier != state.activePrescription)
    }

    @Test func genericTwoDaySizeC30RetainsFourSetsAndArchivedSchema() throws {
        let input = try FixtureCompiler.advanceInput(caseID: "C30")
        let result = try initializeProgram(config: input.state.config, rules: input.rules,
            firstWorkout: WorkoutSlot(date: input.state.activePrescription.date, slotID: "SUN"))
        #expect(result.state.schemaVersion == 1)
        #expect(result.state.baseSafety == nil)
        #expect(result.state.config.variants == nil)
        #expect(result.state.exercises["example_lift"]?.setupRevision == nil)
        #expect(result.workout.exercises[0].sets.count == 4)
        #expect(result.workout.exercises[0].restSeconds == 120)
        #expect(result.workout.exercises[0].sets.allSatisfy { $0.repFloor == 8 && $0.repCeiling == 12 })
        #expect(result.state.exercises["example_lift"]?.mode == .baseline)
        #expect(result.workout == result.state.activePrescription)
        #expect(try prepareWorkout(state: input.state, rules: input.rules) == input.state.activePrescription)
        #expect(throws: EngineError(code: "wrong_fixture_operation", field: "C30")) {
            try FixtureCompiler.prepareInput(caseID: "C30")
        }
    }

    @Test(arguments: Goal.allCases)
    func allFixedStatesStartAtBaselineWithCompleteSafety(goal: Goal) throws {
        let config = try selectFixedProgram(goal: goal, programID: programID)
        let original = config
        let rules = try RulesetCatalog.fixedV1()
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: "SUN")
        let initialized = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
        let state = initialized.state
        #expect(config == original)
        #expect(state.schemaVersion == 2)
        #expect(state.revision == 0 && state.lastSessionDate == nil && state.processedEvents.isEmpty)
        #expect(Set(state.exercises.keys) == Set(config.variants!.keys))
        #expect(state.exercises.count == 12 && state.baseSafety?.count == 12)
        let preset = try rules.preset(goal: goal, daysPerWeek: 3)
        for (id, exercise) in state.exercises {
            let base = config.variants![id]!.baseMovementID
            let movement = config.movements.first { $0.id == base }!
            let fallback = goal == .strength && !movement.lowRepLoadingAllowed
            #expect(exercise == ExerciseState(load: nil, mode: .baseline, normalSets: preset.normalSets,
                repFloor: fallback ? 8 : preset.repFloor, repCeiling: fallback ? 12 : preset.repCeiling,
                ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil,
                interruptedReturn: false, recentComparable: [], setupRevision: 1))
            #expect(state.baseSafety?[base] == MovementSafetyState(paused: false, minimumRir: 2, sourceEventIDs: []))
        }
        var expected = WorkoutPrescription(id: "", date: slot.date, slotID: slot.slotID, exercises: [])
        for base in config.weeklySlots[0].movementIDs {
            let id = config.activeVariantIDs![base]!
            let movement = config.movements.first { $0.id == base }!
            let exercise = state.exercises[id]!
            expected.exercises.append(ExercisePrescription(movementID: id,
                kind: movement.loadingMode == .externalLoad ? .baselineSetup : .working,
                phase: .baseline, load: nil, sets: Array(repeating: SetPrescription(repFloor: exercise.repFloor,
                    repCeiling: exercise.repCeiling, effortInstruction: "Stop when you think you could do two more good reps. Stop earlier for pain or loss of control."), count: preset.normalSets),
                restSeconds: preset.restSeconds, stopInstruction: try rules.resolvedParameters.stopInstruction,
                baseMovementID: base, modificationsSnapshot: ""))
        }
        expected.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(expected))
        #expect(initialized.workout == expected)
        #expect(state.activePrescription == expected)
        #expect(try initializeProgram(config: config, rules: rules, firstWorkout: slot) == initialized)
    }

    @Test func initialInactiveVariantsAreIndependentAndSelectedDescriptionIsSnapshotted() throws {
        var config = try selectFixedProgram(goal: .size, programID: programID)
        let base = "banded_pullups"
        config.variants?["saved"] = MovementVariant(id: "saved", baseMovementID: base, modifications: "+25 lb")
        config.activeVariantIDs?[base] = "saved"
        let initialized = try initializeProgram(config: config, rules: RulesetCatalog.fixedV1(),
            firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-04"), slotID: "SUN"))
        #expect(initialized.state.exercises.count == 13)
        #expect(initialized.state.exercises["saved"] == initialized.state.exercises[try defaultVariantID(programID: config.programID, baseMovementID: base)])
        let prescription = initialized.workout.exercises.first { $0.baseMovementID == base }!
        #expect(prescription.movementID == "saved" && prescription.modificationsSnapshot == "+25 lb")
        #expect(prescription.load == nil && prescription.kind == .working)
    }

    @Test func fixedF08EasierBodyweightDoseKeepsNullLoadAndSnapshots() throws {
        let config = try selectFixedProgram(goal: .size, programID: programID)
        let rules = try RulesetCatalog.fixedV1()
        let initialized = try initializeProgram(config: config, rules: rules,
            firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-06"), slotID: "TUE"))
        let original = initialized.state
        let easier = try prepareWorkout(state: original, rules: rules, easierToday: true)
        #expect(try easier == FixtureCompiler.expectedEasier(state: original, rules: rules))
        let exercise = easier.exercises.first { $0.baseMovementID == "bent_knee_hanging_leg_raise_ab_straps" }!
        #expect(exercise.load == nil && exercise.sets.count == 2 && exercise.phase == .easier)
        #expect(exercise.sets.allSatisfy { $0.repFloor == 0 && $0.repCeiling == 8 && $0.effortInstruction == "Stop with at least 4 good reps left; stop earlier for pain or loss of control." })
        #expect(exercise.modificationsSnapshot == "")
        #expect(initialized.state == original)
    }

    @Test func easierCapsCurrentDoseAndCeilingPreservesOverridesAndUnknownLoad() throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C43")
        input.state.activePrescription.exercises[0].sets = [SetPrescription(repFloor: 4, repCeiling: 5,
            effortInstruction: "Stop with roughly two good reps left; stop earlier for pain or loss of control.")]
        input.state.activePrescription.exercises[0].load = nil
        input.state.activePrescription.exercises[0].kind = .baselineSetup
        input.state.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(input.state.activePrescription))
        let original = input.state
        let easier = try prepareWorkout(state: input.state, rules: input.rules, easierToday: true)
        #expect(try easier == FixtureCompiler.expectedEasier(state: input.state, rules: input.rules))
        #expect(easier.exercises[0].sets.count == 1 && easier.exercises[0].sets[0].repCeiling == 5)
        #expect(easier.exercises[0].load == nil && easier.exercises[0].kind == .baselineSetup)
        #expect(input.state == original)
        #expect(input.state.exercises["example_lift"]?.nextSetOverride == 2)
        #expect(input.state.exercises["example_lift"]?.interruptedReturn == true)
    }

    @Test func mismatchedRulesAndHashRejectWithoutMutation() throws {
        let (state, rules, _) = try FixtureCompiler.prepareInput(caseID: "C41")
        for mutation in [
            { (s: inout ProgramState) in s.rulesetHash = "bad" },
            { (s: inout ProgramState) in s.rulesetVersion = "unknown" },
            { (s: inout ProgramState) in s.activePrescription.id = "bad" }
        ] {
            var invalid = state
            mutation(&invalid)
            let original = invalid
            #expect(throws: EngineError.self) { try prepareWorkout(state: invalid, rules: rules) }
            #expect(throws: EngineError.self) { try prepareWorkout(state: invalid, rules: rules, easierToday: true) }
            #expect(invalid == original)
        }
        var invalidRules = rules
        invalidRules.hash = "bad"
        #expect(throws: EngineError.self) { try prepareWorkout(state: state, rules: invalidRules) }
    }

    @Test func compilerRetainsInvalidReferencesAndReplayRelationships() throws {
        let stale = try FixtureCompiler.advanceInput(caseID: "C32")
        #expect(stale.event.prescriptionID == "stale")
        let mismatch = try FixtureCompiler.advanceInput(caseID: "C44")
        #expect(mismatch.event.prescriptionID == "wrong-derived-id")
        #expect(mismatch.event.exercises[0].prescriptionID != mismatch.event.prescriptionID)
        let replay = try FixtureCompiler.advanceInput(caseID: "C20")
        let conflict = try FixtureCompiler.advanceInput(caseID: "C21")
        #expect(try replay.state.processedEvents[replay.event.eventID] == CanonicalJSON.sha256(FixtureCompiler.canonical(replay.event)))
        #expect(try conflict.state.processedEvents[conflict.event.eventID] != CanonicalJSON.sha256(FixtureCompiler.canonical(conflict.event)))
        #expect(try FixtureCompiler.advanceInput(caseID: "C18").event.prescriptionID == FixtureCompiler.expectedEasier(state: FixtureCompiler.advanceInput(caseID: "C18").state, rules: replay.rules).id)
        #expect(throws: EngineError.self) { try FixtureCompiler.advanceInput(caseID: "C17") }
        #expect(throws: EngineError.self) { try FixtureCompiler.prepareInput(caseID: "unknown") }
        #expect(FixtureCompiler.merge(.object(["array": .array([.integer(1)]), "object": .object(["a": .integer(1)])]),
            .object(["array": .array([]), "object": .object(["b": .null])])) ==
            .object(["array": .array([]), "object": .object(["a": .integer(1), "b": .null])]))
    }

    @Test func compilerExpandsEveryIndependentSourceCaseThroughItsDeclaredAPI() throws {
        let preparationCases = ["C17", "C41", "C46", "C47"]
        for number in 1...47 {
            let id = String(format: "C%02d", number)
            if preparationCases.contains(id) {
                let (state, _, _) = try FixtureCompiler.prepareInput(caseID: id)
                #expect(state.schemaVersion == 1 && state.config.variants == nil && state.baseSafety == nil)
            } else {
                let input = try FixtureCompiler.advanceInput(caseID: id)
                #expect(input.state.schemaVersion == 1 && input.state.config.variants == nil && input.state.baseSafety == nil)
            }
        }
    }

    @Test func stricterSharedSafetyCannotBeBypassedByRehashingOldInstructions() throws {
        let config = try selectFixedProgram(goal: .size, programID: programID)
        let rules = try RulesetCatalog.fixedV1()
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: "SUN")
        var state = try initializeProgram(config: config, rules: rules, firstWorkout: slot).state
        let base = "banded_pullups"
        state.baseSafety?[base]?.minimumRir = 5
        let original = state
        #expect(throws: EngineError.self) { try prepareWorkout(state: state, rules: rules) }
        #expect(throws: EngineError.self) { try prepareWorkout(state: state, rules: rules, easierToday: true) }
        #expect(state == original)
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        let prepared = try prepareWorkout(state: state, rules: rules, easierToday: true)
        #expect(try prepared == FixtureCompiler.expectedEasier(state: state, rules: rules))
        #expect(prepared.exercises.first { $0.baseMovementID == base }!.sets.allSatisfy {
            $0.effortInstruction == "Stop with at least 5 good reps left; stop earlier for pain or loss of control."
        })
        state.baseSafety?[base]?.paused = true
        #expect(throws: EngineError.self) { try prepareWorkout(state: state, rules: rules, easierToday: true) }
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        let pausedOriginal = state
        let paused = try prepareWorkout(state: state, rules: rules, easierToday: true)
        #expect(paused.exercises.first { $0.baseMovementID == base } == state.activePrescription.exercises.first { $0.baseMovementID == base })
        #expect(paused.exercises.first { $0.baseMovementID == base }!.sets.isEmpty)
        #expect(state == pausedOriginal)
    }

    @Test func incompleteAppVariantStateOrSnapshotsRejectWithoutMutation() throws {
        let config = try selectFixedProgram(goal: .size, programID: programID)
        let rules = try RulesetCatalog.fixedV1()
        let state = try initializeProgram(config: config, rules: rules,
            firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-04"), slotID: "SUN")).state
        for mutate in [
            { (s: inout ProgramState) in _ = s.exercises.removeValue(forKey: s.config.activeVariantIDs!["db_romanian_deadlift"]!) },
            { (s: inout ProgramState) in _ = s.baseSafety?.removeValue(forKey: "db_romanian_deadlift") },
            { (s: inout ProgramState) in s.activePrescription.exercises[0].baseMovementID = nil },
            { (s: inout ProgramState) in s.activePrescription.exercises[0].modificationsSnapshot = "invented" },
            { (s: inout ProgramState) in s.schemaVersion = 1 }
        ] {
            var invalid = state
            mutate(&invalid)
            invalid.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(invalid.activePrescription))
            let original = invalid
            #expect(throws: EngineError.self) { try prepareWorkout(state: invalid, rules: rules) }
            #expect(throws: EngineError.self) { try prepareWorkout(state: invalid, rules: rules, easierToday: true) }
            #expect(invalid == original)
        }
    }

    @Test func suppliedDefaultLoadDoesNotSeedNewSavedSetupAndBadInitialSlotRejects() throws {
        var config = try selectFixedProgram(goal: .size, programID: programID)
        let rules = try RulesetCatalog.fixedV1()
        let base = config.movements[0].id
        let initial = config.movements[0].availableLoads[0]
        config.initialLoads[base] = initial
        config.variants?["saved-external"] = MovementVariant(id: "saved-external", baseMovementID: base, modifications: "Different bench setting")
        config.activeVariantIDs?[base] = "saved-external"
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: "SUN")
        let initialized = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
        #expect(initialized.state.exercises[try defaultVariantID(programID: config.programID, baseMovementID: base)]?.load == initial)
        #expect(initialized.state.exercises["saved-external"]?.load == nil)
        #expect(initialized.workout.exercises[0].kind == .baselineSetup && initialized.workout.exercises[0].load == nil)
        let original = config
        #expect(throws: EngineError.self) {
            try initializeProgram(config: config, rules: rules,
                firstWorkout: WorkoutSlot(date: slot.date, slotID: "UNKNOWN"))
        }
        #expect(config == original)
    }
}

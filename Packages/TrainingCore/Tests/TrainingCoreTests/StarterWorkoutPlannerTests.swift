import Foundation
import Testing
@testable import TrainingCore

struct StarterWorkoutPlannerTests {
    let slot = WorkoutSlot(date: try! LocalDate(iso8601: "2026-10-11"), slotID: "SUN")

    func initial(_ choice: StarterProgramChoice = .wholeBodyGlutes, _ goal: Goal = .size) throws -> (ProgramState, Ruleset) {
        let rules = try RulesetCatalog.starter(choice)
        let config = try selectStarterProgram(choice: choice, goal: goal, programID: UUID())
        return (try initializeProgram(config: config, rules: rules, firstWorkout: slot).state, rules)
    }

    @Test func introSizeHasTwoSetsAndHeterogeneousRangesAndRest() throws {
        let (state, rules) = try initial()
        #expect(state.schemaVersion == 4)
        #expect(state.activePrescription.exercises.reduce(0) { $0 + $1.sets.count } == 12)
        let expected: [String: (Int, Int, Int)] = [
            "db_romanian_deadlift": (8, 12, 120), "incline_db_press_30": (8, 12, 120),
            "chest_supported_db_row_30_neutral": (8, 12, 120), "db_floor_glute_bridge": (10, 15, 120),
            "supported_single_leg_calf_raise": (10, 15, 90), "dead_bug_heel_tap": (6, 10, 60)]
        for row in state.activePrescription.exercises {
            let dose = expected[row.baseMovementID!]!
            #expect(row.sets.compactMap(\.targetReps) == [dose.0, dose.0])
            #expect(row.sets.allSatisfy { $0.repFloor == dose.0 && $0.repCeiling == dose.1 })
            #expect(row.restSeconds == dose.2)
        }
        #expect(try prepareWorkout(state: state, rules: rules) == state.activePrescription)
        for goal in Goal.allCases {
            let (other, r) = try initial(.wholeBodyGlutes, goal)
            for weekly in other.config.weeklySlots {
                let date = try slot.date.adding(days: weekly.weekday!)
                let workout = try plannedWorkout(state: other, rules: r, slot: WorkoutSlot(date: date, slotID: weekly.id))
                #expect(workout.exercises.count == 6)
                #expect(other.exercises.values.allSatisfy { $0.normalSets == 2 })
                #expect(other.exercises.values.allSatisfy { $0.ceilingStreak == 0 && $0.strainStreak == 0 && $0.recentComparable.isEmpty && $0.exactRepState?.shortfallStreak == 0 })
            }
        }
    }

    @Test func strengthHandlingReviewEmitsNoWorkingSetsUntilExplicitChoice() throws {
        var (state, rules) = try initial(.wholeBodyGlutes, .strength)
        for base in ["incline_db_press_30", "chest_supported_db_row_30_neutral", "suitcase_db_squat"] {
            let activeSlot = base == "suitcase_db_squat" ? WorkoutSlot(date: try slot.date.adding(days: 4), slotID: "THU") : slot
            let id = state.config.activeVariantIDs![base]!
            let load = state.config.movements.first { $0.id == base }!.availableLoads[3]
            state.exercises[id]!.load = load
            state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: activeSlot)
            let unreviewed = try #require(state.activePrescription.exercises.first { $0.movementID == id })
            #expect(unreviewed.kind == .setupReview && unreviewed.sets.isEmpty)
            let standard = try reconfigureProgram(state: state, change: .reviewStrengthHandling(variantID: id, choice: .standardRange), rules: rules, nextWorkout: activeSlot)
            #expect(standard.state.exercises[id]!.repFloor == 8)
            #expect(standard.state.exercises[id]!.repCeiling == 12)
            let standardRow = try #require(standard.workout.exercises.first { $0.movementID == id })
            #expect(standardRow.kind == .working && standardRow.sets.compactMap(\.targetReps) == [8, 8])
            #expect(standardRow.restSeconds == 180)
            let confirmed = try reconfigureProgram(state: standard.state, change: .reviewStrengthHandling(variantID: id, choice: .lowRep(load: load)), rules: rules, nextWorkout: activeSlot)
            #expect(confirmed.state.exercises[id]!.repFloor == 4)
            #expect(confirmed.state.exercises[id]!.repCeiling == 6)
            let lowRow = try #require(confirmed.workout.exercises.first { $0.movementID == id })
            #expect(lowRow.kind == .working && lowRow.sets.compactMap(\.targetReps) == [4, 4])
            #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: .reviewStrengthHandling(variantID: id, choice: .lowRep(load: Load(amount: "25", unit: .lb, basis: .perImplement))), rules: rules, nextWorkout: activeSlot) }
            let reset = try reconfigureProgram(state: confirmed.state, change: .resetSetup(variantID: id), rules: rules, nextWorkout: activeSlot)
            #expect(reset.state.exercises[id]!.starterState!.strengthHandling == nil)
            #expect(reset.state.exercises[id]!.starterState!.windows.isEmpty)
            #expect(reset.workout.exercises.first { $0.movementID == id }!.kind == .setupReview)
            var changed = confirmed.state
            changed.exercises[id]!.load = state.config.movements.first { $0.id == base }!.availableLoads[4]
            changed.activePrescription = try plannedWorkout(state: changed, rules: rules, slot: activeSlot)
            let changedRow = try #require(changed.activePrescription.exercises.first { $0.movementID == id })
            #expect(changedRow.kind == .setupReview && changedRow.sets.isEmpty)
            try validateStarterProgram(state: changed, rules: rules)
        }
        let rdl = state.activePrescription.exercises.first { $0.baseMovementID == "db_romanian_deadlift" }!
        #expect(rdl.sets.map(\.repFloor) == [6, 6] && rdl.restSeconds == 180)
    }

    @Test func bodyweightBridgeIsTypedIndependentVariant() throws {
        var (state, rules) = try initial()
        let base = "db_floor_glute_bridge", originalID = state.config.activeVariantIDs!["db_floor_glute_bridge"]!
        state.exercises[originalID]!.load = Load(amount: "40", unit: .lb, basis: .total)
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        let result = try changeMovementVariant(state: state, change: .createLoadingMode(baseMovementID: base, variantID: "bodyweight", modifications: "", mode: .bodyweight), rules: rules, nextWorkout: slot)
        let effective = try resolveEffectiveMovement(config: result.state.config, variantID: "bodyweight", rules: rules)
        #expect(effective.loadingMode == .bodyweight && effective.implementCount == 0)
        #expect(effective.availableLoads.isEmpty && !effective.automaticLoadProgressionAllowed)
        #expect(result.state.exercises["bodyweight"]!.load == nil && result.state.exercises["bodyweight"]!.mode == .baseline)
        #expect(result.state.exercises[originalID] == state.exercises[originalID])
        let text = try changeMovementVariant(state: result.state, change: .create(baseMovementID: base, variantID: "text", modifications: "Use 40 lb dumbbell"), rules: rules, nextWorkout: slot)
        #expect(text.state.config.variants!["text"]!.loadingModeOverride == .bodyweight)
        let corrected = try changeMovementVariant(state: text.state, change: .correctDescription(variantID: "text", modifications: "Use 60 lb"), rules: rules, nextWorkout: slot)
        #expect(corrected.state.config.variants!["text"]!.loadingModeOverride == .bodyweight)
        let external = try changeMovementVariant(state: corrected.state, change: .select(baseMovementID: base, variantID: originalID), rules: rules, nextWorkout: slot)
        let numeric = try resolveEffectiveMovement(config: external.state.config, variantID: originalID, rules: rules)
        #expect(numeric.implementCount == 1 && numeric.availableLoads.allSatisfy { $0.basis == .total })
        #expect(external.state.exercises[originalID]!.load == Load(amount: "40", unit: .lb, basis: .total))
        var returnedState = result.state
        returnedState.exercises["bodyweight"]!.mode = .normal
        returnedState.exercises["bodyweight"]!.exactRepState!.lastSuitableNormalDate = try slot.date.adding(days: -28)
        returnedState.activePrescription = try plannedWorkout(state: returnedState, rules: rules, slot: slot)
        let returned = try prepareInterruptedReturn(state: returnedState, asOf: slot.date, rules: rules)
        #expect(returned.state.exercises["bodyweight"]!.load == nil)
        #expect(returned.workout.exercises.first { $0.movementID == "bodyweight" }!.sets.compactMap(\.targetReps) == [10])
        for wrongBase in ["db_romanian_deadlift", "dead_bug_heel_tap"] {
            #expect(throws: EngineError.self) { try changeMovementVariant(state: state, change: .createLoadingMode(baseMovementID: wrongBase, variantID: "bad", modifications: "x", mode: .bodyweight), rules: rules, nextWorkout: slot) }
        }
        #expect(throws: EngineError.self) { try changeMovementVariant(state: state, change: .createLoadingMode(baseMovementID: base, variantID: "bad", modifications: "x", mode: .externalLoad), rules: rules, nextWorkout: slot) }
    }

    @Test func unilateralMissingAndUnequalSidesRemainRaw() throws {
        let (state, rules) = try initial()
        let row = state.activePrescription.exercises.last!
        for sides in [(7, Optional<Int>.none), (8, Optional(6))] {
            let raw = [ActualSet(reps: sides.0, leftReps: sides.0, rightReps: sides.1, setIndex: 0), ActualSet(reps: 6, leftReps: 6, rightReps: 6, setIndex: 1)]
            let log = ExerciseLog(movementID: row.movementID, prescriptionID: state.activePrescription.id, status: .completed, actualLoad: nil, actualSets: raw, finalEffort: .onTarget, problem: .none, baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
            try validateIndexedExactLog(log, prescription: row)
            let context = try exactContext(state: state, id: row.movementID, prescription: row, position: 5, actualLoad: nil, rules: rules)
            let classification = try ExactExposureClassifier.classify(log: log, prescription: row, movement: state.config.movements.last { $0.id == row.baseMovementID }!, state: state.exercises[row.movementID]!, context: context)
            #expect(!classification.equalSides && !classification.cleanKnown)
            #expect(log.actualSets == raw)
            let decoded = try JSONDecoder().decode(ExerciseLog.self, from: JSONEncoder().encode(log))
            #expect(decoded.actualSets == raw)
        }
    }

    @Test func easierAndReturnUseEachMovementFloorAndReserve() throws {
        var (state, rules) = try initial()
        for id in state.exercises.keys { state.exercises[id]!.exactRepState!.normalTargets = Array(repeating: state.exercises[id]!.repFloor + 1, count: 2) }
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        let normal = state.exercises
        let easier = try prepareWorkout(state: state, rules: rules, easierToday: true)
        for row in easier.exercises {
            #expect(row.sets.count == 1)
            #expect(row.sets.first!.targetReps == state.exercises[row.movementID]!.repFloor)
            #expect(row.sets.first!.effortInstruction.contains("at least 4"))
        }
        #expect(state.exercises == normal)
        for id in state.exercises.keys {
            state.exercises[id]!.mode = .normal
            state.exercises[id]!.exactRepState!.lastSuitableNormalDate = try slot.date.adding(days: -28)
        }
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        let returned = try prepareInterruptedReturn(state: state, asOf: slot.date, rules: rules)
        for row in returned.workout.exercises {
            #expect(row.phase == .returning && row.sets.count == 1)
            #expect(row.sets.first!.targetReps == returned.state.exercises[row.movementID]!.repFloor)
            #expect(row.sets.first!.effortInstruction.contains("at least 4"))
        }
        for id in state.exercises.keys { #expect(returned.state.exercises[id]!.exactRepState!.normalTargets == state.exercises[id]!.exactRepState!.normalTargets) }
    }

    @Test func goalAndSetupChangesResolveTheirNewDoseAndSafety() throws {
        var (state, rules) = try initial()
        let base = "db_floor_glute_bridge", id = state.config.activeVariantIDs!["db_floor_glute_bridge"]!
        let family = rules.safetyFamilies![base]!
        #expect(state.retainedSafety![family] == state.baseSafety![base])
        let restricted = try reconfigureProgram(state: state, change: .minimumRir(baseMovementID: base, value: 5), rules: rules, nextWorkout: slot)
        #expect(restricted.state.retainedSafety![family]!.minimumRir == 5)
        #expect(throws: EngineError.self) { try reconfigureProgram(state: restricted.state, change: .minimumRir(baseMovementID: base, value: 2), rules: rules, nextWorkout: slot) }
        state = restricted.state
        state.baseSafety![base]!.paused = true
        state.retainedSafety![family]!.paused = true
        state.exercises[id]!.mode = .paused
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: .safeResume(baseMovementID: base, externalClearanceConfirmed: false), rules: rules, nextWorkout: slot) }
        let resumed = try reconfigureProgram(state: state, change: .safeResume(baseMovementID: base, externalClearanceConfirmed: true), rules: rules, nextWorkout: slot)
        #expect(!resumed.state.retainedSafety![family]!.paused && resumed.state.retainedSafety![family]!.minimumRir == 5)
        for goal in Goal.allCases {
            let changed = try reconfigureProgram(state: resumed.state, change: .goal(goal), rules: rules, nextWorkout: slot)
            #expect(changed.state.exercises[id]!.normalSets == 2 && changed.state.exercises[id]!.repFloor == 10)
            #expect(changed.state.baseSafety![base]!.minimumRir == 5)
            try validateStarterProgram(state: changed.state, rules: rules)
        }
        let setup = try reconfigureProgram(state: resumed.state, change: .resetSetup(variantID: id), rules: rules, nextWorkout: slot)
        #expect(setup.state.exercises[id]!.setupRevision == 2)
        #expect(setup.state.exercises[id]!.exactRepState!.normalTargets == [10, 10])
    }

    @Test func upperStarterRetainsLegacyWorkingDoseForEveryGoal() throws {
        for goal in Goal.allCases {
            let (state, rules) = try initial(.upperBody, goal)
            let config = try selectFixedProgram(goal: goal, programID: UUID(uuidString: state.config.programID)!)
            let old = try initializeProgram(config: config, rules: RulesetCatalog.exactV1(), firstWorkout: slot)
            #expect(state.activePrescription == old.workout)
            for id in state.exercises.keys {
                var exercise = state.exercises[id]!
                exercise.starterState = nil
                #expect(exercise == old.state.exercises[id])
            }
            try validateStarterProgram(state: state, rules: rules)
            #expect(state.activePrescription.exercises.allSatisfy { $0.kind != .setupReview })
        }
    }

    @Test func strictAdmissionRejectsCorruptDoseCountersSafetyAndPrescription() throws {
        let (state, rules) = try initial()
        let id = state.activePrescription.exercises.first!.movementID
        var mutations: [ProgramState] = []
        var bad = state; bad.exercises[id]!.normalSets = 0; mutations.append(bad)
        bad = state; bad.exercises[id]!.normalSets = 3; mutations.append(bad)
        bad = state; bad.exercises[id]!.repFloor = 4; mutations.append(bad)
        bad = state; bad.exercises[id]!.ceilingStreak = 1; mutations.append(bad)
        bad = state; bad.exercises[id]!.exactRepState!.shortfallStreak = 1; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.doseStage = .fixed; mutations.append(bad)
        bad = state; bad.retainedSafety = [:]; mutations.append(bad)
        bad = state; bad.exercises[id]!.load = Load(amount: "17", unit: .lb, basis: .perImplement); mutations.append(bad)
        bad = state; bad.activePrescription.exercises[0].sets[0].targetReps = 99; mutations.append(bad)
        for mutation in mutations { #expect(throws: EngineError.self) { try validateStarterProgram(state: mutation, rules: rules) } }
    }

    func normalRowWithWindows() throws -> (ProgramState, Ruleset, String) {
        var (state, rules) = try initial()
        let base = "chest_supported_db_row_30_neutral", id = state.config.activeVariantIDs!["chest_supported_db_row_30_neutral"]!
        state.exercises[id]!.load = state.config.movements.first { $0.id == base }!.availableLoads[3]
        let prior = try slot.date.adding(days: -7)
        state.lastSessionDate = prior
        state.exercises[id]!.lastCompletedDate = prior
        state.exercises[id]!.exactRepState!.lastSuitableNormalDate = prior
        state.exercises[id]!.mode = .normal
        for weekly in state.config.weeklySlots {
            let date = try slot.date.adding(days: weekly.weekday!)
            let workout = try plannedWorkout(state: state, rules: rules, slot: WorkoutSlot(date: date, slotID: weekly.id))
            let position = weekly.movementIDs.firstIndex(of: base)!
            let row = workout.exercises[position]
            let context = try exactContext(state: state, id: id, prescription: row, position: position, actualLoad: row.load, rules: rules)
            let preceding = weekly.movementIDs.prefix(position).map { StarterPrecedingMovement(baseMovementID: $0, normalSetCount: 2) }
            let key = try starterComparisonKey(profileHash: state.config.profileHash!, slotID: weekly.id, context: context, precedingDose: preceding)
            let raw = row.sets.enumerated().map { ActualSet(reps: $0.element.targetReps!, setIndex: $0.offset) }
            let log = ExerciseLog(movementID: id, prescriptionID: workout.id, status: .completed, actualLoad: row.load, actualSets: raw, finalEffort: .onTarget, problem: .none, baseMovementID: base, modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
            let event = CompletedWorkout(eventID: weekly.id, date: try prior.adding(days: weekly.weekday! - 7), slotID: weekly.id, prescriptionID: workout.id, plannedPrescriptionID: workout.id, sessionMode: .normal, exercises: [log])
            let exposure = exactObservation(event: event, log: log, prescription: row, movement: state.config.movements.first { $0.id == base }!, context: context)
            state.exercises[id]!.starterState!.windows[key] = StarterComparisonWindow(slotID: weekly.id, contextKey: key, context: context, precedingDose: preceding, ceilingStreak: 0, strainStreak: 0, shortfallStreak: 0, introStreak: 1, exposures: [exposure])
        }
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        try validateStarterProgram(state: state, rules: rules)
        return (state, rules, id)
    }

    @Test func returningSetOverrideCannotRetainNormalWindowCredit() throws {
        var (state, rules, id) = try normalRowWithWindows()
        state.exercises[id]!.nextSetOverride = 1
        #expect(!state.exercises[id]!.interruptedReturn)
        #expect(state.exercises[id]!.starterState!.windows.values.allSatisfy { $0.introStreak == 1 })
        // Render the exact returning prescription from the coherent no-credit state.
        // Copying it back proves rejection comes from retained evidence, not a stale ID.
        var withoutCredit = state
        withoutCredit.exercises[id]!.starterState!.windows = [:]
        withoutCredit.activePrescription = try plannedWorkout(state: withoutCredit, rules: rules, slot: slot)
        try validateStarterProgram(state: withoutCredit, rules: rules)
        state.activePrescription = withoutCredit.activePrescription
        let row = try #require(state.activePrescription.exercises.first { $0.movementID == id })
        #expect(row.phase == .returning && row.sets.count == 1)
        #expect(throws: EngineError.self) { try validateStarterProgram(state: state, rules: rules) }
        #expect(throws: EngineError.self) { try prepareWorkout(state: state, rules: rules) }
    }

    @Test(arguments: ["SUN", "TUE", "THU"])
    func eachWindowRejectsExposureOnAnotherScheduledWeekday(slotID: String) throws {
        var (state, rules, id) = try normalRowWithWindows()
        let key = try #require(state.exercises[id]!.starterState!.windows.first { $0.value.slotID == slotID }?.key)
        let correct = state.exercises[id]!.starterState!.windows[key]!.exposures[0].date
        try WorkoutScheduler.validate(slot: WorkoutSlot(date: correct, slotID: slotID), config: state.config)
        try validateStarterProgram(state: state, rules: rules)
        // Another scheduled day, still before completion/session bounds, preserves
        // all other fields and the context key while making slot evidence invalid.
        let wrong = try correct.adding(days: slotID == "SUN" ? 2 : -2)
        state.exercises[id]!.starterState!.windows[key]!.exposures[0].date = wrong
        #expect(throws: EngineError.self) { try validateStarterProgram(state: state, rules: rules) }
        #expect(throws: EngineError.self) { try prepareWorkout(state: state, rules: rules) }
    }

    @Test func windowsHaveStrictFrozenIdentityBoundsAndRawSideAdmission() throws {
        var (state, rules, id) = try normalRowWithWindows()
        let base = "chest_supported_db_row_30_neutral"
        let key = state.exercises[id]!.starterState!.windows.keys.sorted().first!
        var mutations: [ProgramState] = []
        var bad = state; bad.exercises[id]!.starterState!.windows[key]!.introStreak = 2; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.strainStreak = try rules.resolvedParameters.setbackCount; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.context.movementPosition = 5; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.precedingDose[0].normalSetCount = 99; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows["duplicate"] = bad.exercises[id]!.starterState!.windows[key]; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.exposures[0].actualSets[0].leftReps = 7; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.exposures[0].log!.actualSets[0].leftReps = 7; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.exposures = []; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.exposures[0].phase = .baseline; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.exposures[0].effort = .tooHard
        bad.exercises[id]!.starterState!.windows[key]!.exposures[0].log!.finalEffort = .tooHard; mutations.append(bad)
        bad = state; bad.exercises[id]!.starterState!.windows[key]!.exposures[0].actualSets[0].reps = 9
        bad.exercises[id]!.starterState!.windows[key]!.exposures[0].log!.actualSets[0].reps = 9; mutations.append(bad)
        for mutation in mutations { #expect(throws: EngineError.self) { try validateStarterProgram(state: mutation, rules: rules) } }
        let oldWindow = state.exercises[id]!.starterState!.windows[key]!
        state.exercises[id]!.exactRepState!.normalTargets = [9, 8]
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        try validateStarterProgram(state: state, rules: rules)
        #expect(state.exercises[id]!.starterState!.windows[key] == oldWindow)
        let rdl = state.config.activeVariantIDs!["db_romanian_deadlift"]!
        state.exercises[rdl]!.starterState!.doseStage = .established
        state.exercises[rdl]!.normalSets = 3
        state.exercises[rdl]!.exactRepState!.normalTargets = [8, 8, 8]
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: slot)
        try validateStarterProgram(state: state, rules: rules)
        #expect(state.exercises[id]!.starterState!.windows[key] == oldWindow)
        let reset = try reconfigureProgram(state: state, change: .resetSetup(variantID: id), rules: rules, nextWorkout: slot)
        #expect(reset.state.exercises[id]!.starterState!.windows.isEmpty)
        let reserve = try reconfigureProgram(state: state, change: .minimumRir(baseMovementID: base, value: 5), rules: rules, nextWorkout: slot)
        #expect(reserve.state.exercises[id]!.starterState!.windows.isEmpty)
        let goal = try reconfigureProgram(state: state, change: .goal(.maintenance), rules: rules, nextWorkout: slot)
        #expect(goal.state.exercises[id]!.starterState!.windows.isEmpty && goal.state.exercises[rdl]!.normalSets == 2)
        let returned = try prepareInterruptedReturn(state: state, asOf: try slot.date.adding(days: 28), rules: rules)
        #expect(returned.state.exercises[id]!.starterState!.windows.isEmpty)
        #expect(returned.state.exercises[id]!.load?.amount == "15")
    }

    @Test func publicResolversAndHotPathsRejectTamperedSuppliedValues() throws {
        let (state, rules) = try initial()
        let id = state.activePrescription.exercises.first!.movementID
        var config = state.config
        config.movements[0].implementCount = 1
        #expect(throws: EngineError.self) { try resolveEffectiveMovement(config: config, variantID: id, rules: rules) }
        #expect(throws: EngineError.self) { try resolveMovementDose(config: config, variantID: id, exercise: state.exercises[id], rules: rules) }
        var invalid = state; invalid.config = config
        #expect(throws: EngineError.self) { try plannedStarterWorkout(state: invalid, rules: rules, slot: slot) }
        #expect(throws: EngineError.self) { try prepareStarterWorkout(state: invalid, rules: rules, easierToday: false) }
        var altered = rules
        altered.starterDoses!["size"]!["db_romanian_deadlift"]!.repFloor += 1
        #expect(throws: EngineError.self) { try resolveEffectiveMovement(config: state.config, variantID: id, rules: altered) }
        #expect(throws: EngineError.self) { try resolveMovementDose(config: state.config, variantID: id, exercise: state.exercises[id], rules: altered) }
        #expect(throws: EngineError.self) { try plannedStarterWorkout(state: state, rules: altered, slot: slot) }
        #expect(throws: EngineError.self) { try validateStarterProgram(state: state, rules: altered) }
    }

    @Test func newTypedCommandsRoundTripAndLegacyRejectsThem() throws {
        let command = VariantChange.createLoadingMode(baseMovementID: "db_floor_glute_bridge", variantID: "bw", modifications: "", mode: .bodyweight)
        #expect(try JSONDecoder().decode(VariantChange.self, from: JSONEncoder().encode(command)) == command)
        let review = ConfigurationChange.reviewStrengthHandling(variantID: "x", choice: .standardRange)
        #expect(try JSONDecoder().decode(ConfigurationChange.self, from: JSONEncoder().encode(review)) == review)
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let rules = try RulesetCatalog.exactV1()
        let state = try initializeProgram(config: config, rules: rules, firstWorkout: slot).state
        #expect(throws: EngineError.self) { try changeMovementVariant(state: state, change: command, rules: rules, nextWorkout: slot) }
        #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: review, rules: rules, nextWorkout: slot) }
    }
}

extension StarterWorkoutPlannerTests {
    @Test func freshStrengthHandlingAdmitsOnlyExplicitCatalogLoad() throws {
        for base in ["incline_db_press_30", "chest_supported_db_row_30_neutral", "suitcase_db_squat"] {
            let (state, rules) = try initial(.wholeBodyGlutes, .strength)
            let id = state.config.activeVariantIDs![base]!
            let load = state.config.movements.first { $0.id == base }!.availableLoads[2]
            #expect(state.exercises[id]!.load == nil)
            let result = try reconfigureProgram(state: state, change: .reviewStrengthHandling(variantID: id, choice: .lowRep(load: load)), rules: rules, nextWorkout: slot)
            #expect(result.state.exercises[id]!.load == load)
            #expect(result.state.exercises[id]!.starterState!.strengthHandling == .lowRep(load: load))
            #expect(result.state.exercises[id]!.exactRepState!.normalTargets == [4, 4])
            #expect(result.state.exercises[id]!.starterState!.windows.isEmpty)
            #expect(throws: EngineError.self) {
                try reconfigureProgram(state: result.state, change: .reviewStrengthHandling(variantID: id, choice: .lowRep(load: Load(amount: "20", unit: .lb, basis: .perImplement))), rules: rules, nextWorkout: slot)
            }
            for wrong in [Load(amount: "15", unit: .lb, basis: .total), Load(amount: "17", unit: .lb, basis: .perImplement)] {
                #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: .reviewStrengthHandling(variantID: id, choice: .lowRep(load: wrong)), rules: rules, nextWorkout: slot) }
            }
        }
    }
}

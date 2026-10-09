import Foundation

func initializeStarterProgram(config: ProgramConfig, rules: Ruleset, firstWorkout: WorkoutSlot) throws -> InitializedProgram {
    var exercises: [String: ExerciseState] = [:]
    var safety: [String: MovementSafetyState] = [:]
    var retained: [String: MovementSafetyState] = [:]
    for movement in config.movements {
        let restriction = MovementSafetyState(paused: false, minimumRir: movement.minimumRir, sourceEventIDs: [])
        safety[movement.id] = restriction
        let family = rules.safetyFamilies![movement.id]!
        if let previous = retained[family] {
            retained[family] = MovementSafetyState(paused: previous.paused, minimumRir: max(previous.minimumRir, restriction.minimumRir), sourceEventIDs: [])
        } else { retained[family] = restriction }
    }
    for (id, variant) in config.variants! {
        let defaultID = try defaultVariantID(programID: config.programID, baseMovementID: variant.baseMovementID)
        let movement = try resolveValidatedEffectiveMovement(config: config, variantID: id, rules: rules)
        let dose = try resolveValidatedMovementDose(config: config, variantID: id, exercise: nil, rules: rules)
        exercises[id] = newStarterExercise(dose: dose,
            load: id == defaultID && movement.loadingMode == .externalLoad ? config.initialLoads[variant.baseMovementID]! : nil,
            paused: safety[variant.baseMovementID]!.paused)
    }
    var state = ProgramState(schemaVersion: 4, rulesetVersion: rules.version, rulesetHash: rules.hash,
        config: config, revision: 0, exercises: exercises, lastSessionDate: nil,
        activePrescription: WorkoutPrescription(id: "", date: firstWorkout.date, slotID: firstWorkout.slotID, exercises: []),
        processedEvents: [:], baseSafety: safety, retainedSafety: retained)
    state.activePrescription = try plannedStarterWorkout(state: state, rules: rules, slot: firstWorkout)
    return InitializedProgram(state: state, workout: state.activePrescription)
}

func newStarterExercise(dose: MovementDose, load: Load?, paused: Bool) -> ExerciseState {
    ExerciseState(load: load, mode: paused ? .paused : .baseline, normalSets: dose.initialSets,
        repFloor: dose.repFloor, repCeiling: dose.initialRepCeiling, ceilingStreak: 0, strainStreak: 0,
        lastCompletedDate: nil, nextSetOverride: nil, interruptedReturn: false, recentComparable: [], setupRevision: 1,
        exactRepState: ExactRepState(normalTargets: Array(repeating: dose.repFloor, count: dose.initialSets),
            shortfallStreak: 0, lastSuitableNormalDate: nil, setupReviewRequired: false),
        starterState: StarterExerciseState(doseStage: dose.allowsIntroPromotion ? .introductory : .fixed,
            strengthHandling: nil, windows: [:]))
}

public func plannedStarterWorkout(state: ProgramState, rules: Ruleset, slot: WorkoutSlot) throws -> WorkoutPrescription {
    try validateStarterState(state: state, rules: rules)
    return try makeValidatedStarterWorkout(state: state, rules: rules, slot: slot)
}

/// Called only after complete operation-local starter admission.
func makeValidatedStarterWorkout(state: ProgramState, rules: Ruleset, slot: WorkoutSlot) throws -> WorkoutPrescription {
    try WorkoutScheduler.validate(slot: slot, config: state.config)
    guard let weekly = state.config.weeklySlots.first(where: { $0.id == slot.slotID }) else {
        throw EngineError(code: "invalid_slot", field: "slotId")
    }
    let parameters = rules.parameters!
    var workout = WorkoutPrescription(id: "", date: slot.date, slotID: slot.slotID, exercises: [])
    for base in weekly.movementIDs {
        let id = state.config.activeVariantIDs![base]!
        let variant = state.config.variants![id]!
        let exercise = state.exercises[id]!
        let movement = try resolveValidatedEffectiveMovement(config: state.config, variantID: id, rules: rules)
        let dose = try resolveValidatedMovementDose(config: state.config, variantID: id, exercise: exercise, rules: rules)
        let safety = state.baseSafety![base]!
        let paused = safety.paused || exercise.mode == .paused
        let review = dose.requiresHandlingReview || exercise.exactRepState!.setupReviewRequired
        let returning = exercise.interruptedReturn || exercise.nextSetOverride != nil
        let count = min(exercise.normalSets, exercise.nextSetOverride ?? exercise.normalSets)
        let minimum = max(returning ? parameters.easierMinimumRir : parameters.normalMinimumRir,
                          max(movement.minimumRir, safety.minimumRir))
        let targets = exercise.exactRepState!.normalTargets.prefix(count).map { returning ? min($0, dose.repFloor) : $0 }
        workout.exercises.append(ExercisePrescription(movementID: id,
            kind: paused ? .paused : review ? .setupReview :
                exercise.load == nil && movement.loadingMode == .externalLoad ? .baselineSetup : .working,
            phase: returning ? .returning : exercise.mode == .baseline ? .baseline : .normal,
            load: exercise.load, sets: paused || review ? [] : targets.map {
                SetPrescription(repFloor: returning ? 0 : exercise.repFloor,
                    repCeiling: returning ? dose.repFloor : exercise.repCeiling,
                    effortInstruction: exactEffortInstruction(minimumRir: minimum, parameters: parameters), targetReps: $0)
            }, restSeconds: dose.restSeconds, stopInstruction: parameters.stopInstruction,
            baseMovementID: base, modificationsSnapshot: variant.modifications))
    }
    workout.id = try CanonicalJSON.sha256(prescriptionContent(workout))
    return workout
}

public func prepareStarterWorkout(state: ProgramState, rules: Ruleset, easierToday: Bool) throws -> WorkoutPrescription {
    try validateStarterProgram(state: state, rules: rules)
    let planned = state.activePrescription
    guard easierToday else { return planned }
    let parameters = rules.parameters!
    var result = planned
    for index in result.exercises.indices {
        let row = result.exercises[index]
        guard row.kind != .paused && row.kind != .setupReview else { continue }
        let exercise = state.exercises[row.movementID]!
        let dose = try resolveValidatedMovementDose(config: state.config, variantID: row.movementID, exercise: exercise, rules: rules)
        let minimum = max(parameters.easierMinimumRir, state.baseSafety![row.baseMovementID!]!.minimumRir)
        let count = min(row.sets.count, max(1, (exercise.normalSets + 1) / 2))
        result.exercises[index].phase = .easier
        result.exercises[index].sets = exercise.exactRepState!.normalTargets.prefix(count).map {
            SetPrescription(repFloor: 0, repCeiling: dose.repFloor,
                effortInstruction: exactEffortInstruction(minimumRir: minimum, parameters: parameters), targetReps: min($0, dose.repFloor))
        }
    }
    result.id = try CanonicalJSON.sha256(.object([
        "plannedPrescriptionId": .string(planned.id), "sessionMode": .string("easier"),
        "rulesetVersion": .string(rules.version), "rulesetHash": .string(rules.hash),
        "prescription": try prescriptionContent(result)
    ]))
    return result
}

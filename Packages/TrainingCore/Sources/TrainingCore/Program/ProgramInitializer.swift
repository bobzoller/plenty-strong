import Foundation

public struct InitializedProgram: Equatable, Sendable {
    public var state: ProgramState
    public var workout: WorkoutPrescription

    public init(state: ProgramState, workout: WorkoutPrescription) {
        self.state = state
        self.workout = workout
    }
}

public func initializeProgram(config: ProgramConfig, rules: Ruleset, firstWorkout: WorkoutSlot) throws -> InitializedProgram {
    try validate(config: config, rules: rules)
    let policy = try ProgramPolicy.resolve(schemaVersion: rules.contractVersion ?? 1, rules: rules)
    if policy.usesStarterDoses { return try initializeStarterProgram(config: config, rules: rules, firstWorkout: firstWorkout) }
    let app = policy.usesVariants
    let preset = try rules.preset(goal: config.goal, daysPerWeek: config.daysPerWeek)
    var exercises: [String: ExerciseState] = [:]
    var safety: [String: MovementSafetyState] = [:]
    for movement in config.movements {
        let range = initialRepRange(movement: movement, goal: config.goal, preset: preset)
        let variants = app ? config.variants!.values.filter { $0.baseMovementID == movement.id }.map(\.id) : [movement.id]
        for id in variants {
            // A saved setup starts unknown. A base-level supplied starting load
            // applies only to its default variant, never to a different setup.
            let defaultID = app ? try defaultVariantID(programID: config.programID, baseMovementID: movement.id) : movement.id
            let isDefault = id == defaultID
            exercises[id] = ExerciseState(load: isDefault ? config.initialLoads[movement.id]! : nil,
                mode: .baseline, normalSets: preset.normalSets, repFloor: range.floor, repCeiling: range.ceiling,
                ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil,
                interruptedReturn: false, recentComparable: [], setupRevision: app ? 1 : nil,
                exactRepState: policy.usesExactTargets ? ExactRepState(normalTargets: Array(repeating: range.floor, count: preset.normalSets), shortfallStreak: 0, lastSuitableNormalDate: nil, setupReviewRequired: false) : nil)
        }
        if app { safety[movement.id] = MovementSafetyState(paused: false, minimumRir: movement.minimumRir, sourceEventIDs: []) }
    }
    var state = ProgramState(schemaVersion: policy.schemaVersion, rulesetVersion: rules.version, rulesetHash: rules.hash,
        config: config, revision: 0, exercises: exercises, lastSessionDate: nil,
        activePrescription: WorkoutPrescription(id: "", date: firstWorkout.date, slotID: firstWorkout.slotID, exercises: []),
        processedEvents: [:], baseSafety: app ? safety : nil)
    state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: firstWorkout)
    if policy.usesExactTargets { try validateExactRepContract(state: state, rules: rules) }
    return InitializedProgram(state: state, workout: state.activePrescription)
}

/// Shared construction boundary for initialization and later pure transitions.
func plannedWorkout(state: ProgramState, rules: Ruleset, slot: WorkoutSlot) throws -> WorkoutPrescription {
    try rejectLegacyStarterFields(state)
    switch try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules) {
    case .starterExactV1: return try plannedStarterWorkout(state: state, rules: rules, slot: slot)
    case .fixedExactV1: return try plannedExactWorkout(state: state, rules: rules, slot: slot)
    case .numericV02, .fixedCeilingsV1: break
    }
    guard let weeklySlot = state.config.weeklySlots.first(where: { $0.id == slot.slotID }) else {
        throw EngineError(code: "invalid_slot", field: "slotId")
    }
    let app = state.schemaVersion == 2
    if app { try WorkoutScheduler.validate(slot: slot, config: state.config) }
    let preset = try rules.preset(goal: state.config.goal, daysPerWeek: state.config.daysPerWeek)
    let parameters = try rules.resolvedParameters
    var workout = WorkoutPrescription(id: "", date: slot.date, slotID: slot.slotID, exercises: [])
    for base in weeklySlot.movementIDs {
        guard let movement = state.config.movements.first(where: { $0.id == base }),
              let id = app ? state.config.activeVariantIDs?[base] : base,
              let exercise = state.exercises[id] else {
            throw EngineError(code: "invalid_state", field: "exercises.\(base)")
        }
        let shared = state.baseSafety?[base]
        let paused = exercise.mode == .paused || shared?.paused == true
        let minimumRir = max(movement.minimumRir, shared?.minimumRir ?? movement.minimumRir)
        let instruction = effortInstruction(minimumRir: max(parameters.normalMinimumRir, minimumRir), parameters: parameters)
        let count = min(exercise.normalSets, exercise.nextSetOverride ?? exercise.normalSets)
        guard count >= 1, exercise.repFloor >= 0, exercise.repCeiling >= exercise.repFloor else {
            throw EngineError(code: "invalid_state", field: "exercises.\(id)")
        }
        workout.exercises.append(ExercisePrescription(movementID: id,
            kind: paused ? .paused : (exercise.load == nil && movement.loadingMode == .externalLoad ? .baselineSetup : .working),
            phase: exercise.interruptedReturn || exercise.nextSetOverride != nil ? .returning : (exercise.mode == .baseline ? .baseline : .normal),
            load: exercise.load,
            sets: paused ? [] : Array(repeating: SetPrescription(repFloor: exercise.repFloor,
                repCeiling: exercise.repCeiling, effortInstruction: instruction), count: count),
            restSeconds: preset.restSeconds, stopInstruction: parameters.stopInstruction,
            baseMovementID: app ? base : nil, modificationsSnapshot: app ? state.config.variants?[id]?.modifications : nil))
    }
    workout.id = try CanonicalJSON.sha256(prescriptionContent(workout))
    return workout
}

func initialRepRange(movement: Movement, goal: Goal, preset: GoalPreset) -> (floor: Int, ceiling: Int) {
    if goal == .strength && !movement.lowRepLoadingAllowed {
        return (preset.fallbackFloor ?? 8, preset.fallbackCeiling ?? 12)
    }
    return (preset.repFloor, preset.repCeiling)
}

/// Stored semantic copy is part of prescription identity; UI localization is separate.
func effortInstruction(minimumRir: Int, parameters: RuleParameters) -> String {
    minimumRir == parameters.normalMinimumRir ? parameters.normalEffortInstruction :
        "Stop with at least \(minimumRir) good reps left; stop earlier for pain or loss of control."
}

func prescriptionContent(_ workout: WorkoutPrescription) throws -> CanonicalValue {
    guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(workout)) else {
        throw EngineError(code: "invalid_prescription", field: "activePrescription")
    }
    fields.removeValue(forKey: "id")
    return .object(fields)
}

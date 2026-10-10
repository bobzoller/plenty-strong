import Foundation

func exactEffortInstruction(minimumRir: Int, parameters: RuleParameters) -> String {
    minimumRir == parameters.normalMinimumRir ? parameters.normalEffortInstruction :
        "Aim for the listed reps. Stop at that number, or sooner to keep at least \(minimumRir) good reps left. Stop earlier for pain or loss of control."
}

func plannedExactWorkout(state: ProgramState, rules: Ruleset, slot: WorkoutSlot) throws -> WorkoutPrescription {
    guard let weekly = state.config.weeklySlots.first(where: { $0.id == slot.slotID }) else {
        throw EngineError(code: "invalid_slot", field: "slotId")
    }
    try WorkoutScheduler.validate(slot: slot, config: state.config, schedulingPolicy: state.schedulingPolicy)
    let preset = try rules.preset(goal: state.config.goal, daysPerWeek: state.config.daysPerWeek)
    let parameters = try rules.resolvedParameters
    var workout = WorkoutPrescription(id: "", date: slot.date, slotID: slot.slotID, exercises: [])
    for base in weekly.movementIDs {
        guard let id = state.config.activeVariantIDs?[base], let variant = state.config.variants?[id],
              let movement = state.config.movements.first(where: { $0.id == base }),
              let exercise = state.exercises[id], let exact = exercise.exactRepState,
              let safety = state.baseSafety?[base], exact.normalTargets.count == exercise.normalSets else {
            throw EngineError(code: "invalid_exact_state", field: "exercises.\(base)")
        }
        let paused = exercise.mode == .paused || safety.paused
        let returning = exercise.interruptedReturn || exercise.nextSetOverride != nil
        let count = min(exercise.normalSets, exercise.nextSetOverride ?? exercise.normalSets)
        guard count > 0 else { throw EngineError(code: "invalid_exact_state", field: "normalSets") }
        let minimum = max(returning ? parameters.easierMinimumRir : parameters.normalMinimumRir,
                          max(movement.minimumRir, safety.minimumRir))
        let targets = Array(exact.normalTargets.prefix(count)).map { returning ? min($0, exercise.repFloor) : $0 }
        workout.exercises.append(ExercisePrescription(movementID: id,
            kind: paused ? .paused : exact.setupReviewRequired ? .setupReview :
                exercise.load == nil && movement.loadingMode == .externalLoad ? .baselineSetup : .working,
            phase: returning ? .returning : exercise.mode == .baseline ? .baseline : .normal,
            load: exercise.load,
            sets: paused || exact.setupReviewRequired ? [] : targets.map {
                SetPrescription(repFloor: returning ? 0 : exercise.repFloor,
                    repCeiling: returning ? exercise.repFloor : exercise.repCeiling,
                    effortInstruction: exactEffortInstruction(minimumRir: minimum, parameters: parameters), targetReps: $0)
            }, restSeconds: preset.restSeconds, stopInstruction: parameters.stopInstruction,
            baseMovementID: base, modificationsSnapshot: variant.modifications))
    }
    workout.id = try CanonicalJSON.sha256(prescriptionContent(workout))
    return workout
}

func prepareExactWorkout(state: ProgramState, rules: Ruleset, easierToday: Bool) throws -> WorkoutPrescription {
    try validate(config: state.config, rules: rules)
    try validateExactRepContract(state: state, rules: rules)
    try validateExactTransitionState(state: state, rules: rules)
    let planned = state.activePrescription
    let expected = try plannedExactWorkout(state: state, rules: rules, slot: WorkoutSlot(date: planned.date, slotID: planned.slotID))
    guard planned == expected else { throw EngineError(code: "stale_prescription", field: "activePrescription") }
    guard easierToday else { return planned }
    let parameters = try rules.resolvedParameters
    var result = planned
    for index in result.exercises.indices {
        let row = result.exercises[index]
        guard row.kind != .paused && row.kind != .setupReview else { continue }
        let base = row.baseMovementID!
        let exercise = state.exercises[row.movementID]!
        let minimum = max(parameters.easierMinimumRir, state.baseSafety![base]!.minimumRir)
        let count = min(row.sets.count, max(1, (exercise.normalSets + 1) / 2))
        result.exercises[index].phase = .easier
        result.exercises[index].sets = exercise.exactRepState!.normalTargets.prefix(count).map {
            SetPrescription(repFloor: 0, repCeiling: exercise.repFloor,
                effortInstruction: exactEffortInstruction(minimumRir: minimum, parameters: parameters), targetReps: min($0, exercise.repFloor))
        }
    }
    result.id = try CanonicalJSON.sha256(.object([
        "plannedPrescriptionId": .string(planned.id), "sessionMode": .string("easier"),
        "rulesetVersion": .string(rules.version), "rulesetHash": .string(rules.hash),
        "prescription": try prescriptionContent(result)
    ]))
    return result
}

/// Fixed-profile and transition invariants supplement raw wire admission. They
/// apply at preparation as well as advancement/configuration, before any indexing.
private func validateExactTransitionState(state: ProgramState, rules: Ruleset) throws {
    let preset = try rules.preset(goal: state.config.goal, daysPerWeek: state.config.daysPerWeek)
    let parameters = try rules.resolvedParameters
    guard state.revision >= 0, state.revision < Int.max else {
        throw EngineError(code: "invalid_state", field: "revision")
    }
    for (id, exercise) in state.exercises {
        let base = state.config.variants![id]!.baseMovementID
        let movement = state.config.movements.first { $0.id == base }!
        let range = initialRepRange(movement: movement, goal: state.config.goal, preset: preset)
        let safety = state.baseSafety![base]!
        guard exercise.normalSets == preset.normalSets, exercise.repFloor == range.floor,
              exercise.repCeiling >= range.ceiling,
              (0..<parameters.confirmationCount).contains(exercise.ceilingStreak),
              (0..<parameters.setbackCount).contains(exercise.strainStreak),
              (exercise.ceilingStreak == 0 && exercise.strainStreak == 0 && exercise.exactRepState!.shortfallStreak == 0) ||
                !exercise.recentComparable.isEmpty,
              exercise.nextSetOverride == nil || (1...exercise.normalSets).contains(exercise.nextSetOverride!),
              !exercise.interruptedReturn || exercise.nextSetOverride != nil,
              movement.loadingMode == .externalLoad ?
                (exercise.load == nil || movement.availableLoads.contains(exercise.load!)) : exercise.load == nil,
              safety.minimumRir >= movement.minimumRir,
              exercise.mode != .paused || safety.paused else {
            throw EngineError(code: "invalid_exact_state", field: "exercises.\(id)")
        }
        // Hard work can retain raw overshoots as strain context. Non-hard work
        // above the ceiling is review-only and cannot be saved comparison credit.
        guard exercise.recentComparable.allSatisfy({ exposure in
            exposure.effort == .tooHard || exposure.actualSets.allSatisfy { $0.reps <= exposure.repCeiling }
        }) else {
            throw EngineError(code: "invalid_exact_state", field: "recentComparable.\(id)")
        }
    }
}

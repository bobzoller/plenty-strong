import Foundation

/// Comparison identity from the frozen state and issued workout; exact goals are
/// absent. Public callers must supply the current planned or easier prescription.
public func starterContextKey(state: ProgramState, prescription: WorkoutPrescription,
                              variantID: String, rules: Ruleset) throws -> String {
    try validateStarterProgram(state: state, rules: rules)
    guard try prescription == state.activePrescription ||
          prescription == (try prepareStarterWorkout(state: state, rules: rules, easierToday: true)) else {
        throw EngineError(code: "stale_prescription", field: "prescription")
    }
    return try admittedStarterWindow(state: state, prescription: prescription, variantID: variantID, rules: rules).contextKey
}

/// Requires admission of this same state/config/rules in the current operation.
/// Call before the movement loop so preceding doses cannot reflect an earlier
/// movement's promotion in the event being processed.
func admittedStarterWindow(state: ProgramState, prescription: WorkoutPrescription,
                           variantID: String, rules: Ruleset) throws -> StarterComparisonWindow {
    guard let position = prescription.exercises.firstIndex(where: { $0.movementID == variantID }),
          let exercise = state.exercises[variantID] else {
        throw EngineError(code: "invalid_variant", field: "variantId")
    }
    let row = prescription.exercises[position]
    let context = try exactContext(state: state, id: variantID, prescription: row, position: position,
        actualLoad: exercise.load, rules: rules)
    let preceding = prescription.exercises.prefix(position).map {
        StarterPrecedingMovement(baseMovementID: $0.baseMovementID!, normalSetCount: state.exercises[$0.movementID]!.normalSets)
    }
    let key = try starterComparisonKey(profileHash: state.config.profileHash!, slotID: prescription.slotID,
        context: context, precedingDose: preceding)
    return exercise.starterState!.windows[key] ?? StarterComparisonWindow(slotID: prescription.slotID,
        contextKey: key, context: context, precedingDose: preceding, ceilingStreak: 0,
        strainStreak: 0, shortfallStreak: 0, introStreak: 0, exposures: [])
}

/// Replace only an obsolete context for this slot. Other scheduled contexts retain
/// their evidence, including when shared numerical targets have moved forward.
func saveStarterWindow(_ window: StarterComparisonWindow, exercise: inout ExerciseState) {
    exercise.starterState!.windows = exercise.starterState!.windows.filter {
        $0.value.slotID != window.slotID || $0.key == window.contextKey
    }
    exercise.starterState!.windows[window.contextKey] = window
}

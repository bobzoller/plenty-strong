/// A primary rule result; rule helpers modify only the supplied value copy.
struct MovementOutcome {
    var action: DecisionAction
    var rules: [String]
    var key: String
    var appendComparable = false
    var notice: String?
}

func resetComparisons(_ exercise: inout ExerciseState) {
    exercise.ceilingStreak = 0
    exercise.strainStreak = 0
    exercise.recentComparable = []
}

/// Shared pinned R05 gap-start mutation. Entry points own gap detection, safety
/// precedence, completion dates and decisions; this helper changes only the
/// supplied exercise state.
func beginInterruptedReturn(_ exercise: inout ExerciseState) {
    resetComparisons(&exercise)
    exercise.mode = .baseline
    exercise.interruptedReturn = true
    exercise.nextSetOverride = max(1, min(exercise.nextSetOverride ?? exercise.normalSets, exercise.normalSets - 1))
}

func lowerAvailableLoad(movement: Movement, current: Load?) -> Load? {
    guard let current, let index = movement.availableLoads.firstIndex(of: current), index > 0 else { return nil }
    return movement.availableLoads[index - 1]
}

func interruptionRule(exercise: inout ExerciseState, classified: ClassifiedExposure,
                      gap: Bool, app: Bool) -> MovementOutcome {
    if gap {
        beginInterruptedReturn(&exercise)
        return MovementOutcome(action: .recover, rules: ["R05"], key: "interruption_return")
    }
    resetComparisons(&exercise)
    if classified.cleanReturn && classified.original.actualLoad == classified.prescription.load &&
        classified.prescription.phase == .returning &&
        classified.prescription.sets.count == exercise.nextSetOverride {
        exercise.interruptedReturn = false
        exercise.nextSetOverride = nil
        // Explicit combined app contract; archived v0.2 keeps existing mode.
        if app { exercise.mode = .normal }
        return MovementOutcome(action: .recover, rules: ["R05"], key: "interruption_return_complete")
    }
    return MovementOutcome(action: .recover, rules: ["R05"], key: "interruption_return_pending")
}

func baselineRule(exercise: inout ExerciseState, classified: ClassifiedExposure,
                  movement: Movement) -> MovementOutcome {
    resetComparisons(&exercise)
    if classified.normalized.status != .skipped, let actual = classified.original.actualLoad { exercise.load = actual }
    if classified.cleanReturn {
        exercise.mode = .normal
        return MovementOutcome(action: .baseline, rules: ["R06"], key: "baseline_established")
    }
    exercise.mode = .baseline
    if classified.cleanKnown && classified.normalized.finalEffort == .tooHard,
       let lower = lowerAvailableLoad(movement: movement, current: exercise.load) {
        exercise.load = lower
    }
    return MovementOutcome(action: .baseline, rules: ["R06"], key: "baseline_pending",
        notice: classified.aboveCeiling ? "rep_ceiling_exceeded" : nil)
}

func recoveryDoseRule(exercise: inout ExerciseState, classified: ClassifiedExposure) -> MovementOutcome {
    resetComparisons(&exercise)
    if classified.cleanReturn {
        exercise.nextSetOverride = nil
        exercise.mode = .baseline
        return MovementOutcome(action: .recover, rules: ["R09"], key: "recovery_return_complete")
    }
    if classified.cleanKnown && classified.strained && exercise.nextSetOverride == 1 {
        exercise.mode = .paused
        return MovementOutcome(action: .pause, rules: ["R09"], key: "recovery_review_required")
    }
    return MovementOutcome(action: .recover, rules: ["R09"], key: "recovery_return_pending")
}

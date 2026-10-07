import Foundation

func progressionRule(exercise: inout ExerciseState, classified: ClassifiedExposure,
                     movement: Movement, goal: Goal, preset: GoalPreset, parameters: RuleParameters) throws -> MovementOutcome {
    if classified.strained {
        exercise.ceilingStreak = 0
        exercise.strainStreak += 1
        if exercise.strainStreak < parameters.setbackCount {
            return MovementOutcome(action: .hold, rules: ["R08"], key: "strain_hold", appendComparable: true)
        }
        resetComparisons(&exercise)
        if let lower = lowerAvailableLoad(movement: movement, current: exercise.load) {
            exercise.load = lower
            exercise.mode = .baseline
            return MovementOutcome(action: .reduceLoad, rules: ["R08"], key: "load_reduced")
        }
        exercise.nextSetOverride = max(1, exercise.normalSets - 1)
        return MovementOutcome(action: .recover, rules: ["R08"], key: "recovery_dose",
            notice: movement.loadingMode == .externalLoad ? nil : "manual_setup_limit")
    }
    exercise.strainStreak = 0
    if !classified.atCeiling {
        exercise.ceilingStreak = 0
        return MovementOutcome(action: .hold, rules: ["R10"], key: "capacity_hold", appendComparable: true)
    }
    exercise.ceilingStreak += 1
    if exercise.ceilingStreak < parameters.confirmationCount {
        return MovementOutcome(action: .hold, rules: ["R11"], key: "ceiling_confirmation", appendComparable: true)
    }
    exercise.ceilingStreak = 0
    if goal == .maintenance && classified.normalized.finalEffort == .onTarget {
        return MovementOutcome(action: .hold, rules: ["R11", "R12"], key: "maintenance_success", appendComparable: true)
    }
    // Descriptions and assistance strings are never consulted here.
    if movement.loadingMode == .externalLoad && movement.automaticLoadProgressionAllowed,
       let load = exercise.load, let index = movement.availableLoads.firstIndex(of: load),
       index + 1 < movement.availableLoads.count {
        let next = movement.availableLoads[index + 1]
        if try ExactLoad(canonicalAmount: load.amount).allowsIncrease(to: ExactLoad(canonicalAmount: next.amount)) {
            exercise.load = next
            exercise.mode = .baseline
            let range = initialRepRange(movement: movement, goal: goal, preset: preset)
            exercise.repFloor = range.floor
            exercise.repCeiling = range.ceiling
            resetComparisons(&exercise)
            return MovementOutcome(action: .increaseLoad, rules: ["R11", "R13"], key: "load_increased")
        }
    }
    let maximum = goal == .strength && movement.lowRepLoadingAllowed ? parameters.maximumStrengthRepCeiling : parameters.maximumRepCeiling
    if movement.automaticRepRangeExtensionAllowed && exercise.repCeiling < maximum {
        exercise.repCeiling = min(maximum, exercise.repCeiling + parameters.repCeilingExtension)
        resetComparisons(&exercise)
        return MovementOutcome(action: .extendRepCeiling, rules: ["R11", "R14"], key: "rep_ceiling_extended")
    }
    let key = !movement.automaticLoadProgressionAllowed && !movement.automaticRepRangeExtensionAllowed ? "progression_restricted" : "equipment_limit"
    return MovementOutcome(action: .hold, rules: ["R11", "R15"], key: key, appendComparable: true, notice: key)
}

func hasPlateau(_ exposures: [Exposure], current: Exposure, app: Bool, count: Int) -> Bool {
    let window = exposures.filter { sameContext($0, current: current, app: app) && plateauEligible($0) }.suffix(count)
    guard count == 6, window.count == count else { return false }
    let totals = window.map { exposure in exposure.actualSets.reduce(0) {
        $0 + min($1.leftReps ?? $1.reps, $1.rightReps ?? $1.reps)
    } }
    return totals.suffix(3).sorted()[1] <= totals.prefix(3).sorted()[1]
}

/// Planner-domain values: complete, positive actuals normalized to set order.
/// The exposure classifier owns safety, load, side equality, and floor strain.
public struct ExactRepPlanningInput: Equatable, Sendable {
    public var prescribed: [Int]
    public var actual: [Int]
    public var ceiling: Int
    public var goal: Goal
    public var phase: PrescriptionPhase
    public var effort: Effort
    public var missReasons: [MissedGoalReason?]
    public var shortfallStreak: Int

    public init(prescribed: [Int], actual: [Int], ceiling: Int, goal: Goal,
                phase: PrescriptionPhase, effort: Effort, missReasons: [MissedGoalReason?],
                shortfallStreak: Int) {
        self.prescribed = prescribed
        self.actual = actual
        self.ceiling = ceiling
        self.goal = goal
        self.phase = phase
        self.effort = effort
        self.missReasons = missReasons
        self.shortfallStreak = shortfallStreak
    }
}

public enum ExactRepPlanKind: Equatable, Sendable {
    case hold, increment, rebase, adopt, fitBaseline, reduceTargets, observationConflict
}

public struct ExactRepPlanningResult: Equatable, Sendable {
    public var targets: [Int]
    public var shortfallStreak: Int
    public var kind: ExactRepPlanKind

    public init(targets: [Int], shortfallStreak: Int, kind: ExactRepPlanKind) {
        self.targets = targets
        self.shortfallStreak = shortfallStreak
        self.kind = kind
    }
}

public enum ExactRepPlanner {
    public static func plan(_ input: ExactRepPlanningInput) throws -> ExactRepPlanningResult {
        guard (1...20).contains(input.ceiling),
              !input.prescribed.isEmpty,
              input.actual.count == input.prescribed.count,
              input.missReasons.count == input.prescribed.count,
              input.prescribed.allSatisfy({ (1...input.ceiling).contains($0) }),
              input.actual.allSatisfy({ $0 > 0 }),
              (0..<2).contains(input.shortfallStreak),
              input.phase == .baseline || input.phase == .normal else {
            throw EngineError(code: "invalid_exact_planning_input", field: "input")
        }
        let parameters = ExactRepParameters()
        let held = ExactRepPlanningResult(targets: input.prescribed, shortfallStreak: 0, kind: .hold)
        let missed = input.prescribed.indices.filter { input.actual[$0] < input.prescribed[$0] }

        // Baseline fitting is guarded by known, non-hard, nonconflicting feedback.
        // The same qualification also prevents overshoot from implying capacity.
        if input.effort == .unknown { return held }
        if input.effort == .tooEasy && !missed.isEmpty {
            return ExactRepPlanningResult(targets: input.prescribed, shortfallStreak: 0,
                                          kind: .observationConflict)
        }
        if input.effort == .tooHard {
            let targets = input.actual.map { min(input.ceiling, max(parameters.minimumTargetReps, $0 - 1)) }
            return ExactRepPlanningResult(targets: targets, shortfallStreak: 0, kind: .reduceTargets)
        }
        // Never clamp raw actuals into a qualifying exposure. Only generated goals
        // are capped; too-hard handling above deliberately takes precedence.
        if input.actual.contains(where: { $0 > input.ceiling }) {
            return ExactRepPlanningResult(targets: input.prescribed, shortfallStreak: 0,
                                          kind: .observationConflict)
        }
        if input.phase == .baseline {
            return ExactRepPlanningResult(targets: input.actual, shortfallStreak: 0, kind: .fitBaseline)
        }
        if missed.isEmpty && input.actual != input.prescribed {
            return ExactRepPlanningResult(targets: input.actual, shortfallStreak: 0, kind: .adopt)
        }
        if !missed.isEmpty {
            guard missed.allSatisfy({ input.missReasons[$0] == .effortLimit }) else { return held }
            if input.shortfallStreak == 1 {
                return ExactRepPlanningResult(targets: input.actual, shortfallStreak: 0, kind: .rebase)
            }
            return ExactRepPlanningResult(targets: input.prescribed, shortfallStreak: 1, kind: .hold)
        }
        if input.goal == .maintenance && input.effort == .onTarget { return held }

        var targets = input.actual
        if input.effort == .tooEasy {
            targets = targets.map { min(input.ceiling, $0 + parameters.easyIncrementPerSet) }
        } else {
            // Strict comparison preserves the earliest index when minima tie.
            let eligible = targets.indices.filter { targets[$0] < input.ceiling }
            if let index = eligible.min(by: { targets[$0] < targets[$1] }) {
                targets[index] += parameters.normalIncrementTotal
            }
        }
        return ExactRepPlanningResult(targets: targets, shortfallStreak: 0,
                                      kind: targets == input.prescribed ? .hold : .increment)
    }
}

/// Count-only changes preserve order and provisional fatigue; no dose setting is added.
public func resizeExactTargets(_ targets: [Int], to count: Int) throws -> [Int] {
    guard count > 0, !targets.isEmpty, targets.allSatisfy({ (1...20).contains($0) }) else {
        throw EngineError(code: "invalid_exact_targets", field: "targets")
    }
    var resized = Array(targets.prefix(count))
    while resized.count < count {
        resized.append(max(1, resized[resized.count - 1] - 1))
    }
    return resized
}

/// Rebaseline a count-only configuration transition, retaining setup review and pause.
/// Load, range, setup identity, and evidence dates are retained without reinterpretation.
public func resizeExactExerciseState(_ exercise: ExerciseState, to count: Int) throws -> ExerciseState {
    guard var exact = exercise.exactRepState,
          exact.normalTargets.count == exercise.normalSets,
          (1...20).contains(exercise.repCeiling),
          exact.normalTargets.allSatisfy({ (1...exercise.repCeiling).contains($0) }) else {
        throw EngineError(code: "invalid_exact_state", field: "exercise.exactRepState")
    }
    exact.normalTargets = try resizeExactTargets(exact.normalTargets, to: count)
    exact.shortfallStreak = 0
    var resized = exercise
    resized.exactRepState = exact
    resized.normalSets = count
    resized.mode = exercise.mode == .paused ? .paused : .baseline
    resetComparisons(&resized)
    resized.nextSetOverride = nil
    resized.interruptedReturn = false
    return resized
}

import Testing
@testable import TrainingCore

struct ExactRepPlannerTests {
    @Test func conditionalTargets() throws {
        let cases: [(Effort, [Int], ExactRepPlanKind)] = [
            (.onTarget, [10, 10, 10], .increment),
            (.tooEasy, [12, 12, 11], .increment),
            (.tooHard, [9, 9, 8], .reduceTargets)
        ]
        for (effort, expected, kind) in cases {
            let result = try ExactRepPlanner.plan(input(effort: effort))
            #expect(result.targets == expected)
            #expect(result.kind == kind)
            #expect(result.shortfallStreak == 0)
        }
    }

    @Test func tieBreakAndSaturation() throws {
        let cases: [([Int], [Int])] = [
            ([10, 10, 10], [11, 10, 10]),
            ([11, 10, 10], [11, 11, 10]),
            ([12, 12, 11], [12, 12, 12]),
            ([12, 12, 12], [12, 12, 12]),
            ([12, 9, 9], [12, 10, 9])
        ]
        for (before, expected) in cases {
            let result = try ExactRepPlanner.plan(input(prescribed: before, actual: before))
            #expect(result.targets == expected)
            #expect(result.kind == (before == expected ? .hold : .increment))
        }
        #expect(try ExactRepPlanner.plan(input(prescribed: [12, 12, 12],
            actual: [12, 12, 12], effort: .tooEasy)).kind == .hold)
    }

    @Test func shortfallUsesPriorGoalsAndReason() throws {
        let first = try ExactRepPlanner.plan(input(prescribed: [10, 10, 10],
            reasons: [nil, nil, .effortLimit]))
        #expect(first.targets == [10, 10, 10])
        #expect(first.shortfallStreak == 1)
        #expect(first.kind == .hold)
        let second = try ExactRepPlanner.plan(input(prescribed: [10, 10, 10],
            reasons: [nil, nil, .effortLimit], streak: first.shortfallStreak))
        #expect(second.targets == [10, 10, 9])
        #expect(second.shortfallStreak == 0)
        #expect(second.kind == .rebase)
        for reason: MissedGoalReason? in [.timeInterruption, .otherUnknown, nil] {
            let held = try ExactRepPlanner.plan(input(prescribed: [10, 10, 10],
                reasons: [nil, nil, reason], streak: 1))
            #expect(held.targets == [10, 10, 10])
            #expect(held.shortfallStreak == 0)
            #expect(held.kind == .hold)
        }
        let mixed = try ExactRepPlanner.plan(input(prescribed: [10, 10, 10],
            actual: [10, 9, 8], reasons: [nil, .effortLimit, .timeInterruption], streak: 1))
        #expect(mixed.targets == [10, 10, 10])
        #expect(mixed.shortfallStreak == 0)
    }

    @Test func baselinePreservesFatigue() throws {
        for effort in [Effort.onTarget, .tooEasy] {
            let result = try ExactRepPlanner.plan(input(prescribed: [8, 8, 8],
                actual: [8, 7, 6], phase: .baseline, effort: effort))
            if effort == .onTarget {
                #expect(result.targets == [8, 7, 6])
                #expect(result.kind == .fitBaseline)
            } else {
                #expect(result.targets == [8, 8, 8])
                #expect(result.kind == .observationConflict)
            }
            #expect(result.shortfallStreak == 0)
        }
        let easy = try ExactRepPlanner.plan(input(phase: .baseline, effort: .tooEasy))
        #expect(easy.targets == [10, 10, 9])
        #expect(easy.kind == .fitBaseline)
    }

    @Test func baselineCannotBypassEffortQualification() throws {
        let unknown = try ExactRepPlanner.plan(input(actual: [11, 11, 10],
            phase: .baseline, effort: .unknown, streak: 1))
        #expect(unknown.targets == [10, 10, 9])
        #expect(unknown.kind == .hold)
        #expect(unknown.shortfallStreak == 0)
        let hard = try ExactRepPlanner.plan(input(actual: [14, 11, 10],
            phase: .baseline, effort: .tooHard))
        #expect(hard.targets == [12, 10, 9])
        #expect(hard.kind == .reduceTargets)
        let excessive = try ExactRepPlanner.plan(input(actual: [13, 10, 9], phase: .baseline))
        #expect(excessive.targets == [10, 10, 9])
        #expect(excessive.kind == .observationConflict)
    }

    @Test func maintenanceAndUnknownHold() throws {
        let maintenance = try ExactRepPlanner.plan(input(goal: .maintenance, streak: 1))
        #expect(maintenance.targets == [10, 10, 9])
        #expect(maintenance.kind == .hold)
        #expect(maintenance.shortfallStreak == 0)
        for goal in Goal.allCases {
            let unknown = try ExactRepPlanner.plan(input(actual: [11, 11, 10],
                goal: goal, effort: .unknown, streak: 1))
            #expect(unknown.targets == [10, 10, 9])
            #expect(unknown.kind == .hold)
            #expect(unknown.shortfallStreak == 0)
        }
        #expect(try ExactRepPlanner.plan(input(goal: .maintenance, effort: .tooEasy)).targets == [12, 12, 11])
        for goal in [Goal.size, .strength, .fatLoss] {
            #expect(try ExactRepPlanner.plan(input(goal: goal)).targets == [10, 10, 10])
        }
    }

    @Test func overshootNeverBypassesQualification() throws {
        for effort in [Effort.onTarget, .tooEasy] {
            let adopted = try ExactRepPlanner.plan(input(actual: [11, 11, 10], effort: effort, streak: 1))
            #expect(adopted.targets == [11, 11, 10])
            #expect(adopted.kind == .adopt)
            #expect(adopted.shortfallStreak == 0)
            let excessive = try ExactRepPlanner.plan(input(actual: [13, 11, 10], effort: effort))
            #expect(excessive.targets == [10, 10, 9])
            #expect(excessive.kind == .observationConflict)
        }
        let hard = try ExactRepPlanner.plan(input(actual: [14, 11, 10], effort: .tooHard))
        #expect(hard.targets == [12, 10, 9])
        #expect(hard.kind == .reduceTargets)
        let conflict = try ExactRepPlanner.plan(input(actual: [11, 9, 9],
            effort: .tooEasy, reasons: [nil, .effortLimit, nil], streak: 1))
        #expect(conflict.targets == [10, 10, 9])
        #expect(conflict.kind == .observationConflict)
        #expect(conflict.shortfallStreak == 0)
        let missWithOvershoot = try ExactRepPlanner.plan(input(actual: [11, 9, 9],
            reasons: [nil, .effortLimit, nil], streak: 1))
        #expect(missWithOvershoot.targets == [11, 9, 9])
        #expect(missWithOvershoot.kind == .rebase)
    }

    @Test func generatedTargetsRespectOneAndTwentyWithoutClampingActuals() throws {
        #expect(try ExactRepPlanner.plan(input(prescribed: [1], actual: [1],
            ceiling: 1, effort: .tooHard)).targets == [1])
        #expect(try ExactRepPlanner.plan(input(prescribed: [19, 20], actual: [19, 20],
            ceiling: 20, effort: .tooEasy)).targets == [20, 20])
        #expect(try ExactRepPlanner.plan(input(prescribed: [20], actual: [Int.max],
            ceiling: 20, effort: .tooHard)).targets == [20])
        let above = input(prescribed: [20], actual: [Int.max], ceiling: 20)
        #expect(try ExactRepPlanner.plan(above).targets == [20])
        #expect(above.actual == [Int.max])
    }

    @Test func invalidPlannerInputsReject() throws {
        let invalid: [ExactRepPlanningInput] = [
            input(prescribed: [], actual: []), input(actual: [10, 10]),
            input(reasons: []), input(prescribed: [0, 10, 9]),
            input(prescribed: [-1, 10, 9]), input(prescribed: [13, 10, 9]),
            input(actual: [0, 10, 9]), input(actual: [-1, 10, 9]),
            input(ceiling: 0), input(ceiling: 21), input(streak: -1), input(streak: 2),
            input(phase: .easier), input(phase: .returning)
        ]
        for value in invalid {
            #expect(throws: EngineError.self) { try ExactRepPlanner.plan(value) }
        }
    }

    @Test func resizingRetainsPrefixAndAddsFatigueTargets() throws {
        #expect(try resizeExactTargets([10, 10, 9], to: 4) == [10, 10, 9, 8])
        #expect(try resizeExactTargets([2, 1], to: 4) == [2, 1, 1, 1])
        #expect(try resizeExactTargets([10, 10, 9], to: 2) == [10, 10])
        #expect(try resizeExactTargets([20], to: 3) == [20, 19, 18])
        #expect(try resizeExactTargets([1], to: 1) == [1])
        for (targets, count) in [([], 2), ([0], 2), ([-1], 2), ([21], 2), ([1], 0), ([1], -1)] {
            #expect(throws: EngineError.self) { try resizeExactTargets(targets, to: count) }
        }
    }

    @Test func resizingStateRetainsLoadAndRebaselines() throws {
        let state = try exercise()
        let resized = try resizeExactExerciseState(state, to: 4)
        #expect(resized.exactRepState?.normalTargets == [10, 10, 9, 8])
        #expect(resized.normalSets == 4)
        #expect(resized.mode == .baseline)
        #expect(resized.ceilingStreak == 0)
        #expect(resized.strainStreak == 0)
        #expect(resized.recentComparable.isEmpty)
        #expect(resized.exactRepState?.shortfallStreak == 0)
        #expect(resized.nextSetOverride == nil)
        #expect(!resized.interruptedReturn)
        #expect(resized.load == Load(amount: "40", unit: .lb, basis: .perImplement))
        #expect(resized.setupRevision == 3)
        #expect(resized.lastCompletedDate == (try LocalDate(iso8601: "2026-10-06")))
        #expect(resized.exactRepState?.lastSuitableNormalDate == (try LocalDate(iso8601: "2026-10-01")))
        #expect(resized.exactRepState?.setupReviewRequired == true)
        #expect(resized.repFloor == 8)
        #expect(resized.repCeiling == 12)
        #expect(state.normalSets == 3)
        #expect(state.exactRepState?.normalTargets == [10, 10, 9])
        #expect(try resizeExactExerciseState(state, to: 2).exactRepState?.normalTargets == [10, 10])
        var paused = state
        paused.mode = .paused
        paused.load = nil
        let retained = try resizeExactExerciseState(paused, to: 4)
        #expect(retained.mode == .paused)
        #expect(retained.load == nil)
        #expect(retained.exactRepState?.setupReviewRequired == true)
    }

    @Test func resizingStateRejectsMissingOrInconsistentExactState() throws {
        var state = try exercise()
        state.exactRepState = nil
        #expect(throws: EngineError.self) { try resizeExactExerciseState(state, to: 4) }
        state = try exercise()
        state.normalSets = 2
        #expect(throws: EngineError.self) { try resizeExactExerciseState(state, to: 4) }
        state = try exercise()
        state.exactRepState?.normalTargets = [13, 10, 9]
        #expect(throws: EngineError.self) { try resizeExactExerciseState(state, to: 4) }
    }

    private func input(prescribed: [Int] = [10, 10, 9], actual: [Int] = [10, 10, 9],
                       ceiling: Int = 12, goal: Goal = .size, phase: PrescriptionPhase = .normal,
                       effort: Effort = .onTarget, reasons: [MissedGoalReason?]? = nil,
                       streak: Int = 0) -> ExactRepPlanningInput {
        ExactRepPlanningInput(prescribed: prescribed, actual: actual, ceiling: ceiling, goal: goal,
            phase: phase, effort: effort, missReasons: reasons ?? Array(repeating: nil, count: prescribed.count),
            shortfallStreak: streak)
    }

    private func exercise() throws -> ExerciseState {
        let date = try LocalDate(iso8601: "2026-10-06")
        let load = Load(amount: "40", unit: .lb, basis: .perImplement)
        let exposure = Exposure(eventID: "synthetic", date: date, load: load, plannedSetCount: 3,
            repFloor: 8, repCeiling: 12, actualSets: [ActualSet(reps: 10)],
            effort: .onTarget, problem: .none, sessionMode: .normal, phase: .normal)
        return ExerciseState(load: load, mode: .normal, normalSets: 3, repFloor: 8, repCeiling: 12,
            ceilingStreak: 1, strainStreak: 1, lastCompletedDate: date, nextSetOverride: 2,
            interruptedReturn: true, recentComparable: [exposure], setupRevision: 3,
            exactRepState: ExactRepState(normalTargets: [10, 10, 9], shortfallStreak: 1,
                lastSuitableNormalDate: try LocalDate(iso8601: "2026-10-01"), setupReviewRequired: true))
    }
}

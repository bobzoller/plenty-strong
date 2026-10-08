import Foundation
import Testing
@testable import TrainingCore

@Suite struct ExactRepTransitionTests {
    @Test(arguments: (1...19).map { String(format: "X%02d", $0) })
    func trainerWorkedTransitions(_ id: String) throws {
        let input = try ExactRepFixtureCompiler.input(id)
        let original = input
        #expect(try !ExactRepFixtureCompiler.selectedMovementID(id).isEmpty)
        let expected = try ExactRepFixtureCompiler.expected(id)
        let actual = try ExactRepFixtureCompiler.run(input)
        let matches = actual == expected
        #expect(matches, Comment(rawValue: difference(actual, expected) ?? id))
        let repeated = try ExactRepFixtureCompiler.run(input)
        let repeatedMatches = repeated == expected
        #expect(repeatedMatches, Comment(rawValue: difference(repeated, expected) ?? id))
        #expect(input == original)
    }
}

private func difference(_ actual: CanonicalValue, _ expected: CanonicalValue, path: String = "$") -> String? {
    if actual == expected { return nil }
    switch (actual, expected) {
    case let (.object(a), .object(e)):
        for key in Set(a.keys).union(e.keys).sorted() {
            guard let av = a[key], let ev = e[key] else { return "\(path).\(key): missing key actual=\(a[key] != nil) expected=\(e[key] != nil)" }
            if let result = difference(av, ev, path: "\(path).\(key)") { return result }
        }
    case let (.array(a), .array(e)):
        if a.count != e.count { return "\(path): count actual=\(a.count), expected=\(e.count)" }
        for i in a.indices { if let result = difference(a[i], e[i], path: "\(path)[\(i)]") { return result } }
    default: return "\(path): actual=\(actual), expected=\(expected)"
    }
    return path
}

extension ExactRepTransitionTests {
    @Test func firstSetFloorSignalDoesNotPunishLaterFatigue() throws {
        var input = try fixtureAdvance("X11")
        let id = input.event.exercises[0].movementID
        let fit = try applied(input)
        #expect(fit.state.exercises[id]!.exactRepState!.normalTargets == [8, 7, 6])
        #expect(fit.state.exercises[id]!.strainStreak == 0)
        #expect(fit.state.exercises[id]!.mode == .normal)
        setActual(&input, reps: [7, 7, 6], reason: .effortLimit)
        let first = try applied(input)
        #expect(first.state.exercises[id]!.strainStreak == 1)
        #expect(first.state.exercises[id]!.mode == .baseline)
        #expect(first.state.exercises[id]!.exactRepState!.normalTargets == [8, 8, 8])
        #expect(first.state.exercises[id]!.recentComparable.last?.phase == .baseline)
        let second = try applied(completion(first.state, id: id, reps: [7, 7, 6], reason: .effortLimit))
        #expect(second.state.exercises[id]!.load?.amount == "50")
        #expect(second.state.exercises[id]!.mode == .baseline)
        #expect(second.state.exercises[id]!.exactRepState!.normalTargets == [8, 8, 8])
        setActual(&input, reps: [7, 7, 6], effort: .tooEasy, reason: .effortLimit)
        let contradiction = try applied(input)
        #expect(contradiction.state.exercises[id]!.strainStreak == 0)
        #expect(contradiction.state.exercises[id]!.exactRepState!.normalTargets == [8, 8, 8])
        #expect(contradiction.decisions.contains { $0.explanationKey == "observation_conflict" })
    }

    @Test func baselineContextChangesBreakConsecutiveStrain() throws {
        var input = try fixtureAdvance("X11")
        let id = input.event.exercises[0].movementID
        setActual(&input, reps: [7, 7, 6], reason: .effortLimit)
        var first = try applied(input).state
        first.exercises[id]!.setupRevision! += 1
        try refresh(&first)
        let changed = try applied(completion(first, id: id, reps: [7, 7, 6], reason: .effortLimit))
        #expect(changed.state.exercises[id]!.strainStreak == 1)
        #expect(changed.state.exercises[id]!.load?.amount == "55")
        #expect(changed.state.exercises[id]!.recentComparable.count == 1)
        #expect(changed.state.exercises[id]!.recentComparable[0].exactRepContext?.setupRevision == 2)
    }

    @Test func contextBoundaries() throws {
        let first = try applied(fixtureAdvance("X07"))
        let id = try ExactRepFixtureCompiler.selectedMovementID("X07")
        let original = first.state.exercises[id]!.recentComparable[0].exactRepContext!
        let changes: [(inout ExactRepContext) -> Void] = [
            { $0.variantID = "different" }, { $0.setupRevision += 1 },
            { $0.load!.amount = "55" }, { $0.load!.unit = .kg }, { $0.load!.basis = .total },
            { $0.normalSetCount += 1 }, { $0.minimumRir += 1 }, { $0.restSeconds += 1 },
            { $0.movementPosition += 1 }, { $0.repFloor += 1 }, { $0.repCeiling += 2 }, { $0.rulesetHash = "different" }
        ]
        #expect(sameExactContext(original, original))
        for change in changes { var updated = original; change(&updated); #expect(!sameExactContext(original, updated)) }
        // Actual target changes in the normal hard sequence do not break context.
        if case let .advances(inputs) = try ExactRepFixtureCompiler.input("X04") {
            let context0 = inputs[1].state.exercises[id]!.recentComparable[0].exactRepContext!
            var ctx1 = context0
            ctx1.load = inputs[1].state.exercises[id]!.load
            #expect(sameExactContext(context0, ctx1))
        }
        // Every executable policy context change clears the entire window/counters.
        let rules = try RulesetCatalog.exactV1()
        for change in [ConfigurationChange.resetSetup(variantID: id), .minimumRir(baseMovementID: "incline_db_press_24", value: 4), .goal(.strength)] {
            let result = try reconfigureProgram(state: first.state, change: change, rules: rules,
                nextWorkout: WorkoutSlot(date: first.state.activePrescription.date, slotID: first.state.activePrescription.slotID))
            let e = result.state.exercises[id]!
            #expect(e.ceilingStreak == 0 && e.strainStreak == 0 && e.exactRepState!.shortfallStreak == 0)
            #expect(e.recentComparable.isEmpty)
            #expect(e.mode == .baseline)
        }
        // Rest and position are independently persisted context fields.
        for property in ["rest", "position", "reserve", "range"] {
            var changed = first.state
            var exposure = changed.exercises[id]!.recentComparable[0]
            switch property {
            case "rest": exposure.exactRepContext!.restSeconds += 1
            case "position": exposure.exactRepContext!.movementPosition += 1
            case "reserve": exposure.exactRepContext!.minimumRir += 1
            default: exposure.repCeiling = 14; exposure.exactRepContext!.repCeiling = 14
            }
            changed.exercises[id]!.recentComparable = [exposure]
            let result = try applied(completion(changed, id: id, reps: [12, 12, 12]))
            #expect(result.state.exercises[id]!.ceilingStreak == 1)
            #expect(result.state.exercises[id]!.load?.amount == "50")
            #expect(result.state.exercises[id]!.recentComparable.count == 1)
        }
    }

    @Test func safetyWinsInEveryMode() throws {
        let rules = try RulesetCatalog.exactV1()
        for mode in ["normal", "baseline", "easier", "return", "partial"] {
            for problem in [Problem.pain, .controlLost] {
                var input = try fixtureAdvance(mode == "baseline" ? "X11" : "X01")
                let id = input.event.exercises[0].movementID
                let base = input.event.exercises[0].baseMovementID!
                let slot = WorkoutSlot(date: input.state.activePrescription.date, slotID: input.state.activePrescription.slotID)
                input.state = try changeMovementVariant(state: input.state, change: .create(baseMovementID: base, variantID: "safety-sibling", modifications: "alternate grip"), rules: rules, nextWorkout: slot).state
                input.state.config.activeVariantIDs![base] = id
                if mode == "return" { try beginExactInterruptedReturn(&input.state.exercises[id]!, movement: input.state.config.movements[0], rules: rules) }
                try refresh(&input.state)
                let count = mode == "easier" ? 2 : input.state.activePrescription.exercises[0].sets.count
                input = try completion(input.state, id: id, reps: Array(repeating: 8, count: mode == "partial" ? 1 : count),
                    status: mode == "partial" ? .partial : .completed, problem: problem, easier: mode == "easier")
                let result = try applied(input)
                #expect(result.state.baseSafety![base]!.paused)
                #expect(result.state.baseSafety![base]!.sourceEventIDs.contains(input.event.eventID))
                #expect(result.state.exercises[id]!.mode == .paused)
                #expect(result.state.exercises["safety-sibling"]!.mode == .paused)
                #expect(result.workout.exercises.first { $0.movementID == id }!.sets.isEmpty)
                #expect(result.workout.exercises.first { $0.movementID == id }!.kind == .paused)
            }
        }
    }

    @Test func overshootNeverBypassesQualification() throws {
        for fault in ["hard", "unknown", "mixed", "asymmetric", "zero", "missing", "above"] {
            var input = try fixtureAdvance("X01")
            let id = input.event.exercises[0].movementID
            setActual(&input, reps: fault == "above" ? [30, 20, 13] : [11, 11, 10])
            switch fault {
            case "hard": input.event.exercises[0].finalEffort = .tooHard
            case "unknown": input.event.exercises[0].finalEffort = .unknown
            case "mixed": input.event.exercises[0].mixedLoads = true
            case "asymmetric": input.event.exercises[0].actualSets[0].leftReps = 11; input.event.exercises[0].actualSets[0].rightReps = 10
            case "zero": input.event.exercises[0].actualSets[1].reps = 0
            case "missing": input.event.exercises[0].actualSets.remove(at: 1); input.event.exercises[0].skippedSetIndices = [1]
            default: break
            }
            let original = input
            let result = try applied(input)
            let e = result.state.exercises[id]!
            #expect(e.ceilingStreak == 0 && e.load?.amount == "40")
            #expect(e.exactRepState!.normalTargets == [10, 10, 9])
            #expect(e.strainStreak == (fault == "hard" ? 1 : 0))
            #expect(input == original)
            if fault == "above" { #expect(result.decisions.contains { $0.explanationKey == "rep_ceiling_exceeded" }) }
        }
        var hard = try fixtureAdvance("X01")
        setActual(&hard, reps: [30, 20, 13], effort: .tooHard)
        let hardResult = try applied(hard)
        #expect(hardResult.state.exercises[hard.event.exercises[0].movementID]!.exactRepState!.normalTargets == [12, 12, 12])
        #expect(hard.event.exercises[0].actualSets.map(\.reps) == [30, 20, 13])
        #expect(hardResult.decisions.first!.ruleIDs == ["X06"])
    }

    @Test func overdueNormalWorkPreparesReturnEvenWithoutQualifyingPerformance() throws {
        for kind in ["unknown", "partial", "skip"] {
            var input = try fixtureAdvance("X01")
            let id = input.event.exercises[0].movementID
            input.state.exercises[id]!.exactRepState!.lastSuitableNormalDate = try LocalDate(iso8601: "2026-09-06")
            if kind == "unknown" { input.event.exercises[0].finalEffort = .unknown }
            if kind == "partial" { input.event.exercises[0].status = .partial; input.event.exercises[0].actualSets.removeLast() }
            if kind == "skip" { input.event.exercises[0].status = .skipped; input.event.exercises[0].actualSets = []; input.event.exercises[0].skippedSetIndices = [0, 1, 2] }
            let result = try applied(input)
            #expect(result.state.exercises[id]!.interruptedReturn)
            #expect(result.state.exercises[id]!.load?.amount == "35")
            #expect(result.workout.exercises[0].sets.map(\.targetReps) == [8, 8])
            #expect(result.state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 9])
            #expect(result.state.exercises[id]!.recentComparable.isEmpty)
        }
    }

    @Test func cleanReturnRequiresOneBaselineBeforeAnotherInterruptionCanBeDue() throws {
        guard case let .returnSequence(state, asOf, input) = try ExactRepFixtureCompiler.input("X18") else { return }
        let id = input.event.exercises[0].movementID
        let prepared = try prepareInterruptedReturn(state: state, asOf: asOf, rules: input.rules)
        var completionInput = input; completionInput.state = prepared.state
        let returned = try applied(completionInput)
        #expect(returned.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == nil)
        let next = try prepareInterruptedReturn(state: returned.state, asOf: returned.workout.date, rules: input.rules)
        #expect(next.state == returned.state)
        #expect(next.workout.exercises[0].phase == .baseline)
        #expect(next.workout.exercises[0].sets.map(\.targetReps) == [8, 8, 8])
        for fault in ["unknown", "easier"] {
            let intervening = try applied(completion(returned.state, id: id, reps: fault == "easier" ? [8, 8] : [8, 7, 6],
                effort: fault == "unknown" ? .unknown : .onTarget, easier: fault == "easier"))
            #expect(intervening.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == nil)
            let unchanged = try prepareInterruptedReturn(state: intervening.state, asOf: intervening.workout.date, rules: input.rules)
            #expect(!unchanged.state.exercises[id]!.interruptedReturn)
        }
        let calibrated = try applied(completion(returned.state, id: id, reps: [8, 7, 6]))
        #expect(calibrated.state.exercises[id]!.mode == .normal)
        #expect(!calibrated.state.exercises[id]!.interruptedReturn)
        #expect(calibrated.state.exercises[id]!.load?.amount == "45")
        #expect(calibrated.state.exercises[id]!.exactRepState!.normalTargets == [8, 7, 6])
        #expect(calibrated.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == returned.workout.date)
        let again = try prepareInterruptedReturn(state: calibrated.state, asOf: returned.workout.date.adding(days: 28), rules: input.rules)
        #expect(again.state.exercises[id]!.interruptedReturn)
        #expect(again.state.exercises[id]!.load?.amount == "40")
        for fault in ["unknown", "partial", "time", "hard"] {
            var unsuccessful = completionInput
            switch fault {
            case "unknown": unsuccessful.event.exercises[0].finalEffort = .unknown
            case "partial": unsuccessful.event.exercises[0].status = .partial; unsuccessful.event.exercises[0].actualSets.removeLast()
            case "time": unsuccessful.event.exercises[0].actualSets[1].reps = 7; unsuccessful.event.exercises[0].actualSets[1].missedGoalReason = .timeInterruption
            default: unsuccessful.event.exercises[0].finalEffort = .tooHard
            }
            let failed = try applied(unsuccessful)
            #expect(failed.state.exercises[id]!.interruptedReturn)
            #expect(failed.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == state.exercises[id]!.exactRepState!.lastSuitableNormalDate)
        }
    }

    @Test func overdueChangedLoadCannotBypassReturnButPreparedReturnRetainsActualLoad() throws {
        guard case let .returnSequence(state, asOf, frozenCompletion) = try ExactRepFixtureCompiler.input("X18") else { return }
        let id = state.config.activeVariantIDs!["incline_db_press_24"]!
        var unprepared = try completion(state, id: id, reps: [10, 10, 9])
        unprepared.event.exercises[0].actualLoad!.amount = "55"
        let raw = unprepared
        let overdue = try applied(unprepared)
        #expect(overdue.state.exercises[id]!.interruptedReturn)
        #expect(overdue.state.exercises[id]!.load?.amount == "45")
        #expect(overdue.state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 9])
        #expect(overdue.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == state.exercises[id]!.exactRepState!.lastSuitableNormalDate)
        #expect(unprepared == raw)
        let prepared = try prepareInterruptedReturn(state: state, asOf: asOf, rules: frozenCompletion.rules)
        var completed = frozenCompletion; completed.state = prepared.state
        completed.event.exercises[0].actualLoad!.amount = "50"
        let original = completed
        let accepted = try applied(completed)
        #expect(!accepted.state.exercises[id]!.interruptedReturn)
        #expect(accepted.state.exercises[id]!.mode == .baseline)
        #expect(accepted.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == nil)
        #expect(accepted.state.exercises[id]!.load?.amount == "50")
        #expect(accepted.state.exercises[id]!.exactRepState!.normalTargets == [8, 8, 8])
        #expect(completed == original)
    }

    @Test func nonzeroComparisonCountersRequireSavedContextEvidence() throws {
        var input = try fixtureAdvance("X01")
        let id = input.event.exercises[0].movementID
        for counter in ["ceiling", "strain", "shortfall"] {
            input = try fixtureAdvance("X01")
            switch counter {
            case "ceiling": input.state.exercises[id]!.ceilingStreak = 1
            case "strain": input.state.exercises[id]!.strainStreak = 1
            default: input.state.exercises[id]!.exactRepState!.shortfallStreak = 1
            }
            #expect(advanceProgram(input) == .rejected(nextState: input.state, errors: ["invalid_exact_state"]))
        }
    }

    @Test func aboveCeilingNonHardWorkCannotSupplySavedComparisonEvidence() throws {
        let first = try applied(fixtureAdvance("X07"))
        let id = first.workout.exercises[0].movementID
        var input = try completion(first.state, id: id, reps: [12, 12, 12])
        input.state.exercises[id]!.recentComparable[0].actualSets[0].reps = Int.max
        input.state.exercises[id]!.recentComparable[0].log!.actualSets[0].reps = Int.max
        let original = input
        let result = advanceProgram(input)
        let rejected = result == .rejected(nextState: input.state, errors: ["invalid_exact_state"])
        #expect(rejected)
        #expect(input == original)
    }

    @Test func emptyCompletedStatusCannotCertifyPausedOrReviewWork() throws {
        for gate in ["pause", "review"] {
            var state = try fixtureAdvance("X01").state
            let id = state.config.activeVariantIDs!["incline_db_press_24"]!
            if gate == "pause" {
                state.baseSafety!["incline_db_press_24"]!.paused = true
                state.exercises[id]!.mode = .paused
            } else { state.exercises[id]!.exactRepState!.setupReviewRequired = true }
            try refresh(&state)
            let input = try completion(state, id: id, reps: [], status: .completed)
            let original = input
            let result = try applied(input)
            #expect(result.workout.exercises[0].sets.isEmpty)
            #expect(result.state.exercises[id]!.lastCompletedDate == state.exercises[id]!.lastCompletedDate)
            #expect(result.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == state.exercises[id]!.exactRepState!.lastSuitableNormalDate)
            #expect(input == original)
        }
    }

    @Test func aboveCeilingUnknownOrPartialWorkStillRequestsReview() throws {
        for kind in ["unknown", "partial", "mixed"] {
            var input = try fixtureAdvance("X01")
            let id = input.event.exercises[0].movementID
            setActual(&input, reps: [30, 20, 13])
            if kind == "unknown" { input.event.exercises[0].finalEffort = .unknown }
            if kind == "partial" { input.event.exercises[0].status = .partial; input.event.exercises[0].actualSets.removeLast() }
            if kind == "mixed" { input.event.exercises[0].mixedLoads = true }
            let original = input
            let result = try applied(input)
            #expect(result.state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 9])
            #expect(result.state.exercises[id]!.ceilingStreak == 0)
            #expect(result.decisions.contains { $0.explanationKey == "rep_ceiling_exceeded" && $0.action == .notice })
            #expect(input == original)
        }
    }

    @Test func changedLoadStartsFreshFloorRatherThanFittingOldGoals() throws {
        var input = try fixtureAdvance("X01")
        let id = input.event.exercises[0].movementID
        input.event.exercises[0].actualLoad!.amount = "45"
        let result = try applied(input)
        #expect(result.state.exercises[id]!.load?.amount == "45")
        #expect(result.state.exercises[id]!.mode == .baseline)
        #expect(result.state.exercises[id]!.exactRepState!.normalTargets == [8, 8, 8])
        #expect(result.state.exercises[id]!.recentComparable.isEmpty)
        #expect(result.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == input.state.exercises[id]!.exactRepState!.lastSuitableNormalDate)
    }

    @Test func easierCannotRefreshInterruptionClock() throws {
        var input = try fixtureAdvance("X01")
        let id = input.event.exercises[0].movementID
        let rules = input.rules
        input.state.exercises[id]!.exactRepState!.lastSuitableNormalDate = try LocalDate(iso8601: "2026-10-04")
        input.state.exercises[id]!.lastCompletedDate = try LocalDate(iso8601: "2026-10-04")
        input.state.activePrescription = try plannedExactWorkout(state: input.state, rules: rules, slot: WorkoutSlot(date: try LocalDate(iso8601: "2026-11-01"), slotID: "SUN"))
        let day27 = try prepareInterruptedReturn(state: input.state, asOf: LocalDate(iso8601: "2026-10-31"), rules: rules)
        #expect(!day27.state.exercises[id]!.interruptedReturn)
        let easier = try applied(completion(day27.state, id: id, reps: [8, 8], effort: .tooHard, easier: true))
        let easierDate = try LocalDate(iso8601: "2026-11-01")
        let normalDate = try LocalDate(iso8601: "2026-10-04")
        #expect(easier.state.exercises[id]!.lastCompletedDate == easierDate)
        #expect(easier.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == normalDate)
        #expect(easier.state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 9])
        #expect(easier.state.exercises[id]!.strainStreak == 0)
        let day28 = try prepareInterruptedReturn(state: easier.state, asOf: LocalDate(iso8601: "2026-11-01"), rules: rules)
        #expect(day28.state.exercises[id]!.interruptedReturn)
        #expect(day28.state.exercises[id]!.load?.amount == "35")
        #expect(day28.workout.exercises.first { $0.movementID == id }!.sets.map(\.targetReps) == [8, 8])
    }

    @Test func returnEquipmentBodyweightAndMissingDateBoundaries() throws {
        let rules = try RulesetCatalog.exactV1()
        for amount in ["50", "40", "5"] {
            var state = try fixtureAdvance("X01").state
            let id = state.config.activeVariantIDs!["incline_db_press_24"]!
            state.exercises[id]!.load!.amount = amount
            state.exercises[id]!.exactRepState!.lastSuitableNormalDate = try LocalDate(iso8601: "2026-09-06")
            try refresh(&state)
            let result = try prepareInterruptedReturn(state: state, asOf: LocalDate(iso8601: "2026-10-04"), rules: rules)
            #expect(result.state.exercises[id]!.load?.amount == (amount == "50" ? "45" : amount == "40" ? "35" : "5"))
            #expect(result.state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 9])
        }
        var body = try fixtureAdvance("X12").state
        let id = body.config.activeVariantIDs!["bent_knee_hanging_leg_raise_ab_straps"]!
        body.exercises[id]!.exactRepState!.lastSuitableNormalDate = try LocalDate(iso8601: "2026-09-08")
        let returned = try prepareInterruptedReturn(state: body, asOf: LocalDate(iso8601: "2026-10-06"), rules: rules)
        #expect(returned.state.config.activeVariantIDs == body.config.activeVariantIDs)
        #expect(returned.state.exercises[id]!.load == nil)
        var noDate = try fixtureAdvance("X01").state
        let press = noDate.config.activeVariantIDs!["incline_db_press_24"]!
        noDate.exercises[press]!.exactRepState!.lastSuitableNormalDate = nil
        let noEvidence = try prepareInterruptedReturn(state: noDate, asOf: noDate.activePrescription.date, rules: rules)
        #expect(noEvidence.state.exercises[press]!.mode == .baseline)
        #expect(!noEvidence.state.exercises[press]!.interruptedReturn)
        #expect(noEvidence.state.exercises[press]!.exactRepState!.normalTargets == [8, 8, 8])
        for gated in ["pause", "review"] {
            var state = noDate
            if gated == "pause" { state.exercises[press]!.mode = .paused; state.baseSafety!["incline_db_press_24"]!.paused = true }
            else { state.exercises[press]!.exactRepState!.setupReviewRequired = true }
            try refresh(&state)
            let unchanged = try prepareInterruptedReturn(state: state, asOf: LocalDate(iso8601: "2026-12-06"), rules: rules)
            #expect(unchanged.state == state)
        }
    }

    @Test func maintenanceRequiresConsecutiveEasyCeilingConfirmations() throws {
        var input = try fixtureAdvance("X13")
        let id = input.event.exercises[0].movementID
        input.state.exercises[id]!.exactRepState!.normalTargets = [12, 12]
        try refresh(&input.state)
        input = try completion(input.state, id: id, reps: [12, 12], effort: .tooEasy)
        let first = try applied(input)
        #expect(first.state.exercises[id]!.ceilingStreak == 1)
        let nonEasy = try applied(completion(first.state, id: id, reps: [12, 12]))
        #expect(nonEasy.state.exercises[id]!.ceilingStreak == 0)
        #expect(nonEasy.state.exercises[id]!.exactRepState!.normalTargets == [12, 12])
        let easy = try applied(completion(nonEasy.state, id: id, reps: [12, 12], effort: .tooEasy))
        #expect(easy.state.exercises[id]!.ceilingStreak == 1)
        let confirmed = try applied(completion(easy.state, id: id, reps: [12, 12], effort: .tooEasy))
        #expect(confirmed.state.exercises[id]!.repCeiling == 14)
        #expect(confirmed.state.exercises[id]!.exactRepState!.normalTargets == [14, 14])
    }

    @Test func baselineReturnAndEasierSupplyNoCeilingCredit() throws {
        var baseline = try fixtureAdvance("X07")
        let id = baseline.event.exercises[0].movementID
        baseline.state.exercises[id]!.mode = .baseline
        try refresh(&baseline.state)
        baseline = try completion(baseline.state, id: id, reps: [12, 12, 12])
        let fitted = try applied(baseline)
        #expect(fitted.state.exercises[id]!.ceilingStreak == 0)
        #expect(fitted.state.exercises[id]!.load?.amount == "50")
        #expect(fitted.state.exercises[id]!.recentComparable.last?.phase == .baseline)
        let first = try applied(fixtureAdvance("X07"))
        let easier = try applied(completion(first.state, id: id, reps: [8, 8], effort: .tooEasy, easier: true))
        #expect(easier.state.exercises[id]!.ceilingStreak == 1)
        #expect(easier.state.exercises[id]!.recentComparable == first.state.exercises[id]!.recentComparable)
        if case let .returnSequence(state, asOf, completion) = try ExactRepFixtureCompiler.input("X18") {
            let returned = try prepareInterruptedReturn(state: state, asOf: asOf, rules: completion.rules)
            var input = completion; input.state = returned.state
            let finished = try applied(input)
            #expect(finished.state.exercises[id]!.ceilingStreak == 0)
            #expect(finished.state.exercises[id]!.recentComparable.isEmpty)
            #expect(finished.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == nil)
        }
    }

    @Test func skipsFreezeButUnknownAndPartialResetSequences() throws {
        let first = try applied(fixtureAdvance("X07"))
        let id = try ExactRepFixtureCompiler.selectedMovementID("X07")
        for kind in ["skip", "unknown", "partial", "time"] {
            var input = try completion(first.state, id: id, reps: [12, 12, 12])
            switch kind {
            case "skip": input.event.exercises[0].status = .skipped; input.event.exercises[0].actualSets = []; input.event.exercises[0].skippedSetIndices = [0, 1, 2]
            case "unknown": input.event.exercises[0].finalEffort = .unknown
            case "partial": input.event.exercises[0].status = .partial; input.event.exercises[0].actualSets.removeLast()
            default: setActual(&input, reps: [12, 12, 11], reason: .timeInterruption)
            }
            let result = try applied(input)
            #expect(result.state.exercises[id]!.ceilingStreak == (kind == "skip" ? 1 : 0))
            #expect(result.state.exercises[id]!.recentComparable == (kind == "skip" ? first.state.exercises[id]!.recentComparable : []))
            #expect(result.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == first.state.exercises[id]!.exactRepState!.lastSuitableNormalDate)
        }
        var miss = try fixtureAdvance("X05")
        for reason in [MissedGoalReason.timeInterruption, .otherUnknown] {
            setActual(&miss, reps: [10, 10, 9], reason: reason)
            let result = try applied(miss)
            #expect(result.state.exercises[miss.event.exercises[0].movementID]!.exactRepState!.shortfallStreak == 0)
        }
    }

    @Test func minimumLoadAndBodyweightSecondStrainRequireSetupReview() throws {
        for name in ["X01", "X12"] {
            var input = try fixtureAdvance(name)
            let id = input.event.exercises.first { $0.status != .skipped }!.movementID
            if name == "X01" { input.state.exercises[id]!.load!.amount = "5"; try refresh(&input.state) }
            input = try completion(input.state, id: id, reps: [10, 10, 9], effort: .tooHard)
            let first = try applied(input)
            let second = try applied(completion(first.state, id: id, reps: [9, 9, 8], effort: .tooHard))
            #expect(second.state.exercises[id]!.exactRepState!.setupReviewRequired)
            #expect(second.state.exercises[id]!.load == first.state.exercises[id]!.load)
            #expect(second.state.exercises[id]!.exactRepState!.normalTargets == [9, 9, 8])
            #expect(second.state.baseSafety![input.event.exercises.first { $0.movementID == id }!.baseMovementID!]!.paused == false)
            #expect(second.workout.exercises.first { $0.movementID == id }!.kind == .setupReview)
            #expect(second.workout.exercises.first { $0.movementID == id }!.sets.isEmpty)
            let reset = try reconfigureProgram(state: second.state, change: .resetSetup(variantID: id), rules: input.rules,
                nextWorkout: WorkoutSlot(date: second.workout.date, slotID: second.workout.slotID))
            #expect(!reset.state.exercises[id]!.exactRepState!.setupReviewRequired)
            #expect(reset.state.exercises[id]!.mode == .baseline)
            #expect(reset.state.exercises[id]!.recentComparable.isEmpty)
        }
    }

    @Test func countOnlyResizeDiffersFromGoalRangeReseedingAndRestrictedMovements() throws {
        let input = try fixtureAdvance("X01")
        let id = input.event.exercises[0].movementID
        let exercise = input.state.exercises[id]!
        let resized = try resizeExactExerciseState(exercise, to: 4)
        #expect(resized.exactRepState!.normalTargets == [10, 10, 9, 8])
        #expect(resized.load == exercise.load && resized.mode == .baseline)
        #expect(try resizeExactExerciseState(exercise, to: 2).exactRepState!.normalTargets == [10, 10])
        let result = try reconfigureProgram(state: input.state, change: .goal(.strength), rules: input.rules,
            nextWorkout: WorkoutSlot(date: input.state.activePrescription.date, slotID: input.state.activePrescription.slotID))
        #expect(result.state.exercises[id]!.exactRepState!.normalTargets == [4, 4, 4])
        let restricted = result.state.config.activeVariantIDs!["db_lateral_raise"]!
        #expect(result.state.exercises[restricted]!.repFloor == 8 && result.state.exercises[restricted]!.repCeiling == 12)
        let protected = try reconfigureProgram(state: result.state, change: .minimumRir(baseMovementID: "incline_db_press_24", value: 5), rules: input.rules,
            nextWorkout: WorkoutSlot(date: result.workout.date, slotID: result.workout.slotID))
        let prescribed = protected.workout.exercises.first { $0.movementID == id }!
        #expect(prescribed.sets.allSatisfy { $0.effortInstruction.contains("at least 5 good reps left") })
        #expect(try prepareWorkout(state: protected.state, rules: input.rules, easierToday: true).exercises.first { $0.movementID == id }!.sets.allSatisfy { $0.effortInstruction.contains("at least 5 good reps left") })
        var restriction = result.state.config.movements.first { $0.id == "db_lateral_raise" }!
        restriction.automaticLoadProgressionAllowed = false
        #expect(try permittedHigherExactLoad(movement: restriction, current: restriction.availableLoads[9]) == nil)
    }

    @Test func decimalTenPercentEqualityLargeGapsAndCeilingLimits() throws {
        let rules = try RulesetCatalog.exactV1()
        var movement = try fixtureAdvance("X01").state.config.movements[0]
        func load(_ amount: String) -> Load { Load(amount: amount, unit: .kg, basis: .perImplement) }
        movement.availableLoads = [load("0.5"), load("0.55"), load("0.605"), load("0.7")]
        #expect(try permittedHigherExactLoad(movement: movement, current: load("0.5")) == load("0.55"))
        #expect(try permittedHigherExactLoad(movement: movement, current: load("0.55")) == load("0.605"))
        #expect(try permittedHigherExactLoad(movement: movement, current: load("0.605")) == nil)
        var exercise = try fixtureAdvance("X01").state.exercises.values.first { $0.load != nil }!
        exercise.load = load("0.605")
        try beginExactInterruptedReturn(&exercise, movement: movement, rules: rules)
        #expect(exercise.load == load("0.5"))
        for goal in [Goal.size, .strength] {
            var input = try fixtureAdvance(goal == .size ? "X07" : "X17")
            let id = input.event.exercises[0].movementID
            let ceiling = goal == .size ? 20 : 8
            input.state.exercises[id]!.repCeiling = ceiling
            input.state.exercises[id]!.load!.amount = "80"
            input.state.exercises[id]!.exactRepState!.normalTargets = [ceiling, ceiling, ceiling]
            try refresh(&input.state)
            let first = try applied(completion(input.state, id: id, reps: [ceiling, ceiling, ceiling]))
            let second = try applied(completion(first.state, id: id, reps: [ceiling, ceiling, ceiling]))
            #expect(second.state.exercises[id]!.repCeiling == ceiling)
            #expect(second.state.exercises[id]!.exactRepState!.normalTargets == [ceiling, ceiling, ceiling])
            #expect(second.decisions.contains { $0.explanationKey == "equipment_limit" })
        }
    }

    @Test func sixComparableExposurePlateauAppliesOnlyToSizeAndStrength() throws {
        for goal in Goal.allCases {
            var state = try fixtureAdvance("X01").state
            let rules = try RulesetCatalog.exactV1()
            if goal != .size { state = try reconfigureProgram(state: state, change: .goal(goal), rules: rules,
                nextWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID)).state }
            let id = state.config.activeVariantIDs!["incline_db_press_24"]!
            let actual = goal == .strength ? [5, 5, 4] : state.exercises[id]!.normalSets == 2 ? [10, 9] : [10, 10, 9]
            state.exercises[id]!.mode = .normal
            state.exercises[id]!.exactRepState!.normalTargets = actual
            try refresh(&state)
            var finalDecisions: [Decision] = []
            for index in 0..<6 {
                let result = try applied(completion(state, id: id, reps: actual, reason: .otherUnknown))
                state = result.state; finalDecisions = result.decisions
                if index < 5 { #expect(!finalDecisions.contains { $0.explanationKey == "plateau_check" }) }
            }
            #expect(finalDecisions.contains { $0.explanationKey == "plateau_check" } == [.size, .strength].contains(goal))
            #expect(state.exercises[id]!.recentComparable.count == 6)
        }
    }

    @Test func staleAndEventIDReplayRejectWithoutMutation() throws {
        let input = try fixtureAdvance("X01")
        let result = try applied(input)
        var replay = input; replay.state = result.state
        #expect(advanceProgram(replay) == .noOp(nextState: result.state, reason: .eventReplayed))
        replay.event.exercises[0].finalEffort = .tooHard
        #expect(advanceProgram(replay) == .rejected(nextState: result.state, errors: ["event_id_conflict"]))
        var stale = input; stale.event.prescriptionID = "stale"
        #expect(advanceProgram(stale) == .rejected(nextState: input.state, errors: ["stale_prescription"]))
        var unsupported = input; unsupported.state.schemaVersion = 4
        #expect(advanceProgram(unsupported) == .rejected(nextState: unsupported.state, errors: ["unsupported_policy"]))
        var invalid = input; invalid.event.exercises[0].actualSets[1].setIndex = 0
        #expect(advanceProgram(invalid) == .rejected(nextState: input.state, errors: ["invalid_sets"]))
        var backdated = input; backdated.nextWorkoutDate = backdated.event.date
        #expect(advanceProgram(backdated) == .rejected(nextState: input.state, errors: ["invalid_date"]))
    }

    @Test func samePolicyBranchResolutionUnionsSafetyAndMixedPolicyRejects() throws {
        let input = try fixtureAdvance("X01")
        var other = input.state
        other.baseSafety!["incline_db_press_24"]!.paused = true
        other.exercises[input.event.exercises[0].movementID]!.mode = .paused
        try refresh(&other)
        let branches = [VerifiedBranch(headHash: "a", state: input.state, commands: []), VerifiedBranch(headHash: "b", state: other, commands: [])]
        var resolution = BranchResolutionInput(commonAncestor: input.state, competingHeadHashes: ["a", "b"], branches: branches,
            selection: BranchSelection(selectedHeadHash: "a"), rules: input.rules,
            next: WorkoutSlot(date: input.state.activePrescription.date, slotID: input.state.activePrescription.slotID))
        let result = try resolveCloudBranches(resolution)
        #expect(result.state.baseSafety!["incline_db_press_24"]!.paused)
        #expect(result.workout.exercises[0].sets.isEmpty)
        #expect(result.state.exercises.values.allSatisfy { $0.recentComparable.isEmpty })
        #expect(result.state.exercises[input.event.exercises[0].movementID]!.exactRepState!.normalTargets == [8, 8, 8])
        resolution.branches[1].state.schemaVersion = 2
        resolution.branches[1].state.rulesetHash = RulesetCatalog.fixedRulesetHash
        #expect(throws: EngineError(code: "mixed_policy_conflict", field: "branches")) { try resolveCloudBranches(resolution) }
        #expect(resolution.branches[0].state == input.state)
    }

    @Test func variantSelectionResetsContextWithoutInventingResistance() throws {
        let first = try applied(fixtureAdvance("X03"))
        let id = first.workout.exercises[0].movementID
        let base = "incline_db_press_24"
        let rules = try RulesetCatalog.exactV1()
        let slot = WorkoutSlot(date: first.workout.date, slotID: first.workout.slotID)
        let created = try changeMovementVariant(state: first.state,
            change: .create(baseMovementID: base, variantID: "independent-setup", modifications: "different bench setup"),
            rules: rules, nextWorkout: slot)
        #expect(created.state.exercises["independent-setup"]!.load == nil)
        #expect(created.state.exercises["independent-setup"]!.exactRepState!.normalTargets == [8, 8, 8])
        #expect(created.workout.exercises[0].kind == .baselineSetup)
        let selected = try changeMovementVariant(state: created.state,
            change: .select(baseMovementID: base, variantID: id), rules: rules, nextWorkout: slot)
        #expect(selected.state.exercises[id]!.strainStreak == 0)
        #expect(selected.state.exercises[id]!.recentComparable.isEmpty)
        #expect(selected.state.exercises[id]!.mode == .baseline)
        #expect(selected.state.exercises[id]!.load?.amount == "40")
        #expect(selected.state.exercises[id]!.exactRepState!.normalTargets == [9, 9, 8])
        #expect(selected.decisions[0].ruleIDs == ["X12"])
        #expect(selected.decisions[0].sourceIDs == ["EX01", "EX07"])
        var shared = selected.state
        shared.baseSafety![base]!.paused = true
        shared.exercises[id]!.mode = .paused
        try refresh(&shared)
        let pausedSelection = try changeMovementVariant(state: shared,
            change: .select(baseMovementID: base, variantID: "independent-setup"), rules: rules, nextWorkout: slot)
        #expect(pausedSelection.workout.exercises[0].kind == .paused)
        #expect(pausedSelection.workout.exercises[0].sets.isEmpty)
    }

    @Test func exactConfigurationDecisionEvidenceUsesFrozenArchive() throws {
        let input = try fixtureAdvance("X01")
        let slot = WorkoutSlot(date: input.state.activePrescription.date, slotID: input.state.activePrescription.slotID)
        let changed = try reconfigureProgram(state: input.state, change: .goal(.strength), rules: input.rules, nextWorkout: slot)
        #expect(changed.decisions.allSatisfy { $0.ruleIDs == ["X12"] && $0.sourceIDs == ["EX01", "EX07"] && $0.evidenceClass == .appAdaptation })
        let branches = [VerifiedBranch(headHash: "a", state: input.state, commands: []), VerifiedBranch(headHash: "b", state: input.state, commands: [])]
        let result = try resolveCloudBranches(BranchResolutionInput(commonAncestor: input.state, competingHeadHashes: ["a", "b"], branches: branches,
            selection: BranchSelection(selectedHeadHash: "a"), rules: input.rules, next: slot))
        #expect(result.decisions.allSatisfy { $0.ruleIDs == ["X13"] && $0.sourceIDs.isEmpty && $0.evidenceClass == .softwareRequirement })
    }

    @Test func indexedSideObservationsRemainRawAndOnlyEqualSidesQualify() throws {
        var state = try fixtureAdvance("X01").state
        let id = state.config.activeVariantIDs!["lying_db_curls"]!
        state.exercises[id]!.load = state.config.movements.first { $0.id == "lying_db_curls" }!.availableLoads[7]
        state.exercises[id]!.mode = .normal
        state.exercises[id]!.exactRepState!.normalTargets = [10, 10, 9]
        state.exercises[id]!.exactRepState!.lastSuitableNormalDate = try LocalDate(iso8601: "2026-10-01")
        try refresh(&state)
        var input = try completion(state, id: id, reps: [10, 10, 9])
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        for i in input.event.exercises[row].actualSets.indices {
            let reps = input.event.exercises[row].actualSets[i].reps
            input.event.exercises[row].actualSets[i].leftReps = reps
            input.event.exercises[row].actualSets[i].rightReps = reps
        }
        input.event.exercises[row].actualSets.reverse()
        let raw = input.event.exercises[row]
        let equal = try applied(input)
        #expect(equal.state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 10])
        #expect(equal.state.exercises[id]!.recentComparable.last!.log == raw)
        for fault in ["unequal", "missing-side", "skipped-middle"] {
            var partial = input
            switch fault {
            case "unequal": partial.event.exercises[row].actualSets[0].rightReps = 8
            case "missing-side": partial.event.exercises[row].actualSets[0].rightReps = nil
            default: partial.event.exercises[row].actualSets.remove(at: 1); partial.event.exercises[row].skippedSetIndices = [1]
            }
            let original = partial
            let result = try applied(partial)
            #expect(result.state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 9])
            #expect(result.state.exercises[id]!.recentComparable.isEmpty)
            #expect(partial == original)
        }
    }

    @Test func boundedTargetSweepHonorsCeilingsAndSafety() throws {
        // Every ordinary target value, plus every supported strength extension,
        // is exercised at the transition boundary. No fabricated valid states.
        for value in 1...20 {
            for effort in [Effort.onTarget, .tooEasy, .tooHard, .unknown] {
                var input = try fixtureAdvance("X01")
                let id = input.event.exercises[0].movementID
                input.state.exercises[id]!.repCeiling = max(12, value)
                input.state.exercises[id]!.exactRepState!.normalTargets = [value, max(1, value - 1), max(1, value - 2)]
                try refresh(&input.state)
                input = try completion(input.state, id: id, reps: input.state.exercises[id]!.exactRepState!.normalTargets, effort: effort)
                let result = try applied(input)
                let e = result.state.exercises[id]!
                #expect(e.exactRepState!.normalTargets.allSatisfy { (1...e.repCeiling).contains($0) })
                #expect(e.load?.amount == "40")
                input.event.exercises[0].problem = .pain
                let stopped = try applied(input)
                #expect(stopped.workout.exercises[0].sets.isEmpty)
                #expect(stopped.state.baseSafety!["incline_db_press_24"]!.paused)
            }
        }
    }
}

private func fixtureAdvance(_ id: String) throws -> AdvanceInput {
    guard case let .advances(inputs) = try ExactRepFixtureCompiler.input(id) else { throw EngineError(code: "wrong_fixture", field: id) }
    return inputs[0]
}
private struct Applied { var state: ProgramState; var workout: WorkoutPrescription; var decisions: [Decision] }
private func applied(_ input: AdvanceInput) throws -> Applied {
    switch advanceProgram(input) {
    case let .applied(state, workout, decisions): return Applied(state: state, workout: workout, decisions: decisions)
    case let .rejected(_, errors): throw EngineError(code: errors.joined(separator: ","), field: "test_transition")
    case .noOp: throw EngineError(code: "unexpected_replay", field: "test_transition")
    }
}
private func refresh(_ state: inout ProgramState) throws {
    state.activePrescription = try plannedExactWorkout(state: state, rules: RulesetCatalog.exactV1(),
        slot: WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID))
}
private func setActual(_ input: inout AdvanceInput, reps: [Int], effort: Effort = .onTarget, reason: MissedGoalReason? = nil) {
    let index = input.event.exercises.firstIndex { $0.status != .skipped }!
    input.event.exercises[index].actualSets = reps.enumerated().map { ActualSet(reps: $0.element, setIndex: $0.offset, missedGoalReason: reason) }
    input.event.exercises[index].finalEffort = effort
}
private func completion(_ state: ProgramState, id: String, reps: [Int], effort: Effort = .onTarget,
                        reason: MissedGoalReason? = nil, status: LogStatus = .completed,
                        problem: Problem = .none, easier: Bool = false) throws -> AdvanceInput {
    let rules = try RulesetCatalog.exactV1()
    let displayed = try prepareWorkout(state: state, rules: rules, easierToday: easier)
    let logs = displayed.exercises.map { row in
        let selected = row.movementID == id
        return ExerciseLog(movementID: row.movementID, prescriptionID: displayed.id, status: selected ? status : .skipped,
            actualLoad: row.load, actualSets: selected ? reps.enumerated().map {
                ActualSet(reps: $0.element, setIndex: $0.offset, missedGoalReason: reason)
            } : [], finalEffort: selected ? effort : .unknown, problem: selected ? problem : .none,
            baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot,
            effortScope: .allWorkingSets, skippedSetIndices: selected ? [] : Array(row.sets.indices), mixedLoads: false)
    }
    let event = CompletedWorkout(eventID: "edge-\(state.revision)-\(displayed.date.iso8601)", date: displayed.date,
        slotID: displayed.slotID, prescriptionID: displayed.id, plannedPrescriptionID: state.activePrescription.id,
        sessionMode: easier ? .easier : .normal, exercises: logs)
    let next = WorkoutSlot(date: try displayed.date.adding(days: displayed.slotID == "SUN" ? 4 : displayed.slotID == "THU" ? 3 : 7),
                           slotID: displayed.slotID == "SUN" ? "THU" : displayed.slotID == "THU" ? "SUN" : "TUE")
    return AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)
}

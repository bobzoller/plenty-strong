import Foundation
import Testing
@testable import TrainingCore

@Suite struct StarterProgressionTests {
    let rdl = "db_romanian_deadlift"
    let row = "chest_supported_db_row_30_neutral"

    @Test func sharedTargetsAdvanceAcrossDifferentPositions() throws {
        var state = try starterState()
        try starterSet(&state, base: rdl, targets: [10, 10, 9], established: true)
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10, 9]], nextSlot: "THU"))
        let id = state.config.activeVariantIDs![rdl]!
        #expect(state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 10])
        #expect(state.activePrescription.exercises.first { $0.movementID == id }!.sets.compactMap(\.targetReps) == [10, 10, 10])
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10, 10]]))
        #expect(Set(state.exercises[id]!.starterState!.windows.values.map(\.slotID)) == ["SUN", "THU"])
    }

    @Test func samePositionDifferentPrecedingWorkNeverCombinesConfirmations() throws {
        var state = try starterState(goal: .maintenance)
        try starterSet(&state, base: row, targets: [12, 12])
        let id = state.config.activeVariantIDs![row]!
        state = try starterApplied(starterInput(state, actuals: [row: [12, 12]], efforts: [row: .tooEasy]))
        state = try starterApplied(starterInput(state, actuals: [row: [12, 12]], efforts: [row: .tooEasy]))
        let windows = state.exercises[id]!.starterState!.windows.values
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.ceilingStreak == 1 && $0.context.movementPosition == 2 })
        #expect(windows.first!.precedingDose != windows.dropFirst().first!.precedingDose)
        #expect(state.exercises[id]!.load?.amount == "50")
    }

    @Test func alternatingSlotsRetainTheirOwnCeilingAndStrainEvidence() throws {
        for hard in [false, true] {
            var state = try starterState(goal: .maintenance)
            try starterSet(&state, base: row, targets: hard ? [10, 9] : [12, 12])
            let id = state.config.activeVariantIDs![row]!
            let reps = hard ? [10, 9] : [12, 12]
            let effort: Effort = hard ? .tooHard : .tooEasy
            for next in ["TUE", "THU", "SUN"] {
                state = try starterApplied(starterInput(state, actuals: [row: reps], efforts: [row: effort], nextSlot: next))
            }
            #expect(state.exercises[id]!.starterState!.windows.count == 3)
            state = try starterApplied(starterInput(state, actuals: [row: reps], efforts: [row: effort]))
            #expect(state.exercises[id]!.load?.amount == (hard ? "45" : "55"))
            #expect(state.exercises[id]!.starterState!.windows.isEmpty)
            #expect(state.exercises[id]!.mode == .baseline)
        }
    }

    @Test func introWinsOverLoadIncrease() throws {
        let input = try starterPromotionInput()
        let original = input
        let state = try starterApplied(input)
        let id = state.config.activeVariantIDs![rdl]!
        #expect(state.exercises[id]!.load?.amount == "50")
        #expect(state.exercises[id]!.normalSets == 3)
        #expect(state.exercises[id]!.exactRepState!.normalTargets == [12, 12, 11])
        #expect(state.exercises[id]!.mode == .baseline)
        #expect(state.exercises[id]!.starterState!.windows.isEmpty)
        #expect(input == original)
        #expect(input.event.exercises[0].actualSets.map(\.reps) == [12, 12])
        #expect(state.activePrescription.exercises.first { $0.movementID == id }!.sets.count == 3)
    }

    @Test func introPromotesOnlyAfterTwoMatchingNormalExposures() throws {
        var state = try starterState()
        try starterSet(&state, base: rdl, targets: [10, 9])
        let id = state.config.activeVariantIDs![rdl]!
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 9]], nextSlot: "THU"))
        #expect(state.exercises[id]!.normalSets == 2)
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.normalSets == 2)
        // On-target current shared goals, same SUN context: promotion without bonus.
        state = try starterApplied(starterInput(state, actuals: [rdl: [11, 10]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.normalSets == 3)
        #expect(state.exercises[id]!.exactRepState!.normalTargets == [11, 10, 9])
        #expect(state.exercises[id]!.starterState!.doseStage == .established)
        // Baseline is not introductory credit and the growth cannot recur.
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 9, 8]], nextSlot: "SUN"))
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 9, 8]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.normalSets == 3)
    }

    @Test func loadSetupGoalAndReturnClearAllWindows() throws {
        let input = try starterPromotionInput()
        let state = input.state
        let id = state.config.activeVariantIDs![rdl]!
        let slot = WorkoutSlot(date: state.activePrescription.date, slotID: "SUN")
        for change in [ConfigurationChange.resetSetup(variantID: id), .goal(.strength), .minimumRir(baseMovementID: rdl, value: 4)] {
            let result = try reconfigureProgram(state: state, change: change, rules: input.rules, nextWorkout: slot)
            #expect(result.state.exercises[id]!.starterState!.windows.isEmpty)
        }
        var changed = input
        changed.event.exercises[0].actualLoad!.amount = "55"
        let loaded = try starterApplied(changed)
        #expect(loaded.exercises[id]!.starterState!.windows.isEmpty)
        #expect(loaded.exercises[id]!.mode == .baseline)
        var overdue = state
        overdue.exercises[id]!.exactRepState!.lastSuitableNormalDate = try LocalDate(iso8601: "2026-09-01")
        let returning = try starterApplied(starterInput(overdue, actuals: [rdl: [12, 12]]))
        #expect(returning.exercises[id]!.starterState!.windows.isEmpty)
        #expect(returning.exercises[id]!.interruptedReturn)
    }

    @Test func maintenanceCapsPauseAndUnequalSidesStayGuarded() throws {
        var state = try starterState(goal: .maintenance)
        try starterSet(&state, base: rdl, targets: [10, 9], load: "20")
        let id = state.config.activeVariantIDs![rdl]!
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 9]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.exactRepState!.normalTargets == [10, 9])
        for _ in 0..<2 {
            state.exercises[id]!.exactRepState!.normalTargets = [12, 12]
            try starterRefresh(&state)
            state = try starterApplied(starterInput(state, actuals: [rdl: [12, 12]], efforts: [rdl: .tooEasy], nextSlot: "SUN"))
        }
        #expect(state.exercises[id]!.load?.amount == "20")
        #expect(state.exercises[id]!.repCeiling == 14)
        state = try starterApplied(starterInput(state, actuals: [rdl: [12, 12]], problems: [rdl: .pain]))
        #expect(state.exercises[id]!.mode == .paused)
        #expect(state.retainedSafety![try starterRules(state).safetyFamilies![rdl]!]!.paused)
        var sides = try starterState()
        let calf = "supported_single_leg_calf_raise"
        try starterSet(&sides, base: calf, targets: [12, 12], load: "20")
        var sideInput = try starterInput(sides, actuals: [calf: [12, 12]])
        let index = sideInput.event.exercises.firstIndex { $0.baseMovementID == calf }!
        sideInput.event.exercises[index].actualSets[0].rightReps = 11
        let held = try starterApplied(sideInput)
        #expect(held.exercises[sides.config.activeVariantIDs![calf]!]!.exactRepState!.normalTargets == [12, 12])
    }
}

extension StarterProgressionTests {
    @Test func midRangePromotionRetainsTwoSetActualsAndDoesNotRepeat() throws {
        var input = try starterPromotionInput()
        let id = input.state.config.activeVariantIDs![rdl]!
        let key = input.state.exercises[id]!.starterState!.windows.keys.first!
        input.state.exercises[id]!.exactRepState!.normalTargets = [10, 9]
        var prior = input.state.exercises[id]!.starterState!.windows[key]!
        prior.ceilingStreak = 0
        prior.exposures[0].prescribedTargets = [10, 9]
        prior.exposures[0].actualSets = [ActualSet(reps: 10, setIndex: 0), ActualSet(reps: 9, setIndex: 1)]
        prior.exposures[0].log!.actualSets = prior.exposures[0].actualSets
        input.state.exercises[id]!.starterState!.windows[key] = prior
        try starterRefresh(&input.state)
        input = try starterInput(input.state, actuals: [rdl: [10, 9]], nextSlot: "SUN")
        let raw = input.event
        var state = try starterApplied(input)
        #expect(state.exercises[id]!.exactRepState!.normalTargets == [10, 9, 8])
        #expect(state.exercises[id]!.load?.amount == "50")
        #expect(input.event == raw && input.event.exercises[0].actualSets.count == 2)
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 9, 8]], nextSlot: "SUN"))
        for reps in [[10, 9, 8], [10, 9, 9]] {
            state = try starterApplied(starterInput(state, actuals: [rdl: reps], nextSlot: "SUN"))
            #expect(state.exercises[id]!.normalSets == 3)
        }
    }

    @Test(arguments: ["skip", "easier"])
    func skipAndEasierFreezeIntroductoryCredit(_ kind: String) throws {
        let input = try starterPromotionInput()
        let id = input.state.config.activeVariantIDs![rdl]!
        var state = try starterApplied(starterInput(input.state,
            actuals: kind == "skip" ? [:] : [rdl: [8]], mode: kind == "skip" ? .normal : .easier, nextSlot: "SUN"))
        #expect(state.exercises[id]!.starterState!.windows == input.state.exercises[id]!.starterState!.windows)
        state = try starterApplied(starterInput(state, actuals: [rdl: [12, 12]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.normalSets == 3)
    }

    @Test(arguments: ["baseline", "partial", "unknown", "hard", "overshoot", "above", "mixed", "time"])
    func ineligibleNormalResultsCannotPromote(_ fault: String) throws {
        var input = try starterPromotionInput()
        let id = input.state.config.activeVariantIDs![rdl]!
        switch fault {
        case "baseline":
            input.state.exercises[id]!.mode = .baseline
            input.state.exercises[id]!.starterState!.windows = [:]
            try starterRefresh(&input.state)
            input = try starterInput(input.state, actuals: [rdl: [12, 12]], nextSlot: "SUN")
        case "partial":
            input.event.exercises[0].status = .partial
            input.event.exercises[0].actualSets.removeLast()
            input.event.exercises[0].skippedSetIndices = [1]
        case "unknown": input.event.exercises[0].finalEffort = .unknown
        case "hard": input.event.exercises[0].finalEffort = .tooHard
        case "mixed": input.event.exercises[0].mixedLoads = true
        case "time":
            input.event.exercises[0].actualSets[1].reps = 11
            input.event.exercises[0].actualSets[1].missedGoalReason = .timeInterruption
        case "overshoot":
            input.state.exercises[id]!.exactRepState!.normalTargets = [11, 11]
            try starterRefresh(&input.state)
            input = try starterInput(input.state, actuals: [rdl: [12, 12]], nextSlot: "SUN")
        default: input.event.exercises[0].actualSets[0].reps = 13
        }
        let state = try starterApplied(input)
        #expect(state.exercises[id]!.normalSets == 2)
        #expect(state.exercises[id]!.starterState!.windows.values.allSatisfy { $0.introStreak == 0 })
    }

    @Test func ineligibleSlotResetsOnlyItsOwnCreditAndObsoletePrecedingDoseReplacesSlot() throws {
        var state = try starterState()
        try starterSet(&state, base: row, targets: [12, 12])
        let id = state.config.activeVariantIDs![row]!
        state = try starterApplied(starterInput(state, actuals: [row: [12, 12]]))
        state = try starterApplied(starterInput(state, actuals: [row: [12, 12]], nextSlot: "SUN"))
        let tue = state.exercises[id]!.starterState!.windows.values.first { $0.slotID == "TUE" }!
        state = try starterApplied(starterInput(state, actuals: [row: [12]], nextSlot: "SUN"))
        #expect(Array(state.exercises[id]!.starterState!.windows.values) == [tue])
        // A preceding promotion changes this slot's identity while preserving TUE.
        let preceding = state.config.activeVariantIDs![rdl]!
        state.exercises[preceding]!.starterState!.doseStage = .established
        state.exercises[preceding]!.normalSets = 3
        state.exercises[preceding]!.exactRepState!.normalTargets = [8, 8, 7]
        try starterRefresh(&state)
        state = try starterApplied(starterInput(state, actuals: [row: [12, 12]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.starterState!.windows.count == 2)
        let sun = state.exercises[id]!.starterState!.windows.values.first { $0.slotID == "SUN" }!
        #expect(sun.precedingDose[0].normalSetCount == 3 && sun.introStreak == 1)
        #expect(state.exercises[id]!.starterState!.windows.values.first { $0.slotID == "TUE" } == tue)
    }

    @Test func contextsUseFrozenPrecedingDoseWhenEarlierMovementPromotes() throws {
        var input = try starterPromotionInput()
        try starterSet(&input.state, base: row, targets: [10, 9])
        input = try starterInput(input.state, actuals: [rdl: [12, 12], row: [10, 9]], nextSlot: "SUN")
        let state = try starterApplied(input)
        let id = state.config.activeVariantIDs![row]!
        let window = try #require(state.exercises[id]!.starterState!.windows.values.first)
        #expect(state.exercises[state.config.activeVariantIDs![rdl]!]!.normalSets == 3)
        #expect(window.precedingDose[0] == StarterPrecedingMovement(baseMovementID: rdl, normalSetCount: 2))
        #expect(window.contextKey == (try starterContextKey(state: input.state,
            prescription: input.state.activePrescription, variantID: id, rules: input.rules)))
    }

    @Test(arguments: [Goal.fatLoss, .maintenance])
    func fixedGoalsAndIneligibleMovementsNeverGraduate(_ goal: Goal) throws {
        var state = try starterState(goal: goal)
        try starterSet(&state, base: rdl, targets: [10, 9])
        let id = state.config.activeVariantIDs![rdl]!
        for _ in 0..<3 {
            let targets = state.exercises[id]!.exactRepState!.normalTargets
            state = try starterApplied(starterInput(state, actuals: [rdl: targets], nextSlot: "SUN"))
        }
        #expect(state.exercises[id]!.normalSets == 2 && state.exercises[id]!.starterState!.doseStage == .fixed)
        var size = try starterState()
        let bridge = "db_floor_glute_bridge"
        try starterSet(&size, base: bridge, targets: [12, 11])
        let bridgeID = size.config.activeVariantIDs![bridge]!
        for _ in 0..<3 {
            size = try starterApplied(starterInput(size, actuals: [bridge: size.exercises[bridgeID]!.exactRepState!.normalTargets], nextSlot: "SUN"))
        }
        #expect(size.exercises[bridgeID]!.normalSets == 2)
    }

    @Test func strengthRDLUsesSixToTenThenTwentyCapAndHandlingLoadChangesRequireReview() throws {
        var state = try starterState(goal: .strength)
        try starterSet(&state, base: rdl, targets: [10, 10])
        let id = state.config.activeVariantIDs![rdl]!
        #expect(state.exercises[id]!.repFloor == 6 && state.exercises[id]!.repCeiling == 10)
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10]], nextSlot: "SUN"))
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.normalSets == 3 && state.exercises[id]!.load?.amount == "50")
        state.exercises[id]!.mode = .normal
        state.exercises[id]!.load!.amount = "20"
        state.exercises[id]!.exactRepState!.normalTargets = [10, 10, 10]
        state.exercises[id]!.starterState!.windows = [:]
        try starterRefresh(&state)
        for _ in 0..<2 { state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10, 10]], nextSlot: "SUN")) }
        #expect(state.exercises[id]!.repCeiling == 12 && state.exercises[id]!.load?.amount == "20")
        state.exercises[id]!.repCeiling = 20
        state.exercises[id]!.exactRepState!.normalTargets = [20, 20, 20]
        state.exercises[id]!.starterState!.windows = [:]
        try starterRefresh(&state)
        for _ in 0..<2 { state = try starterApplied(starterInput(state, actuals: [rdl: [20, 20, 20]], nextSlot: "SUN")) }
        #expect(state.exercises[id]!.repCeiling == 20 && state.exercises[id]!.load?.amount == "20")
        let press = "incline_db_press_30"
        let pressID = state.config.activeVariantIDs![press]!
        state.exercises[pressID]!.load = state.config.movements.first { $0.id == press }!.availableLoads[9]
        try starterRefresh(&state)
        state = try reconfigureProgram(state: state, change: .reviewStrengthHandling(variantID: pressID,
            choice: .lowRep(load: state.exercises[pressID]!.load!)), rules: starterRules(state),
            nextWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: "SUN")).state
        var changed = try starterInput(state, actuals: [press: [4, 4]])
        let pressIndex = changed.event.exercises.firstIndex { $0.baseMovementID == press }!
        changed.event.exercises[pressIndex].actualLoad!.amount = "55"
        let reviewed = try starterApplied(changed)
        #expect(reviewed.exercises[pressID]!.starterState!.strengthHandling == nil)
        #expect(reviewed.activePrescription.exercises.first { $0.movementID == pressID } == nil)
        let nextSUN = try plannedWorkout(state: reviewed, rules: starterRules(reviewed),
            slot: WorkoutSlot(date: reviewed.activePrescription.date.adding(days: 5), slotID: "SUN"))
        #expect(nextSUN.exercises.first { $0.movementID == pressID }!.kind == .setupReview)
    }

    @Test func secondStrainAtMinimumLoadRequiresReviewAndReturnOverrideHasNoCredit() throws {
        var state = try starterState(goal: .maintenance)
        try starterSet(&state, base: rdl, targets: [10, 9], load: "5")
        let id = state.config.activeVariantIDs![rdl]!
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 9]], efforts: [rdl: .tooHard], nextSlot: "SUN"))
        state = try starterApplied(starterInput(state, actuals: [rdl: [9, 8]], efforts: [rdl: .tooHard], nextSlot: "SUN"))
        #expect(state.exercises[id]!.exactRepState!.setupReviewRequired)
        #expect(state.exercises[id]!.starterState!.windows.isEmpty)
        #expect(state.exercises[id]!.load?.amount == "5")
        var returning = try starterState()
        try starterSet(&returning, base: rdl, targets: [10, 9])
        let returnID = returning.config.activeVariantIDs![rdl]!
        returning.exercises[returnID]!.nextSetOverride = 1
        try starterRefresh(&returning)
        let completed = try starterApplied(starterInput(returning, actuals: [rdl: [8]]))
        #expect(completed.exercises[returnID]!.mode == .baseline)
        #expect(completed.exercises[returnID]!.normalSets == 2)
        #expect(completed.exercises[returnID]!.starterState!.windows.isEmpty)
    }

    @Test func shortfallAndPlateauEvidenceAreContextLocal() throws {
        var state = try starterState()
        try starterSet(&state, base: rdl, targets: [10, 10, 10], established: true)
        let id = state.config.activeVariantIDs![rdl]!
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10, 9]], nextSlot: "THU"))
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10, 9]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 10])
        #expect(state.exercises[id]!.starterState!.windows.values.allSatisfy { $0.shortfallStreak == 1 })
        state = try starterApplied(starterInput(state, actuals: [rdl: [10, 10, 9]], nextSlot: "SUN"))
        #expect(state.exercises[id]!.exactRepState!.normalTargets == [10, 10, 9])
        #expect(state.exercises[id]!.starterState!.windows.values.first { $0.slotID == "THU" }!.shortfallStreak == 1)
        // Unknown cause holds the vector, giving a real context-local plateau.
        state.exercises[id]!.exactRepState!.normalTargets = [10, 10, 10]
        state.exercises[id]!.starterState!.windows = [:]
        try starterRefresh(&state)
        for index in 0..<6 {
            var input = try starterInput(state, actuals: [rdl: [10, 10, 9]], nextSlot: "SUN")
            input.event.exercises[0].actualSets[2].missedGoalReason = .otherUnknown
            guard case let .applied(next, _, decisions) = advanceProgram(input) else { Issue.record("Expected valid plateau event"); return }
            state = next
            #expect(decisions.contains { $0.explanationKey == "plateau_check" } == (index == 5))
        }
        #expect(state.exercises[id]!.starterState!.windows.values.first!.exposures.count == 6)
        #expect(state.exercises[id]!.ceilingStreak == 0 && state.exercises[id]!.strainStreak == 0)
        #expect(state.exercises[id]!.exactRepState!.shortfallStreak == 0 && state.exercises[id]!.recentComparable.isEmpty)
    }

    @Test func publicBoundariesRejectTamperingAndReplayRemainsIdempotent() throws {
        let input = try starterPromotionInput()
        let state = try starterApplied(input)
        var replay = input; replay.state = state
        #expect(advanceProgram(replay) == .noOp(nextState: state, reason: .eventReplayed))
        replay.event.exercises[0].finalEffort = .tooHard
        #expect(advanceProgram(replay) == .rejected(nextState: state, errors: ["event_id_conflict"]))
        var changed = input
        changed.rules.starterDoses!["size"]![rdl]!.maximumRepCeiling = 19
        #expect(throws: EngineError.self) {
            try starterContextKey(state: changed.state, prescription: changed.state.activePrescription,
                variantID: changed.state.config.activeVariantIDs![rdl]!, rules: changed.rules)
        }
        guard case .rejected = advanceStarterProgram(changed) else { Issue.record("Tampered rules admitted"); return }
        var stale = input.state.activePrescription; stale.exercises[0].sets[0].targetReps = 11
        #expect(throws: EngineError.self) { try starterContextKey(state: input.state, prescription: stale,
            variantID: input.state.config.activeVariantIDs![rdl]!, rules: input.rules) }
    }
}

extension StarterProgressionTests {
    @Test(arguments: [Goal.size, .strength], ["db_romanian_deadlift", "incline_db_press_30", "chest_supported_db_row_30_neutral", "suitcase_db_squat"])
    func everyEligibleSizeStrengthMovementPromotesOnce(_ goal: Goal, _ base: String) throws {
        var state = try starterState(goal: goal, slotID: base == "suitcase_db_squat" ? "THU" : "SUN")
        let slot = state.activePrescription.slotID
        let id = state.config.activeVariantIDs![base]!
        if goal == .strength && base != rdl {
            let load = state.config.movements.first { $0.id == base }!.availableLoads[9]
            state.exercises[id]!.load = load
            try starterRefresh(&state)
            state = try reconfigureProgram(state: state, change: .reviewStrengthHandling(variantID: id, choice: .lowRep(load: load)),
                rules: starterRules(state), nextWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: slot)).state
        }
        let first = goal == .size ? [10, 9] : base == rdl ? [8, 7] : [5, 4]
        let second = goal == .size ? [10, 10] : base == rdl ? [8, 8] : [5, 5]
        let promoted = goal == .size ? [10, 10, 9] : base == rdl ? [8, 8, 7] : [5, 5, 4]
        try starterSet(&state, base: base, targets: first)
        state = try starterApplied(starterInput(state, actuals: [base: first], nextSlot: slot))
        state = try starterApplied(starterInput(state, actuals: [base: second], nextSlot: slot))
        #expect(state.exercises[id]!.normalSets == 3 && state.exercises[id]!.mode == .baseline)
        #expect(state.exercises[id]!.exactRepState!.normalTargets == promoted)
        #expect(state.exercises[id]!.load?.amount == "50")
        #expect(state.exercises[id]!.starterState!.windows.isEmpty)
    }

    @Test func reviewedStrengthGroupCannotExtendPastEightAndStricterReservePersists() throws {
        var state = try starterState(goal: .strength)
        let base = "incline_db_press_30"
        let id = state.config.activeVariantIDs![base]!
        state.exercises[id]!.load = state.config.movements.first { $0.id == base }!.availableLoads[3]
        try starterRefresh(&state)
        let slot = WorkoutSlot(date: state.activePrescription.date, slotID: "SUN")
        state = try reconfigureProgram(state: state, change: .reviewStrengthHandling(variantID: id,
            choice: .lowRep(load: state.exercises[id]!.load!)), rules: starterRules(state), nextWorkout: slot).state
        state = try reconfigureProgram(state: state, change: .minimumRir(baseMovementID: base, value: 5),
            rules: starterRules(state), nextWorkout: slot).state
        try starterSet(&state, base: base, targets: [6, 6, 6], load: "20", established: true)
        for _ in 0..<2 { state = try starterApplied(starterInput(state, actuals: [base: [6, 6, 6]], nextSlot: "SUN")) }
        #expect(state.exercises[id]!.repCeiling == 8 && state.exercises[id]!.load?.amount == "20")
        state.exercises[id]!.exactRepState!.normalTargets = [8, 8, 8]
        state.exercises[id]!.starterState!.windows = [:]
        try starterRefresh(&state)
        for _ in 0..<2 { state = try starterApplied(starterInput(state, actuals: [base: [8, 8, 8]], nextSlot: "SUN")) }
        #expect(state.exercises[id]!.repCeiling == 8)
        #expect(state.activePrescription.exercises.first { $0.movementID == id }!.sets.allSatisfy {
            $0.effortInstruction.contains("at least 5 good reps left")
        })
    }

    @Test func introHelperRejectsUnequalSidesAndUnconfirmedResistance() throws {
        let input = try starterPromotionInput()
        let id = input.state.config.activeVariantIDs![rdl]!
        let original = input.state.exercises[id]!
        let key = original.starterState!.windows.keys.first!
        let dose = try resolveMovementDose(config: input.state.config, variantID: id, exercise: original, rules: input.rules)
        for fault in ["sides", "load", "duplicate"] {
            var exercise = original
            var observation = original.starterState!.windows[key]!.exposures[0]
            observation.date = input.event.date
            observation.eventID = input.event.eventID
            if fault == "sides" {
                observation.actualSets[0].leftReps = 12
                observation.actualSets[0].rightReps = 11
                observation.log!.actualSets = observation.actualSets
            } else if fault == "load" {
                exercise.load = nil
                observation.load = nil
                observation.log!.actualLoad = nil
                observation.exactRepContext!.load = nil
                exercise.starterState!.windows[key]!.context.load = nil
            } else {
                observation = original.starterState!.windows[key]!.exposures[0]
            }
            #expect(try !applyStarterIntroductoryDose(exercise: &exercise, dose: dose,
                observation: observation, windowKey: key))
            #expect(exercise.normalSets == 2)
        }
    }
}

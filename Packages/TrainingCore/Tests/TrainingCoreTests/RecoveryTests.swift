import Testing
@testable import TrainingCore

struct RecoveryTests {
    @Test(arguments: [27, 28])
    func interruptionUsesCalendarBoundary(days: Int) throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C03")
        input.state.exercises["example_lift"]?.lastCompletedDate = try input.event.date.adding(days: -days)
        guard case let .applied(state, _, decisions) = advanceProgram(input) else { Issue.record("Expected applied"); return }
        #expect(state.exercises["example_lift"]?.interruptedReturn == (days == 28))
        #expect(decisions[0].ruleIDs == (days == 28 ? ["R05"] : ["R11"]))
    }

    @Test func tooHardBaselineRetreatsWithoutConfirmation() throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C23")
        input.event.exercises[0].finalEffort = .tooHard
        guard case let .applied(state, _, decisions) = advanceProgram(input) else { Issue.record("Expected applied"); return }
        #expect(state.exercises["example_lift"]?.load?.amount == "38")
        #expect(state.exercises["example_lift"]?.mode == .baseline)
        #expect(state.exercises["example_lift"]?.recentComparable == [])
        #expect(decisions[0].ruleIDs == ["R06"])
    }

    @Test func oneSetRecoveryStrainPausesForReview() throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C40")
        input.state.exercises["example_lift"]?.nextSetOverride = 1
        input.state.activePrescription.exercises[0].sets.removeLast()
        input.state.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(input.state.activePrescription))
        input.event.prescriptionID = input.state.activePrescription.id
        input.event.plannedPrescriptionID = input.state.activePrescription.id
        input.event.exercises[0].prescriptionID = input.state.activePrescription.id
        input.event.exercises[0].actualSets = [ActualSet(reps: 7)]
        input.event.exercises[0].finalEffort = .tooHard
        guard case let .applied(state, workout, decisions) = advanceProgram(input) else { Issue.record("Expected applied"); return }
        #expect(state.exercises["example_lift"]?.mode == .paused)
        #expect(workout.exercises[0].sets == [])
        #expect(decisions[0].ruleIDs == ["R09"])
    }
}

extension RecoveryTests {
    @Test func gapThenReturnResolvesAppWithoutExtraBaselineGate() throws {
        let inputBase = try appInput(ceilingStreak: 1)
        var input = inputBase
        let id = input.state.config.activeVariantIDs!["banded_pullups"]!
        input.state.exercises[id]!.lastCompletedDate = try input.event.date.adding(days: -28)
        var gap = input.state.exercises[id]!
        gap.mode = .baseline
        gap.ceilingStreak = 0
        gap.strainStreak = 0
        gap.nextSetOverride = 2
        gap.interruptedReturn = true
        gap.recentComparable = []
        let gapExpected = try appGolden(input, target: id, after: gap, action: .recover, rules: ["R05"], key: "interruption_return")
        #expect(advanceProgram(input) == gapExpected)
        guard case let .applied(state, _, _) = gapExpected else { return }
        let returnInput = try appEvent(state: state, rules: input.rules, target: id, eventID: "return")
        var returned = state.exercises[id]!
        returned.mode = .normal
        returned.nextSetOverride = nil
        returned.interruptedReturn = false
        let expected = try appGolden(returnInput, target: id, after: returned, action: .recover,
            rules: ["R05"], key: "interruption_return_complete")
        #expect(advanceProgram(returnInput) == expected)
        guard case let .applied(final, workout, _) = expected else { return }
        #expect(final.exercises[id]!.recentComparable.isEmpty && workout.exercises.first { $0.movementID == id }!.phase == .normal)
    }

    @Test func archivedGapThenReturnKeepsBaselinePerOriginalRulesVersion() throws {
        let input = try FixtureCompiler.advanceInput(caseID: "C28")
        guard case let .applied(state, _, _) = try FixtureCompiler.expectedAdvanceResult(caseID: "C28") else { return }
        var next = input
        next.state = state
        next.event = CompletedWorkout(eventID: "archived-return", date: state.activePrescription.date,
            slotID: state.activePrescription.slotID, prescriptionID: state.activePrescription.id,
            plannedPrescriptionID: state.activePrescription.id, sessionMode: .normal,
            exercises: [ExerciseLog(movementID: "example_lift", prescriptionID: state.activePrescription.id, status: .completed,
                actualLoad: state.exercises["example_lift"]!.load, actualSets: [ActualSet(reps: 10), ActualSet(reps: 10)], finalEffort: .onTarget, problem: .none)])
        next.nextSlotID = "THU"
        next.nextWorkoutDate = try next.event.date.adding(days: 2)
        var after = state.exercises["example_lift"]!
        after.nextSetOverride = nil
        after.interruptedReturn = false
        after.lastCompletedDate = next.event.date
        let expected = try legacyGolden(next, after: after, action: .recover, rules: ["R05"], key: "interruption_return_complete")
        #expect(advanceProgram(next) == expected)
        #expect(after.mode == .baseline && after.ceilingStreak == 0)
    }

    @Test func nonnumericTwoSetbacksReduceDoseAndRequestManualReview() throws {
        var input = try appInput()
        let id = input.state.config.activeVariantIDs!["banded_pullups"]!
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        input.state.exercises[id]!.strainStreak = 1
        input.event.exercises[row].finalEffort = .tooHard
        var after = input.state.exercises[id]!
        after.strainStreak = 0
        after.nextSetOverride = 2
        let expected = try appGolden(input, target: id, after: after, action: .recover, rules: ["R08"], key: "recovery_dose",
            notices: [("manual_setup_limit", ["R08"])])
        #expect(advanceProgram(input) == expected)
        #expect(after.load == nil && after.normalSets == 3)
    }

    @Test func ineligibleReturnKeepsUnresolvedRecoveryFlagsAndNoComparisons() throws {
        var input = try appInput()
        let id = input.state.config.activeVariantIDs!["banded_pullups"]!
        input.state.exercises[id]!.mode = .baseline
        input.state.exercises[id]!.interruptedReturn = true
        input.state.exercises[id]!.nextSetOverride = 2
        input.state.activePrescription = try FixtureCompiler.expectedWorkout(state: input.state,
            date: input.event.date, slotID: input.event.slotID)
        input = try appEvent(state: input.state, rules: input.rules, target: id)
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        input.event.exercises[row].status = .partial
        input.event.exercises[row].actualSets.removeLast()
        let after = input.state.exercises[id]!
        let expected = try appGolden(input, target: id, after: after, action: .recover, rules: ["R05"], key: "interruption_return_pending")
        #expect(advanceProgram(input) == expected)
        #expect(after.lastCompletedDate == nil && after.interruptedReturn && after.recentComparable.isEmpty)
    }
}

extension RecoveryTests {
    @Test func baselineFloorMissWithNonHardEffortDoesNotInventRetreat() throws {
        var input = try FixtureCompiler.advanceInput(caseID: "C23")
        input.event.exercises[0].actualSets = [ActualSet(reps: 7), ActualSet(reps: 7), ActualSet(reps: 7)]
        var after = input.state.exercises["example_lift"]!
        after.load = input.event.exercises[0].actualLoad
        after.lastCompletedDate = input.event.date
        let expected = try legacyGolden(input, after: after, action: .baseline, rules: ["R06"], key: "baseline_pending")
        #expect(advanceProgram(input) == expected)
    }

    @Test func changedLoadDuringPendingAppReturnCannotCompleteReturnOrBaseline() throws {
        var input = try appInput(base: "incline_db_press_24", mode: .baseline, amount: "50")
        let id = input.state.config.activeVariantIDs!["incline_db_press_24"]!
        input.state.exercises[id]!.interruptedReturn = true
        input.state.exercises[id]!.nextSetOverride = 2
        input.state.activePrescription = try FixtureCompiler.expectedWorkout(state: input.state, date: input.event.date, slotID: input.event.slotID)
        input = try appEvent(state: input.state, rules: input.rules, target: id)
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        input.event.exercises[row].actualLoad!.amount = "55"
        var after = input.state.exercises[id]!
        after.load = input.event.exercises[row].actualLoad
        let expected = try appGolden(input, target: id, after: after, action: .recover, rules: ["R05"], key: "interruption_return_pending")
        #expect(advanceProgram(input) == expected)
    }
}

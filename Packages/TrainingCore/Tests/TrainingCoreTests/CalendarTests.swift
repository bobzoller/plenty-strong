import Foundation
import Testing
@testable import TrainingCore

struct CalendarTests {
    @Test(arguments: [("2026-10-05", "2026-10-06", "TUE"), ("2026-10-06", "2026-10-06", "TUE"), ("2026-10-09", "2026-10-11", "SUN"), ("2024-02-29", "2024-02-29", "THU")])
    func calendarUsesFixedWeekdays(input: String, expected: String, slot: String) throws {
        let config = try selectFixedProgram(goal: .size, programID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)
        #expect(try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: input), config: config) == WorkoutSlot(date: LocalDate(iso8601: expected), slotID: slot))
    }

    @Test func rescheduleInvalidatesPendingIDWithoutInventingHistory() throws {
        let (state, rules, _, _) = try configurationInput()
        let slot = try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-05"), config: state.config)
        let result = try reschedulePendingWorkout(state: state, slot: slot, rules: rules)
        #expect(result.workout.id != state.activePrescription.id)
        #expect(result.workout.date == slot.date && result.workout.slotID == "TUE")
        #expect(result.state.exercises == state.exercises)
        #expect(result.state.processedEvents == state.processedEvents)
        #expect(result.state.lastSessionDate == state.lastSessionDate)
        #expect(result.state.revision == state.revision + 1)
        #expect(try reschedulePendingWorkout(state: result.state, slot: slot, rules: rules).state == result.state)
    }

    @Test func completionAndBackwardDateNeverScheduleSecondWorkoutSameDay() throws {
        var (state, rules, slot, _) = try configurationInput()
        state.lastSessionDate = slot.date
        #expect(throws: EngineError.self) { try reschedulePendingWorkout(state: state, slot: slot, rules: rules) }
        let future = try WorkoutScheduler.nextSlot(after: slot.date, config: state.config)
        #expect(future.date > slot.date)
        #expect(try reschedulePendingWorkout(state: state, slot: future, rules: rules).workout.date == future.date)
        let backwards = WorkoutSlot(date: try slot.date.adding(days: -7), slotID: slot.slotID)
        #expect(throws: EngineError.self) { try reschedulePendingWorkout(state: state, slot: backwards, rules: rules) }
    }

    @Test(arguments: [27, 28])
    func explicitInterruptionBoundaryIsIdempotentAndDoesNotCreateEvent(days: Int) throws {
        var (state, rules, slot, id) = try configurationInput()
        state.exercises[id]!.lastCompletedDate = try slot.date.adding(days: -days)
        let result = try prepareInterruptedReturn(state: state, asOf: slot.date, rules: rules)
        #expect(result.state.exercises[id]!.interruptedReturn == (days == 28))
        #expect(result.state.processedEvents == state.processedEvents)
        #expect(result.state.lastSessionDate == state.lastSessionDate)
        #expect(result.state.exercises[id]!.lastCompletedDate == state.exercises[id]!.lastCompletedDate)
        if days == 28 {
            #expect(result.state.exercises[id]!.mode == .baseline)
            #expect(result.state.exercises[id]!.nextSetOverride == 2)
            #expect(result.state.exercises[id]!.ceilingStreak == 0)
            #expect(result.decisions.first!.ruleIDs == ["R05"])
        } else { #expect(result.state == state && result.decisions.isEmpty) }
        #expect(try prepareInterruptedReturn(state: result.state, asOf: slot.date, rules: rules).state == result.state)
    }

    @Test func backwardInterruptionDateRejectsAndPauseRemainsAuthoritative() throws {
        var (state, rules, slot, id) = try configurationInput()
        state.exercises[id]!.lastCompletedDate = slot.date
        #expect(throws: EngineError.self) { try prepareInterruptedReturn(state: state, asOf: slot.date.adding(days: -1), rules: rules) }
        state.exercises[id]!.lastCompletedDate = try slot.date.adding(days: -28)
        state.baseSafety!["banded_pullups"]!.paused = true
        state.exercises[id]!.mode = .paused
        state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: slot.date, slotID: slot.slotID)
        let result = try prepareInterruptedReturn(state: state, asOf: slot.date, rules: rules)
        #expect(result.state.exercises[id]!.mode == .paused)
        #expect(result.state.baseSafety == state.baseSafety)
        #expect(result.workout.exercises.first { $0.movementID == id }!.sets.isEmpty)
    }

    @Test func suppliedTimezoneHandlesDSTTravelAndMidnightWithoutRewritingDates() throws {
        let ny = try CalendarContext(timeZoneID: "America/New_York")
        let hi = try CalendarContext(timeZoneID: "Pacific/Honolulu")
        let parser = ISO8601DateFormatter()
        for instant in ["2026-03-08T06:59:00Z", "2026-03-08T07:01:00Z"] {
            #expect(try ny.localDate(at: parser.date(from: instant)!) == LocalDate(iso8601: "2026-03-08"))
        }
        for instant in ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            #expect(try ny.localDate(at: parser.date(from: instant)!) == LocalDate(iso8601: "2026-11-01"))
        }
        let travel = parser.date(from: "2026-10-06T05:00:00Z")!
        #expect(try hi.localDate(at: travel) == LocalDate(iso8601: "2026-10-05"))
        #expect(try ny.localDate(at: travel) == LocalDate(iso8601: "2026-10-06"))
        let start = try hi.localDate(at: parser.date(from: "2026-10-06T09:59:00Z")!)
        let finish = try hi.localDate(at: parser.date(from: "2026-10-06T10:01:00Z")!)
        #expect(start == (try LocalDate(iso8601: "2026-10-05")))
        #expect(finish == (try LocalDate(iso8601: "2026-10-06")))
        // This verifies only conversion. Persisted started-draft midnight behavior belongs to O6/O7.
        #expect(throws: EngineError.self) { try CalendarContext(timeZoneID: "invalid-zone") }
    }
}

extension CalendarTests {
    @Test func mismatchedAppSlotDateRejectsAtEveryBoundaryWithoutMutation() throws {
        let (state, rules, slot, id) = try configurationInput()
        let original = state
        let bad = WorkoutSlot(date: try slot.date.adding(days: 1), slotID: slot.slotID)
        #expect(throws: EngineError.self) { try initializeProgram(config: state.config, rules: rules, firstWorkout: bad) }
        #expect(throws: EngineError.self) { try reschedulePendingWorkout(state: state, slot: bad, rules: rules) }
        #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: .resetSetup(variantID: id), rules: rules, nextWorkout: bad) }
        #expect(throws: EngineError.self) { try changeMovementVariant(state: state, change: .create(baseMovementID: "banded_pullups", variantID: "bad", modifications: "Setup"), rules: rules, nextWorkout: bad) }
        var tampered = state
        tampered.activePrescription.date = bad.date
        tampered.activePrescription.id = try CanonicalJSON.sha256(FixtureCompiler.prescriptionContent(tampered.activePrescription))
        #expect(throws: EngineError.self) { try prepareWorkout(state: tampered, rules: rules) }
        #expect(throws: EngineError.self) { try plannedWorkout(state: state, rules: rules, slot: bad) }
        var input = try appEvent(state: state, rules: rules, target: id)
        input.nextWorkoutDate = bad.date
        #expect(advanceProgram(input) == .rejected(nextState: state, errors: ["invalid_slot_date"]))
        #expect(state == original)
    }
}

extension CalendarTests {
    @Test func explicitAdapterReturnResolvesByPinnedRulesVersion() throws {
        var (app, rules, slot, id) = try configurationInput()
        app.exercises[id]!.lastCompletedDate = try slot.date.adding(days: -28)
        let appPending = try prepareInterruptedReturn(state: app, asOf: slot.date, rules: rules)
        let appInput = try appEvent(state: appPending.state, rules: rules, target: id)
        guard case let .applied(appReturned, _, _) = advanceProgram(appInput) else { Issue.record("Expected app return"); return }
        #expect(appReturned.exercises[id]!.mode == .normal)
        #expect(!appReturned.exercises[id]!.interruptedReturn && appReturned.exercises[id]!.nextSetOverride == nil)
        #expect(appReturned.exercises[id]!.recentComparable.isEmpty)
        var numeric = try FixtureCompiler.advanceInput(caseID: "C03")
        numeric.state.exercises["example_lift"]!.lastCompletedDate = try numeric.event.date.adding(days: -28)
        let pending = try prepareInterruptedReturn(state: numeric.state, asOf: numeric.event.date, rules: numeric.rules)
        numeric.state = pending.state
        numeric.event.prescriptionID = pending.workout.id
        numeric.event.plannedPrescriptionID = pending.workout.id
        numeric.event.exercises[0].prescriptionID = pending.workout.id
        numeric.event.exercises[0].actualSets = Array(repeating: ActualSet(reps: 12), count: 2)
        guard case let .applied(returned, _, _) = advanceProgram(numeric) else { Issue.record("Expected archived return"); return }
        #expect(returned.exercises["example_lift"]!.mode == .baseline)
        #expect(!returned.exercises["example_lift"]!.interruptedReturn && returned.exercises["example_lift"]!.nextSetOverride == nil)
        #expect(returned.exercises["example_lift"]!.recentComparable.isEmpty)
        #expect(returned.rulesetHash == numeric.state.rulesetHash)
    }
}

extension CalendarTests {
    @Test(arguments: ["unknownLoad", "changedLoad", "unknownEffort", "tooHard", "partial", "easier"])
    func preparedReturnRequiresCleanKnownSameLoadNormalWork(condition: String) throws {
        let original = try appInput(base: "incline_db_press_24", amount: "50")
        var state = original.state
        let id = state.config.activeVariantIDs!["incline_db_press_24"]!
        state.exercises[id]!.lastCompletedDate = try state.activePrescription.date.adding(days: -28)
        let prepared = try prepareInterruptedReturn(state: state, asOf: state.activePrescription.date, rules: original.rules)
        var input = try appEvent(state: prepared.state, rules: original.rules, target: id, easier: condition == "easier")
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        switch condition {
        case "unknownLoad": input.event.exercises[row].actualLoad = nil
        case "changedLoad": input.event.exercises[row].actualLoad = Load(amount: "55", unit: .lb, basis: .perImplement)
        case "unknownEffort": input.event.exercises[row].finalEffort = .unknown
        case "tooHard": input.event.exercises[row].finalEffort = .tooHard
        case "partial": input.event.exercises[row].status = .partial; input.event.exercises[row].actualSets.removeLast()
        default: break
        }
        guard case let .applied(result, _, _) = advanceProgram(input) else { Issue.record("Expected ineligible return recorded"); return }
        #expect(result.exercises[id]!.interruptedReturn)
        #expect(result.exercises[id]!.nextSetOverride == 2)
        #expect(result.exercises[id]!.recentComparable.isEmpty)
        #expect(result.exercises[id]!.load?.amount == (condition == "changedLoad" ? "55" : "50"))
    }
}

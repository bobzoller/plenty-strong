import Foundation
import Testing
@testable import TrainingCore

struct FlexibleSchedulingTests {
    @Test func flexibleActivationHasExplicitReplayableWireKind() throws {
        let bytes = Data(#"{"kind":"activateFlexibleScheduling"}"#.utf8)
        // An unrecognized command means old replay must stay old; enabling this
        // behavior needs an admitted, journaled command rather than an app clock.
        let command = try? JSONDecoder().decode(JournalCommand.self, from: bytes)
        #expect(command != nil)
        if let command {
            #expect(try CanonicalJSON.encode(exactCanonical(command)) == bytes)
        }
    }
}

extension FlexibleSchedulingTests {
    @Test(arguments: ["starter-upper", "starter-glute", "schema3-exact"])
    func selectingRecentVariantWaitsForActualDateInsteadOfFutureSuggestion(policy: String) throws {
        let rules: Ruleset
        var state: ProgramState
        if policy == "schema3-exact" {
            rules = try RulesetCatalog.exactV1()
            state = try initializeProgram(config: selectFixedProgram(goal: .size, programID: UUID()), rules: rules,
                firstWorkout: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")).state
        } else {
            state = try starterState(choice: policy == "starter-upper" ? .upperBody : .wholeBodyGlutes)
            rules = try starterRules(state)
        }
        let base = state.activePrescription.exercises[0].baseMovementID!
        let id = state.config.activeVariantIDs![base]!
        let movement = state.config.movements.first { $0.id == base }!
        let actualDate = try LocalDate(iso8601: "2026-10-11")
        let issued = WorkoutSlot(date: try actualDate.adding(days: rules.parameters!.interruptionDays), slotID: "SUN")
        state.exercises[id]!.load = movement.availableLoads.first { $0.amount == "50" }
        state.exercises[id]!.mode = .normal
        state.exercises[id]!.lastCompletedDate = actualDate
        state.exercises[id]!.exactRepState!.lastSuitableNormalDate = actualDate
        state.lastSessionDate = actualDate
        state.activePrescription = try plannedWorkout(state: state, rules: rules, slot: issued)
        let legacy = state
        state = try activateFlexibleScheduling(state: state, rules: rules).state
        func selectOriginal(_ input: ProgramState) throws -> ConfigurationResult {
            let created = try changeMovementVariant(state: input,
                change: .create(baseMovementID: base, variantID: "different-grip", modifications: "Different grip"),
                rules: rules, nextWorkout: issued)
            return try changeMovementVariant(state: created.state,
                change: .select(baseMovementID: base, variantID: id), rules: rules, nextWorkout: issued)
        }
        let selected = try selectOriginal(state)
        #expect(!selected.state.exercises[id]!.interruptedReturn)
        #expect(selected.state.exercises[id]!.load == state.exercises[id]!.load)
        #expect(selected.state.exercises[id]!.normalSets == state.exercises[id]!.normalSets)
        #expect(selected.state.exercises[id]!.exactRepState!.lastSuitableNormalDate == actualDate)
        #expect(selected.workout.date == issued.date && selected.workout.slotID == issued.slotID)
        let current = try prepareInterruptedReturn(state: selected.state, asOf: actualDate.adding(days: 1), rules: rules)
        #expect(!current.state.exercises[id]!.interruptedReturn)
        let onGap = try prepareInterruptedReturn(state: current.state, asOf: issued.date, rules: rules)
        #expect(onGap.state.exercises[id]!.interruptedReturn)
        #expect(try selectOriginal(legacy).state.exercises[id]!.interruptedReturn)
    }
}

extension FlexibleSchedulingTests {
    @Test(arguments: [StarterProgramChoice.upperBody, .wholeBodyGlutes])
    func actualEarlyAndLateDatesDriveProgressionWithoutChangingRotation(choice: StarterProgramChoice) throws {
        for actual in ["2026-10-09", "2026-10-14"] {
            let original = try starterState(choice: choice)
            let state = try activateFlexibleScheduling(state: original, rules: starterRules(original)).state
            var event = try starterCompletion(state: state, actualsByBase: [:])
            event.date = try LocalDate(iso8601: actual)
            let instant = ISO8601DateFormatter().date(from: "\(actual)T20:00:00Z")!
            let millis = try SessionTiming.milliseconds(at: instant)
            event.timing = SessionTiming(plannedDate: original.activePrescription.date, startedAtMilliseconds: millis,
                finishedAtMilliseconds: millis + 3_600_000, timeZoneID: "Pacific/Honolulu")
            let next = try LocalDate(iso8601: actual == "2026-10-09" ? "2026-10-13" : "2026-10-15")
            let result = advanceProgram(AdvanceInput(state: state, event: event, rules: try starterRules(state),
                nextSlotID: "TUE", nextWorkoutDate: next))
            guard case let .applied(after, pending, _) = result else {
                Issue.record("Flexible completion must apply"); continue
            }
            #expect(after.lastSessionDate == event.date)
            #expect(pending.slotID == "TUE" && pending.date == next)
            #expect(pending.exercises.map(\.baseMovementID) == state.config.weeklySlots[1].movementIDs.map(Optional.some))
            #expect(after.processedEvents.count == 1)
        }
    }
}

extension FlexibleSchedulingTests {
    @Test func cadenceAndRotationAreIndependentAndLegacySlotsStayStrict() throws {
        let config = try starterState().config
        let thursday = try LocalDate(iso8601: "2026-10-15")
        let tuesdayOnThursday = WorkoutSlot(date: thursday, slotID: "TUE")
        #expect(throws: EngineError.self) { try WorkoutScheduler.validate(slot: tuesdayOnThursday, config: config) }
        try WorkoutScheduler.validate(slot: tuesdayOnThursday, config: config, schedulingPolicy: .flexibleV1)
        #expect(try WorkoutScheduler.nextRotation(after: LocalDate(iso8601: "2026-10-14"), consumedSlotID: "SUN", config: config) == tuesdayOnThursday)
        #expect(try WorkoutScheduler.nextRotation(after: thursday, consumedSlotID: "TUE", config: config) == WorkoutSlot(date: LocalDate(iso8601: "2026-10-18"), slotID: "THU"))
        #expect(throws: EngineError.self) {
            try WorkoutScheduler.validate(slot: WorkoutSlot(date: LocalDate(iso8601: "2026-10-16"), slotID: "TUE"), config: config, schedulingPolicy: .flexibleV1)
        }
    }
    @Test func actualSuitableEvidenceUsesEarlySessionDateAndGapUsesIt() throws {
        var state = try starterState(choice: .upperBody)
        let base = "banded_pullups"
        let id = state.config.activeVariantIDs![base]!
        // Planned Sunday is at the interruption boundary, Friday is before it.
        let rules = try starterRules(state)
        let prior = try state.activePrescription.date.adding(days: -rules.parameters!.interruptionDays)
        let targets = Array(repeating: 8, count: state.exercises[id]!.normalSets)
        try starterSet(&state, base: base, targets: targets, load: "50")
        state.exercises[id]!.exactRepState!.lastSuitableNormalDate = prior
        state = try activateFlexibleScheduling(state: state, rules: rules).state
        let real = ISO8601DateFormatter().date(from: "2026-10-09T20:00:00Z")!
        let millis = try SessionTiming.milliseconds(at: real)
        var event = try starterCompletion(state: state, actualsByBase: [base: targets])
        event.date = try LocalDate(iso8601: "2026-10-09")
        event.timing = SessionTiming(plannedDate: state.activePrescription.date, startedAtMilliseconds: millis,
            finishedAtMilliseconds: millis + 1000, timeZoneID: "Pacific/Honolulu")
        let next = try WorkoutScheduler.nextRotation(after: state.activePrescription.date, consumedSlotID: "SUN", config: state.config)
        let after = try starterApplied(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date))
        #expect(after.lastSessionDate == event.date)
        #expect(after.exercises[id]!.lastCompletedDate == event.date)
        #expect(after.exercises[id]!.exactRepState!.lastSuitableNormalDate == event.date)
        #expect(after.exercises[id]!.starterState!.windows.values.first?.exposures.first?.date == event.date)
        #expect(!after.exercises[id]!.interruptedReturn)
        let beforeGap = try prepareInterruptedReturn(state: after, asOf: event.date.adding(days: rules.parameters!.interruptionDays - 1), rules: rules)
        #expect(!beforeGap.state.exercises[id]!.interruptedReturn)
        let onGap = try prepareInterruptedReturn(state: after, asOf: event.date.adding(days: rules.parameters!.interruptionDays), rules: rules)
        #expect(onGap.state.exercises[id]!.interruptedReturn)
    }
    @Test func invalidTimingRotationAndDuplicateLocalDateCannotAdvance() throws {
        let old = try starterState()
        let rules = try starterRules(old)
        var state = try activateFlexibleScheduling(state: old, rules: rules).state
        var event = try starterCompletion(state: state, actualsByBase: [:])
        event.date = try LocalDate(iso8601: "2026-10-09")
        let millis = try SessionTiming.milliseconds(at: ISO8601DateFormatter().date(from: "2026-10-09T20:00:00Z")!)
        let timing = SessionTiming(plannedDate: old.activePrescription.date, startedAtMilliseconds: millis,
            finishedAtMilliseconds: millis + 1000, timeZoneID: "Pacific/Honolulu")
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE")
        func rejected(_ input: AdvanceInput) -> Bool { if case .rejected = advanceProgram(input) { true } else { false } }
        #expect(rejected(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)))
        event.timing = timing
        #expect(rejected(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: "THU", nextWorkoutDate: next.date)))
        event.timing!.finishedAtMilliseconds = millis - 1
        #expect(rejected(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)))
        event.timing = timing
        state.lastSessionDate = event.date
        #expect(rejected(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)))
        #expect(rejected(AdvanceInput(state: old, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)))
    }
}

extension FlexibleSchedulingTests {
    @Test(arguments: [StarterProgramChoice.upperBody, .wholeBodyGlutes])
    func repeatedEarlySessionsNeverUseDistantSuggestionAsCapacityClock(choice: StarterProgramChoice) throws {
        var state = try starterState(choice: choice)
        let rules = try starterRules(state)
        for (id, variant) in state.config.variants! {
            let movement = state.config.movements.first { $0.id == variant.baseMovementID }!
            state.exercises[id]!.load = movement.loadingMode == .externalLoad ? movement.availableLoads.first : nil
        }
        try starterRefresh(&state)
        state = try activateFlexibleScheduling(state: state, rules: rules).state
        var actualDate = try LocalDate(iso8601: "2026-10-09")
        for _ in 0..<24 {
            let displayed = state.activePrescription
            let actuals = Dictionary(uniqueKeysWithValues: displayed.exercises.map { ($0.baseMovementID!, $0.sets.map { $0.targetReps! }) })
            var event = try starterCompletion(state: state, actualsByBase: actuals)
            event.date = actualDate
            event.eventID = "early-\(actualDate.iso8601)"
            let start = try SessionTiming.milliseconds(at: ISO8601DateFormatter().date(from: "\(actualDate.iso8601)T20:00:00Z")!)
            event.timing = SessionTiming(plannedDate: displayed.date, startedAtMilliseconds: start,
                finishedAtMilliseconds: start + 1000, timeZoneID: "Pacific/Honolulu")
            let next = try WorkoutScheduler.nextRotation(after: displayed.date, consumedSlotID: displayed.slotID, config: state.config)
            state = try starterApplied(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date))
            #expect(!state.exercises.values.contains { $0.interruptedReturn })
            actualDate = try actualDate.adding(days: 1)
        }
        #expect(state.lastSessionDate!.days(until: state.activePrescription.date) >= rules.parameters!.interruptionDays)
        let prepared = try prepareInterruptedReturn(state: state, asOf: actualDate, rules: rules)
        #expect(prepared.state == state)
        #expect(try prepareWorkout(state: state, rules: rules) == state.activePrescription)
    }
}

extension FlexibleSchedulingTests {
    @Test func configurationAndRescheduleCannotConsumeFlexiblePendingWorkout() throws {
        let old = try starterState()
        let rules = try starterRules(old)
        let state = try activateFlexibleScheduling(state: old, rules: rules).state
        let later = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE")
        #expect(throws: EngineError.self) { try reschedulePendingWorkout(state: state, slot: later, rules: rules) }
        #expect(throws: EngineError.self) { try reconfigureProgram(state: state, change: .goal(.maintenance), rules: rules, nextWorkout: later) }
        let same = WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID)
        let changed = try reconfigureProgram(state: state, change: .goal(.maintenance), rules: rules, nextWorkout: same)
        #expect(changed.state.activePrescription.date == same.date && changed.state.activePrescription.slotID == same.slotID)
    }
}

extension FlexibleSchedulingTests {
    @Test(arguments: [StarterProgramChoice.upperBody, .wholeBodyGlutes])
    func recoveryKeepsTuesdayRotationOnThursdayCadenceAndMovesDateOnlyForHistory(choice: StarterProgramChoice) throws {
        let old = try starterState(choice: choice)
        let rules = try starterRules(old)
        let common = try activateFlexibleScheduling(state: old, rules: rules).state
        var selected = common
        selected.lastSessionDate = try LocalDate(iso8601: "2026-10-14")
        selected.revision += 1
        try starterRefresh(&selected, slotID: "TUE", date: LocalDate(iso8601: "2026-10-15"))
        var other = selected
        other.revision += 1
        other.lastSessionDate = try LocalDate(iso8601: "2026-10-15")
        try starterRefresh(&other, slotID: "THU", date: LocalDate(iso8601: "2026-10-18"))
        let selectedPending = WorkoutSlot(date: selected.activePrescription.date, slotID: "TUE")
        #expect(try WorkoutScheduler.pendingAfterRecovery(state: selected, latestSessionDate: selected.lastSessionDate) == selectedPending)
        let next = try WorkoutScheduler.pendingAfterRecovery(state: selected, latestSessionDate: other.lastSessionDate)
        #expect(next == WorkoutSlot(date: try LocalDate(iso8601: "2026-10-18"), slotID: "TUE"))
        let input = BranchResolutionInput(commonAncestor: common, competingHeadHashes: ["selected", "other"],
            branches: [VerifiedBranch(headHash: "selected", state: selected, commands: []), VerifiedBranch(headHash: "other", state: other, commands: [])],
            selection: BranchSelection(selectedHeadHash: "selected"), rules: rules, next: next)
        let resolved = try resolveCloudBranches(input)
        #expect(resolved.workout.slotID == "TUE")
        #expect(resolved.workout.exercises.map(\.baseMovementID) == selected.activePrescription.exercises.map(\.baseMovementID))
        var wrong = input
        wrong.next.slotID = "SUN"
        #expect(throws: EngineError.self) { try resolveCloudBranches(wrong) }
    }
}

extension FlexibleSchedulingTests {
    @Test(arguments: [StarterProgramChoice.upperBody, .wholeBodyGlutes])
    func recoveryRejectsUnnecessarilyDistantSuggestionForSelectedGroup(choice: StarterProgramChoice) throws {
        let old = try starterState(choice: choice)
        let rules = try starterRules(old)
        let common = try activateFlexibleScheduling(state: old, rules: rules).state
        var selected = common
        selected.lastSessionDate = try LocalDate(iso8601: "2026-10-14")
        selected.revision += 1
        try starterRefresh(&selected, slotID: "TUE", date: LocalDate(iso8601: "2026-10-15"))
        let branches = [VerifiedBranch(headHash: "selected", state: selected, commands: []), VerifiedBranch(headHash: "other", state: selected, commands: [])]
        let unchanged = WorkoutSlot(date: selected.activePrescription.date, slotID: "TUE")
        var input = BranchResolutionInput(commonAncestor: common, competingHeadHashes: ["selected", "other"], branches: branches,
            selection: BranchSelection(selectedHeadHash: "selected"), rules: rules, next: unchanged)
        #expect(try resolveCloudBranches(input).workout.date == unchanged.date)
        input.next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-25"), slotID: "TUE")
        // Moving this suggestion is unnecessary: both branches' actual sessions
        // precede the selected Thursday suggestion. Reject the payload in core,
        // including offline replay, rather than trusting only the caller helper.
        let wronglyAccepted = try? resolveCloudBranches(input)
        let acceptedDistantSuggestion = wronglyAccepted != nil
        #expect(!acceptedDistantSuggestion)
        input.branches[1].state.lastSessionDate = unchanged.date
        try starterRefresh(&input.branches[1].state, slotID: "THU", date: LocalDate(iso8601: "2026-10-18"))
        let skippedFirstCadence = (try? resolveCloudBranches(input)) != nil
        #expect(!skippedFirstCadence)
        input.next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-18"), slotID: "TUE")
        #expect(try resolveCloudBranches(input).workout.date == input.next.date)
    }
}

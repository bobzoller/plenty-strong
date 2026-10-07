import Foundation
import Testing
@testable import TrainingCore

/// Synthetic inputs from O3 initialization; expected O4 transitions are authored
/// explicitly below and expanded without production transition/rule helpers.
func appInput(base: String = "banded_pullups", variant: String? = nil, modifications: String = "",
              mode: ExerciseMode = .normal, amount: String? = nil, ceilingStreak: Int = 0) throws -> AdvanceInput {
    let rules = try RulesetCatalog.fixedV1()
    var config = try selectFixedProgram(goal: .size, programID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    if let variant {
        config.variants![variant] = MovementVariant(id: variant, baseMovementID: base, modifications: modifications)
        config.activeVariantIDs![base] = variant
    }
    let slot = config.weeklySlots.first { $0.movementIDs.contains(base) }!.id
    let date = try LocalDate(iso8601: "2026-10-04").adding(days: config.weeklySlots.first { $0.id == slot }!.weekday!)
    var state = try initializeProgram(config: config, rules: rules, firstWorkout: WorkoutSlot(date: date, slotID: slot)).state
    for (id, saved) in config.variants! {
        let movement = config.movements.first { $0.id == saved.baseMovementID }!
        state.exercises[id]!.mode = .normal
        state.exercises[id]!.load = movement.availableLoads.first
    }
    let id = config.activeVariantIDs![base]!
    state.exercises[id]!.mode = mode
    state.exercises[id]!.load = amount.map { Load(amount: $0, unit: .lb, basis: config.movements.first { $0.id == base }!.availableLoads.first!.basis) }
    state.exercises[id]!.ceilingStreak = ceilingStreak
    state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: date, slotID: slot)
    return try appEvent(state: state, rules: rules, target: id)
}

func appEvent(state: ProgramState, rules: Ruleset, target: String, eventID: String = "app-event", easier: Bool = false) throws -> AdvanceInput {
    let displayed = easier ? try FixtureCompiler.expectedEasier(state: state, rules: rules) : state.activePrescription
    let rows = displayed.exercises.map { p -> ExerciseLog in
        let movement = state.config.movements.first { $0.id == p.baseMovementID }!
        let reps = p.sets.first?.repCeiling ?? 0
        return ExerciseLog(movementID: p.movementID, prescriptionID: displayed.id,
            status: p.movementID == target && p.kind != .paused ? .completed : .skipped,
            actualLoad: p.movementID == target ? p.load : nil,
            actualSets: p.movementID == target && p.kind != .paused ? p.sets.map { _ in ActualSet(reps: reps,
                leftReps: movement.repCounting == .perSide ? reps : nil,
                rightReps: movement.repCounting == .perSide ? reps : nil) } : [],
            finalEffort: p.movementID == target ? .onTarget : .unknown, problem: .none,
            baseMovementID: p.baseMovementID, modificationsSnapshot: p.modificationsSnapshot)
    }
    return AdvanceInput(state: state, event: CompletedWorkout(eventID: eventID, date: displayed.date,
        slotID: displayed.slotID, prescriptionID: displayed.id, plannedPrescriptionID: state.activePrescription.id,
        sessionMode: easier ? .easier : .normal, exercises: rows), rules: rules,
        nextSlotID: state.activePrescription.slotID, nextWorkoutDate: try displayed.date.adding(days: 7))
}

/// Complete expected app result. Every behavior choice is passed explicitly by a
/// policy-authored test; this only assembles values, snapshots, IDs and traces.
func appGolden(_ input: AdvanceInput, target: String, after authored: ExerciseState,
               action: DecisionAction, rules: [String], key: String, append: Bool = false,
               pauseBase: Bool = false, notices: [(String, [String])] = [], completed: Bool? = nil,
               otherRules: [String] = ["R07"], otherKey: String = "skip_recorded") throws -> AdvanceResult {
    var state = input.state
    let displayed = input.event.sessionMode == .easier ? try FixtureCompiler.expectedEasier(state: state, rules: input.rules) : state.activePrescription
    var after = authored
    let targetLog = input.event.exercises.first { $0.movementID == target }!
    // Tests author semantic completion, including partial-side cases, in `authored`.
    if completed ?? (targetLog.status == .completed) { after.lastCompletedDate = input.event.date }
    if append {
        let p = displayed.exercises.first { $0.movementID == target }!
        let movement = state.config.movements.first { $0.id == p.baseMovementID }!
        let exposure = Exposure(eventID: input.event.eventID, date: input.event.date, log: targetLog,
            movementID: target, baseMovementID: targetLog.baseMovementID, modificationsSnapshot: targetLog.modificationsSnapshot,
            load: targetLog.actualLoad, plannedSetCount: p.sets.count, repFloor: p.sets[0].repFloor, repCeiling: p.sets[0].repCeiling,
            effortInstruction: p.sets[0].effortInstruction, actualSets: targetLog.actualSets,
            effort: targetLog.finalEffort, problem: targetLog.problem, sessionMode: input.event.sessionMode, phase: p.phase,
            loadingMode: movement.loadingMode, setupRevision: authored.setupRevision, repCounting: movement.repCounting)
        after.recentComparable = Array((after.recentComparable + [exposure]).suffix(6))
    }
    state.exercises[target] = after
    if pauseBase {
        let base = targetLog.baseMovementID!
        state.baseSafety![base]!.paused = true
        state.baseSafety![base]!.sourceEventIDs.append(input.event.eventID)
    }
    var decisions: [Decision] = []
    for p in displayed.exercises {
        if p.movementID == target {
            decisions.append(try FixtureCompiler.expectedDecision(id: target, action: action, rules: rules, key: key,
                before: input.state.exercises[target]!, after: after))
            for (notice, noticeRules) in notices {
                decisions.append(try FixtureCompiler.expectedDecision(id: target, action: .notice, rules: noticeRules, key: notice,
                    before: input.state.exercises[target]!, after: after))
            }
        } else {
            let saved = state.exercises[p.movementID]!
            decisions.append(try FixtureCompiler.expectedDecision(id: p.movementID, action: .hold, rules: otherRules, key: otherKey, before: saved, after: saved))
        }
    }
    state.revision += 1
    state.lastSessionDate = input.event.date
    state.processedEvents[input.event.eventID] = try CanonicalJSON.sha256(FixtureCompiler.canonical(input.event))
    let workout = try FixtureCompiler.expectedWorkout(state: state, date: input.nextWorkoutDate, slotID: input.nextSlotID)
    state.activePrescription = workout
    return .applied(nextState: state, nextWorkout: workout, decisions: decisions)
}

struct VariantProgressionTests {
    @Test(arguments: ["+25 lb", "35 lb assistance"])
    func modifiedPullupConfirmsThenExtendsWithNullNumericLoad(description: String) throws {
        let id = "modified-pullup"
        let input = try appInput(variant: id, modifications: description)
        let original = input
        var first = input.state.exercises[id]!
        first.ceilingStreak = 1
        let firstExpected = try appGolden(input, target: id, after: first, action: .hold, rules: ["R11"], key: "ceiling_confirmation", append: true)
        #expect(advanceProgram(input) == firstExpected)
        guard case let .applied(firstState, _, _) = firstExpected else { return }
        let secondInput = try appEvent(state: firstState, rules: input.rules, target: id, eventID: "second")
        var second = firstState.exercises[id]!
        second.ceilingStreak = 0
        second.repCeiling = 14
        second.recentComparable = []
        let secondExpected = try appGolden(secondInput, target: id, after: second, action: .extendRepCeiling,
            rules: ["R11", "R14"], key: "rep_ceiling_extended")
        #expect(advanceProgram(secondInput) == secondExpected)
        #expect(second.load == nil)
        let defaultID = input.state.config.variants!.values.first { $0.baseMovementID == "banded_pullups" && $0.modifications.isEmpty }!.id
        #expect(firstState.exercises[defaultID] == input.state.exercises[defaultID])
        #expect(input == original)
    }

    @Test func switchingToAnotherVariantDoesNotPoolConfirmationsOrWindows() throws {
        let input = try appInput(variant: "modified-pullup", modifications: "Different grip")
        var first = input.state.exercises["modified-pullup"]!
        first.ceilingStreak = 1
        guard case var .applied(state, _, _) = try appGolden(input, target: "modified-pullup", after: first,
            action: .hold, rules: ["R11"], key: "ceiling_confirmation", append: true) else { return }
        let originalModified = state.exercises["modified-pullup"]!
        let defaultID = try defaultVariantID(programID: state.config.programID, baseMovementID: "banded_pullups")
        state.config.activeVariantIDs!["banded_pullups"] = defaultID
        state.revision += 1 // Synthetic O5 selection input; O4 does not perform selection.
        state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: input.nextWorkoutDate, slotID: input.nextSlotID)
        let next = try appEvent(state: state, rules: input.rules, target: defaultID, eventID: "default-exposure")
        var after = state.exercises[defaultID]!
        after.ceilingStreak = 1
        let expected = try appGolden(next, target: defaultID, after: after, action: .hold, rules: ["R11"], key: "ceiling_confirmation", append: true)
        #expect(advanceProgram(next) == expected)
        guard case let .applied(final, _, _) = expected else { return }
        #expect(final.exercises["modified-pullup"] == originalModified)
        #expect(final.exercises[defaultID]?.recentComparable.count == 1)
    }

    @Test func painSharesBasePauseAndSwitchCannotClearIt() throws {
        var input = try appInput(variant: "modified-pullup", modifications: "+25 lb")
        let id = "modified-pullup"
        let row = input.event.exercises.firstIndex { $0.movementID == id }!
        input.event.exercises[row].problem = .pain
        var after = input.state.exercises[id]!
        after.mode = .paused
        after.ceilingStreak = 0
        after.strainStreak = 0
        after.recentComparable = []
        let expected = try appGolden(input, target: id, after: after, action: .pause, rules: ["R01"], key: "movement_paused", pauseBase: true)
        #expect(advanceProgram(input) == expected)
        guard case var .applied(state, _, _) = expected else { return }
        let oldSafety = state.baseSafety
        let oldPaused = state.exercises[id]
        for selected in [try defaultVariantID(programID: state.config.programID, baseMovementID: "banded_pullups"), "new-variant"] {
            if selected == "new-variant" {
                state.config.variants![selected] = MovementVariant(id: selected, baseMovementID: "banded_pullups", modifications: "New setup")
                state.exercises[selected] = ExerciseState(load: nil, mode: .baseline, normalSets: 3, repFloor: 8, repCeiling: 12,
                    ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil, interruptedReturn: false, recentComparable: [], setupRevision: 1)
            }
            state.config.activeVariantIDs!["banded_pullups"] = selected
            state.revision += 1
            state.activePrescription = try FixtureCompiler.expectedWorkout(state: state, date: input.nextWorkoutDate, slotID: input.nextSlotID)
            let next = try appEvent(state: state, rules: input.rules, target: selected, eventID: selected)
            let golden = try appGolden(next, target: selected, after: state.exercises[selected]!, action: .hold, rules: ["R01"], key: "paused_preserved")
            #expect(advanceProgram(next) == golden)
            #expect(try prepareWorkout(state: state, rules: input.rules, easierToday: true).exercises.first { $0.movementID == selected }?.sets == [])
            #expect(state.baseSafety == oldSafety && state.exercises[id] == oldPaused)
        }
    }
}

extension VariantProgressionTests {
    @Test func sixAppOnTargetExposuresProduceCompleteMedianOverlay() throws {
        var input = try appInput(variant: "modified-pullup", modifications: "Different grip")
        let id = "modified-pullup"
        let observations = [[10,10,10], [10,10,9], [10,10,10], [10,10,9], [10,10,10], [10,10,10]]
        for index in observations.indices {
            let row = input.event.exercises.firstIndex { $0.movementID == id }!
            input.event.exercises[row].actualSets = observations[index].map { ActualSet(reps: $0) }
            let after = input.state.exercises[id]!
            let expected = try appGolden(input, target: id, after: after, action: .hold, rules: ["R10"], key: "capacity_hold",
                append: true, notices: index == 5 ? [("plateau_check", ["R16"])] : [])
            #expect(advanceProgram(input) == expected)
            guard case let .applied(nextState, _, _) = expected else { return }
            input = try appEvent(state: nextState, rules: input.rules, target: id, eventID: "exposure-\(index + 1)")
        }
    }

    @Test(arguments: [false, true])
    func easierAppExposureKeepsBaselineAndUnresolvedReturnState(returnPending: Bool) throws {
        var input = try appInput(variant: "modified-pullup", modifications: "Different grip", mode: .baseline)
        let id = "modified-pullup"
        if returnPending {
            input.state.exercises[id]!.interruptedReturn = true
            input.state.exercises[id]!.nextSetOverride = 2
            input.state.activePrescription = try FixtureCompiler.expectedWorkout(state: input.state, date: input.event.date, slotID: input.event.slotID)
        }
        input = try appEvent(state: input.state, rules: input.rules, target: id, easier: true)
        let original = input
        let after = input.state.exercises[id]!
        let expected = try appGolden(input, target: id, after: after, action: .hold, rules: ["R03", "R04"], key: "easier_session_recorded",
            otherRules: ["R03", "R04"], otherKey: "easier_session_recorded")
        #expect(advanceProgram(input) == expected)
        #expect(input == original)
        guard case let .applied(state, _, _) = expected else { return }
        #expect(state.exercises[id]!.mode == .baseline && state.exercises[id]!.interruptedReturn == returnPending)
        #expect(state.exercises[id]!.lastCompletedDate == input.event.date && state.exercises[id]!.recentComparable.isEmpty)
    }
}

import Foundation
@testable import TrainingCore

func starterState(choice: StarterProgramChoice = .wholeBodyGlutes, goal: Goal = .size, slotID: String = "SUN") throws -> ProgramState {
    let rules = try RulesetCatalog.starter(choice)
    let config = try selectStarterProgram(choice: choice, goal: goal,
        programID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    let date = try LocalDate(iso8601: slotID == "SUN" ? "2026-10-11" : slotID == "TUE" ? "2026-10-13" : "2026-10-15")
    return try initializeProgram(config: config, rules: rules, firstWorkout: WorkoutSlot(date: date, slotID: slotID)).state
}

func starterRules(_ state: ProgramState) throws -> Ruleset {
    try RulesetCatalog.starter(state.config.profileID == "starter-upper-v1" ? .upperBody : .wholeBodyGlutes)
}

func starterRefresh(_ state: inout ProgramState, slotID: String? = nil, date: LocalDate? = nil) throws {
    state.activePrescription = try plannedWorkout(state: state, rules: starterRules(state),
        slot: WorkoutSlot(date: date ?? state.activePrescription.date, slotID: slotID ?? state.activePrescription.slotID))
}

func starterSet(_ state: inout ProgramState, base: String, targets: [Int], load: String = "50", established: Bool = false) throws {
    let id = state.config.activeVariantIDs![base]!
    let movement = state.config.movements.first { $0.id == base }!
    state.exercises[id]!.load = movement.availableLoads.first { $0.amount == load }
    state.exercises[id]!.mode = .normal
    state.exercises[id]!.normalSets = targets.count
    state.exercises[id]!.exactRepState!.normalTargets = targets
    state.exercises[id]!.exactRepState!.lastSuitableNormalDate = try state.activePrescription.date.adding(days: -7)
    if established { state.exercises[id]!.starterState!.doseStage = .established }
    try starterRefresh(&state)
}

func starterCompletion(state: ProgramState, actualsByBase: [String: [Int]], effortByBase: [String: Effort] = [:],
                       problemsByBase: [String: Problem] = [:], sessionMode: SessionMode = .normal) throws -> CompletedWorkout {
    let displayed = try prepareWorkout(state: state, rules: starterRules(state), easierToday: sessionMode == .easier)
    let logs = displayed.exercises.map { row in
        let base = row.baseMovementID!
        let movement = state.config.movements.first { $0.id == base }!
        let actual = actualsByBase[base] ?? []
        let selected = !actual.isEmpty
        return ExerciseLog(movementID: row.movementID, prescriptionID: displayed.id,
            status: selected ? (actual.count == row.sets.count ? .completed : .partial) : .skipped,
            actualLoad: row.load, actualSets: actual.enumerated().map { index, reps in
                ActualSet(reps: reps, leftReps: movement.repCounting == .perSide ? reps : nil,
                    rightReps: movement.repCounting == .perSide ? reps : nil, setIndex: index,
                    missedGoalReason: reps < row.sets[index].targetReps! ? .effortLimit : nil)
            }, finalEffort: selected ? effortByBase[base] ?? .onTarget : .unknown,
            problem: problemsByBase[base] ?? .none, baseMovementID: base, modificationsSnapshot: row.modificationsSnapshot,
            effortScope: .allWorkingSets, skippedSetIndices: Array(actual.count..<row.sets.count), mixedLoads: false)
    }
    return CompletedWorkout(eventID: "starter-\(state.revision)-\(displayed.date.iso8601)", date: displayed.date,
        slotID: displayed.slotID, prescriptionID: displayed.id, plannedPrescriptionID: state.activePrescription.id,
        sessionMode: sessionMode, exercises: logs)
}

func starterInput(_ state: ProgramState, actuals: [String: [Int]], efforts: [String: Effort] = [:],
                  problems: [String: Problem] = [:], mode: SessionMode = .normal,
                  nextSlot: String? = nil) throws -> AdvanceInput {
    let current = state.activePrescription.slotID
    let next = nextSlot ?? (current == "SUN" ? "TUE" : current == "TUE" ? "THU" : "SUN")
    let weekday = ["SUN": 0, "TUE": 2, "THU": 4]
    let days = (weekday[next]! - weekday[current]! + 7) % 7
    return AdvanceInput(state: state,
        event: try starterCompletion(state: state, actualsByBase: actuals, effortByBase: efforts,
            problemsByBase: problems, sessionMode: mode), rules: try starterRules(state), nextSlotID: next,
        nextWorkoutDate: try state.activePrescription.date.adding(days: days == 0 ? 7 : days))
}

func starterApplied(_ input: AdvanceInput) throws -> ProgramState {
    switch advanceProgram(input) {
    case let .applied(state, _, _): return state
    case let .rejected(_, errors): throw EngineError(code: errors.joined(separator: ","), field: "starter_test")
    case .noOp: throw EngineError(code: "unexpected_replay", field: "starter_test")
    }
}

/// Authored prior event/context, not a production advancement-derived expected result.
func starterPromotionInput() throws -> AdvanceInput {
    var state = try starterState()
    let base = "db_romanian_deadlift"
    try starterSet(&state, base: base, targets: [12, 12])
    let id = state.config.activeVariantIDs![base]!
    let rules = try starterRules(state)
    let row = state.activePrescription.exercises[0]
    let context = try exactContext(state: state, id: id, prescription: row, position: 0, actualLoad: row.load, rules: rules)
    let key = try starterComparisonKey(profileHash: state.config.profileHash!, slotID: "SUN", context: context, precedingDose: [])
    var event = try starterCompletion(state: state, actualsByBase: [base: [12, 12]])
    event.eventID = "prior-sun"
    event.date = try LocalDate(iso8601: "2026-10-04")
    let observation = exactObservation(event: event, log: event.exercises[0], prescription: row,
        movement: state.config.movements.first { $0.id == base }!, context: context)
    state.exercises[id]!.starterState!.windows[key] = StarterComparisonWindow(slotID: "SUN", contextKey: key,
        context: context, precedingDose: [], ceilingStreak: 1, strainStreak: 0, shortfallStreak: 0,
        introStreak: 1, exposures: [observation])
    state.exercises[id]!.lastCompletedDate = event.date
    state.lastSessionDate = event.date
    try starterRefresh(&state)
    return try starterInput(state, actuals: [base: [12, 12]], nextSlot: "THU")
}

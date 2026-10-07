import Foundation

public struct ConfigurationResult: Equatable, Sendable {
    public var state: ProgramState
    public var workout: WorkoutPrescription
    public var decisions: [Decision]

    public init(state: ProgramState, workout: WorkoutPrescription, decisions: [Decision]) {
        self.state = state
        self.workout = workout
        self.decisions = decisions
    }
}

/// Pure value transition. The repository must journal the typed command with the
/// exact parent revision and commit state, prescription and outbox atomically.
public func reconfigureProgram(state: ProgramState, change: ConfigurationChange,
                               rules: Ruleset, nextWorkout: WorkoutSlot) throws -> ConfigurationResult {
    try validateConfigurationInput(state: state, rules: rules, slot: nextWorkout)
    var updated = state
    var decisions: [Decision] = []
    var affected: [String] = []
    let key: String
    var resumeAuthorized = false
    switch change {
    case let .goal(goal):
        guard goal != state.config.goal else { return unchangedConfiguration(state) }
        updated.config.goal = goal
        affected = state.exercises.keys.sorted()
        key = "goal_changed"
    case let .minimumRir(base, value):
        guard let movement = state.config.movements.first(where: { $0.id == base }) else {
            throw EngineError(code: "unknown_movement", field: "baseMovementId")
        }
        let current = state.baseSafety?[base]?.minimumRir ?? movement.minimumRir
        guard value >= current else { throw EngineError(code: "clearance_required", field: "minimumRir") }
        guard value != current else { return unchangedConfiguration(state) }
        if state.schemaVersion == 2 { updated.baseSafety![base]!.minimumRir = value }
        else { updated.config.movements[updated.config.movements.firstIndex { $0.id == base }!].minimumRir = value }
        affected = variantIDs(for: base, in: state)
        key = "minimum_rir_changed"
    case let .resetSetup(id):
        guard let existing = state.exercises[id] else { throw EngineError(code: "unknown_variant", field: "variantId") }
        let (revision, overflow) = (existing.setupRevision ?? 1).addingReportingOverflow(1)
        guard !overflow else { throw EngineError(code: "invalid_state", field: "setupRevision") }
        updated.exercises[id]!.setupRevision = revision
        affected = [id]
        key = "setup_reset"
    case let .safeResume(base, clearance):
        guard state.config.movements.contains(where: { $0.id == base }) else { throw EngineError(code: "unknown_movement", field: "baseMovementId") }
        guard clearance else { throw EngineError(code: "clearance_required", field: "externalClearanceConfirmed") }
        affected = variantIDs(for: base, in: state)
        resumeAuthorized = true
        if state.schemaVersion == 2 { updated.baseSafety![base]!.paused = false }
        key = "safe_resume"
    }
    for id in affected {
        let before = state.exercises[id]!
        let base = state.config.variants?[id]?.baseMovementID ?? id
        let movement = updated.config.movements.first { $0.id == base }!
        rebaseline(&updated.exercises[id]!, movement: movement, config: updated.config,
                   preset: try rules.preset(goal: updated.config.goal, daysPerWeek: updated.config.daysPerWeek),
                   paused: updated.baseSafety?[base]?.paused == true || (before.mode == .paused && !resumeAuthorized))
        decisions.append(try configurationDecision(id: id, action: .baseline, key: key,
                                                   before: before, after: updated.exercises[id]!))
    }
    return try finishConfiguration(original: state, updated: updated, rules: rules, slot: nextWorkout, decisions: decisions)
}

func validateConfigurationInput(state: ProgramState, rules: Ruleset, slot: WorkoutSlot) throws {
    try validateConfigurationState(state: state, rules: rules)
    if state.schemaVersion == 2 { try WorkoutScheduler.validate(slot: slot, config: state.config) }
    if let last = state.lastSessionDate, slot.date <= last {
        throw EngineError(code: "non_future_workout", field: "slot.date")
    }
    guard state.config.weeklySlots.contains(where: { $0.id == slot.slotID }) else {
        throw EngineError(code: "invalid_slot", field: "slotId")
    }
}

func validateConfigurationState(state: ProgramState, rules: Ruleset) throws {
    _ = try prepareWorkout(state: state, rules: rules)
    let expectedIDs = state.schemaVersion == 2 ? Set(state.config.variants!.keys) : Set(state.config.movements.map(\.id))
    guard Set(state.exercises.keys) == expectedIDs else {
        throw EngineError(code: "invalid_state", field: "exercises")
    }
}

func variantIDs(for base: String, in state: ProgramState) -> [String] {
    state.schemaVersion == 2 ? state.config.variants!.values.filter { $0.baseMovementID == base }.map(\.id).sorted() : [base]
}

func rebaseline(_ exercise: inout ExerciseState, movement: Movement, config: ProgramConfig,
                preset: GoalPreset, paused: Bool) {
    let range = initialRepRange(movement: movement, goal: config.goal, preset: preset)
    exercise.mode = paused ? .paused : .baseline
    exercise.normalSets = preset.normalSets
    exercise.repFloor = range.floor
    exercise.repCeiling = range.ceiling
    resetComparisons(&exercise)
    exercise.nextSetOverride = nil
    exercise.interruptedReturn = false
    // Keep the known load, setup revision and last completion; the journal owns
    // immutable raw history, while recentComparable is only an eligibility window.
}

func unchangedConfiguration(_ state: ProgramState) -> ConfigurationResult {
    ConfigurationResult(state: state, workout: state.activePrescription, decisions: [])
}

func finishConfiguration(original: ProgramState, updated: ProgramState, rules: Ruleset,
                         slot: WorkoutSlot, decisions: [Decision]) throws -> ConfigurationResult {
    var result = updated
    let (revision, overflow) = original.revision.addingReportingOverflow(1)
    guard !overflow else { throw EngineError(code: "invalid_state", field: "revision") }
    result.revision = revision
    result.activePrescription = try plannedWorkout(state: result, rules: rules, slot: slot)
    _ = try prepareWorkout(state: result, rules: rules)
    return ConfigurationResult(state: result, workout: result.activePrescription, decisions: decisions)
}

func configurationDecision(id: String?, action: DecisionAction, ruleIDs: [String] = [], key: String,
                           before: some Encodable, after: some Encodable) throws -> Decision {
    func fields(_ value: some Encodable) throws -> [String: CanonicalValue] {
        guard case .object(let fields) = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)) else {
            throw EngineError(code: "invalid_state", field: "decisions")
        }
        return fields
    }
    return try Decision(movementID: id, action: action, ruleIDs: ruleIDs, sourceIDs: [],
                        evidenceClass: .appAdaptation, explanationKey: key, before: fields(before), after: fields(after))
}

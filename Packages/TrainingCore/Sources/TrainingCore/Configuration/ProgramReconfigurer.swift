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
    if state.schemaVersion == 4 {
        return try reconfigureStarterProgram(state: state, change: change, rules: rules, nextWorkout: nextWorkout)
    }
    try validateConfigurationInput(state: state, rules: rules, slot: nextWorkout)
    let policy = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
    var updated = state
    var decisions: [Decision] = []
    var affected: [String] = []
    let key: String
    var resumeAuthorized = false
    switch change {
    case .reviewStrengthHandling:
        throw EngineError(code: "unsupported_operation", field: "reviewStrengthHandling")
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
        if policy.usesVariants { updated.baseSafety![base]!.minimumRir = value }
        else { updated.config.movements[updated.config.movements.firstIndex { $0.id == base }!].minimumRir = value }
        affected = try variantIDs(for: base, in: state, rules: rules)
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
        affected = try variantIDs(for: base, in: state, rules: rules)
        resumeAuthorized = true
        if policy.usesVariants { updated.baseSafety![base]!.paused = false }
        key = "safe_resume"
    }
    for id in affected {
        let before = state.exercises[id]!
        let base = state.config.variants?[id]?.baseMovementID ?? id
        let movement = updated.config.movements.first { $0.id == base }!
        rebaseline(&updated.exercises[id]!, movement: movement, config: updated.config,
                   preset: try rules.preset(goal: updated.config.goal, daysPerWeek: updated.config.daysPerWeek),
                   paused: updated.baseSafety?[base]?.paused == true || (before.mode == .paused && !resumeAuthorized))
        if policy.usesExactTargets {
            seedExactBaseline(&updated.exercises[id]!, clearSetupReview: key == "setup_reset")
        }
        decisions.append(try configurationDecision(id: id, action: .baseline, ruleIDs: policy.usesExactTargets ? ["X12"] : [], key: key,
                                                   before: before, after: updated.exercises[id]!, ruleset: policy.usesExactTargets ? rules : nil))
    }
    return try finishConfiguration(original: state, updated: updated, rules: rules, slot: nextWorkout, decisions: decisions)
}

func validateConfigurationInput(state: ProgramState, rules: Ruleset, slot: WorkoutSlot, preservePendingSlot: Bool = true) throws {
    if preservePendingSlot, state.schedulingPolicy == .flexibleV1,
       slot != WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID) {
        throw EngineError(code: "pending_rotation_locked", field: "slot")
    }
    try validateConfigurationState(state: state, rules: rules)
    if try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules).usesVariants { try WorkoutScheduler.validate(slot: slot, config: state.config, schedulingPolicy: state.schedulingPolicy) }
    if let last = state.lastSessionDate, slot.date <= last {
        throw EngineError(code: "non_future_workout", field: "slot.date")
    }
    guard state.config.weeklySlots.contains(where: { $0.id == slot.slotID }) else {
        throw EngineError(code: "invalid_slot", field: "slotId")
    }
}

func validateConfigurationState(state: ProgramState, rules: Ruleset) throws {
    _ = try prepareWorkout(state: state, rules: rules)
    let expectedIDs = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules).usesVariants ? Set(state.config.variants!.keys) : Set(state.config.movements.map(\.id))
    guard Set(state.exercises.keys) == expectedIDs else {
        throw EngineError(code: "invalid_state", field: "exercises")
    }
}

func variantIDs(for base: String, in state: ProgramState, rules: Ruleset) throws -> [String] {
    try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules).usesVariants ? state.config.variants!.values.filter { $0.baseMovementID == base }.map(\.id).sorted() : [base]
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
                           before: some Encodable, after: some Encodable, ruleset: Ruleset? = nil) throws -> Decision {
    func fields(_ value: some Encodable) throws -> [String: CanonicalValue] {
        guard case .object(let fields) = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)) else {
            throw EngineError(code: "invalid_state", field: "decisions")
        }
        return fields
    }
    let archived = try ruleIDs.map { ruleID -> RuleRecord? in
        guard let ruleset else { return nil }
        guard let rule = ruleset.rules?.first(where: { $0.id == ruleID }) else {
            throw EngineError(code: "invalid_exact_transition", field: "decisions")
        }
        return rule
    }.compactMap { $0 }
    return try Decision(movementID: id, action: action, ruleIDs: ruleIDs,
                        sourceIDs: Array(Set(archived.flatMap(\.sourceIDs))).sorted(),
                        evidenceClass: archived.first?.evidenceClass ?? .appAdaptation,
                        explanationKey: key, before: fields(before), after: fields(after))
}

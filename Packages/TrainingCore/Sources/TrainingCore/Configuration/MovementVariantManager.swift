import Foundation

/// O6 must reject setup/selection changes after working sets, actual observations
/// or a problem flag. Only an explicitly invalidated empty draft may be rebuilt.
public func changeMovementVariant(state: ProgramState, change: VariantChange, rules: Ruleset,
                                  nextWorkout: WorkoutSlot) throws -> ConfigurationResult {
    if state.schemaVersion == 4 {
        return try changeStarterMovementVariant(state: state, change: change, rules: rules, nextWorkout: nextWorkout)
    }
    try validateConfigurationInput(state: state, rules: rules, slot: nextWorkout)
    let policy = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
    guard policy.usesVariants else { throw EngineError(code: "unsupported_variant_policy", field: "schemaVersion") }
    var updated = state
    let id: String
    let key: String
    var checkGap = false
    switch change {
    case .createLoadingMode:
        throw EngineError(code: "unsupported_operation", field: "createLoadingMode")
    case let .create(base, variant, description):
        guard let movement = state.config.movements.first(where: { $0.id == base }) else {
            throw EngineError(code: "unknown_movement", field: "baseMovementId")
        }
        guard !variant.isEmpty, state.config.variants![variant] == nil else {
            throw EngineError(code: "variant_id_conflict", field: "variantId")
        }
        id = variant
        key = "variant_created"
        updated.config.variants![id] = MovementVariant(id: id, baseMovementID: base,
            modifications: description.trimmingCharacters(in: .whitespacesAndNewlines))
        updated.config.activeVariantIDs![base] = id
        let preset = try rules.preset(goal: state.config.goal, daysPerWeek: state.config.daysPerWeek)
        let range = initialRepRange(movement: movement, goal: state.config.goal, preset: preset)
        updated.exercises[id] = ExerciseState(load: nil, mode: state.baseSafety![base]!.paused ? .paused : .baseline,
            normalSets: preset.normalSets, repFloor: range.floor, repCeiling: range.ceiling,
            ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil,
            interruptedReturn: false, recentComparable: [], setupRevision: 1,
            exactRepState: policy.usesExactTargets ? ExactRepState(normalTargets: Array(repeating: range.floor, count: preset.normalSets), shortfallStreak: 0, lastSuitableNormalDate: nil, setupReviewRequired: false) : nil)
    case let .select(base, variant):
        guard state.config.movements.contains(where: { $0.id == base }),
              state.config.variants![variant]?.baseMovementID == base else {
            throw EngineError(code: "invalid_variant", field: "variantId")
        }
        guard state.config.activeVariantIDs![base] != variant else { return unchangedConfiguration(state) }
        id = variant
        key = "variant_selected"
        checkGap = true
        updated.config.activeVariantIDs![base] = variant
        if policy.usesExactTargets {
            resetExactComparisons(&updated.exercises[id]!)
            if updated.exercises[id]!.mode != .paused { updated.exercises[id]!.mode = .baseline }
        }
    case let .correctDescription(variant, description):
        guard let saved = state.config.variants![variant] else { throw EngineError(code: "unknown_variant", field: "variantId") }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.modifications.utf8.elementsEqual(trimmed.utf8) else { return unchangedConfiguration(state) }
        id = variant
        key = "variant_description_corrected"
        updated.config.variants![id]!.modifications = trimmed
    }
    try validate(config: updated.config, rules: rules)
    var decisions = [try configurationDecision(id: id, action: .notice, ruleIDs: policy.usesExactTargets ? ["X12"] : [], key: key,
        before: state.config, after: updated.config, ruleset: policy.usesExactTargets ? rules : nil)]
    if checkGap, let gap = try markInterruptedReturn(state: &updated, id: id, asOf: nextWorkout.date, rules: rules) {
        decisions.append(gap)
    }
    return try finishConfiguration(original: state, updated: updated, rules: rules, slot: nextWorkout, decisions: decisions)
}

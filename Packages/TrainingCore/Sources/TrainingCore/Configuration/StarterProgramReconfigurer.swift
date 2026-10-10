import Foundation

public func reconfigureStarterProgram(state: ProgramState, change: ConfigurationChange, rules: Ruleset,
                                     nextWorkout: WorkoutSlot) throws -> ConfigurationResult {
    try validateConfigurationInput(state: state, rules: rules, slot: nextWorkout)
    guard try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules).usesStarterDoses else {
        throw EngineError(code: "unsupported_operation", field: "starterConfiguration")
    }
    var updated = state
    var affected: [String] = []
    var restartDose = false
    var clearHandling = false
    let key: String
    switch change {
    case let .goal(goal):
        guard goal != state.config.goal else { return unchangedConfiguration(state) }
        updated.config.goal = goal
        affected = state.exercises.keys.sorted()
        restartDose = true
        clearHandling = true
        key = "goal_changed"
    case let .resetSetup(id):
        guard let existing = state.exercises[id] else { throw EngineError(code: "unknown_variant", field: "variantId") }
        let (revision, overflow) = existing.setupRevision!.addingReportingOverflow(1)
        guard !overflow else { throw EngineError(code: "invalid_state", field: "setupRevision") }
        updated.exercises[id]!.setupRevision = revision
        affected = [id]
        restartDose = true
        clearHandling = true
        updated.exercises[id]!.exactRepState!.setupReviewRequired = false
        key = "setup_reset"
    case let .reviewStrengthHandling(id, choice):
        guard let exercise = state.exercises[id], let variant = state.config.variants?[id],
              rules.starterDoses?[state.config.goal.rawValue]?[variant.baseMovementID]?.requiresHandlingReview == true else {
            throw EngineError(code: "invalid_handling_choice", field: "variantId")
        }
        if case let .lowRep(load) = choice {
            let movement = try resolveEffectiveMovement(config: state.config, variantID: id, rules: rules)
            guard (exercise.load == nil || exercise.load == load), movement.availableLoads.contains(load) else {
                throw EngineError(code: "handling_load_mismatch", field: "load")
            }
            // An explicit first handling review may establish only an unknown load.
            // Existing known loads retain the exact-match safeguard.
            if exercise.load == nil { updated.exercises[id]!.load = load }
        }
        guard exercise.starterState!.strengthHandling != choice else { return unchangedConfiguration(state) }
        updated.exercises[id]!.starterState!.strengthHandling = choice
        affected = [id]
        key = "strength_handling_reviewed"
    case let .minimumRir(base, value):
        guard let family = rules.safetyFamilies?[base], let current = state.baseSafety?[base] else {
            throw EngineError(code: "unknown_movement", field: "baseMovementId")
        }
        guard value >= current.minimumRir else { throw EngineError(code: "clearance_required", field: "minimumRir") }
        guard value != current.minimumRir else { return unchangedConfiguration(state) }
        updated.retainedSafety![family]!.minimumRir = value
        affected = projectStarterFamilySafety(&updated, family: family, rules: rules)
        key = "minimum_rir_changed"
    case let .safeResume(base, clearance):
        guard let family = rules.safetyFamilies?[base], state.baseSafety?[base] != nil else {
            throw EngineError(code: "unknown_movement", field: "baseMovementId")
        }
        guard clearance else { throw EngineError(code: "clearance_required", field: "externalClearanceConfirmed") }
        updated.retainedSafety![family]!.paused = false
        affected = projectStarterFamilySafety(&updated, family: family, rules: rules)
        key = "safe_resume"
    }
    var decisions: [Decision] = []
    for id in affected {
        let before = state.exercises[id]!
        try rebaselineStarterExercise(state: &updated, id: id, rules: rules,
            restartDose: restartDose, clearHandling: clearHandling)
        decisions.append(try configurationDecision(id: id, action: .baseline, ruleIDs: key == "strength_handling_reviewed" ? ["P05"] : ["X12"], key: key,
            before: before, after: updated.exercises[id]!, ruleset: rules))
    }
    return try finishConfiguration(original: state, updated: updated, rules: rules, slot: nextWorkout, decisions: decisions)
}

/// Shared pure family projection; unrelated and currently removed families persist.
@discardableResult
func projectStarterFamilySafety(_ state: inout ProgramState, family: String, rules: Ruleset) -> [String] {
    let bases = state.config.movements.filter { rules.safetyFamilies![$0.id] == family }.map(\.id)
    for base in bases { state.baseSafety![base] = state.retainedSafety![family]! }
    return state.config.variants!.values.filter { bases.contains($0.baseMovementID) }.map(\.id).sorted()
}

func resetStarterComparisons(_ exercise: inout ExerciseState) {
    resetExactComparisons(&exercise)
    exercise.starterState?.windows = [:]
}

func rebaselineStarterExercise(state: inout ProgramState, id: String, rules: Ruleset,
                               restartDose: Bool, clearHandling: Bool) throws {
    if clearHandling { state.exercises[id]!.starterState!.strengthHandling = nil }
    let dose = try resolveMovementDose(config: state.config, variantID: id, exercise: state.exercises[id], rules: rules)
    let base = state.config.variants![id]!.baseMovementID
    var exercise = state.exercises[id]!
    if restartDose { exercise.starterState!.doseStage = dose.allowsIntroPromotion ? .introductory : .fixed }
    exercise.normalSets = exercise.starterState!.doseStage == .established ? dose.establishedSets : dose.initialSets
    exercise.repFloor = dose.repFloor
    exercise.repCeiling = dose.initialRepCeiling
    exercise.mode = state.baseSafety![base]!.paused ? .paused : .baseline
    seedExactBaseline(&exercise)
    resetStarterComparisons(&exercise)
    exercise.exactRepState!.lastSuitableNormalDate = nil
    state.exercises[id] = exercise
}

func changeStarterMovementVariant(state: ProgramState, change: VariantChange, rules: Ruleset,
                                  nextWorkout: WorkoutSlot) throws -> ConfigurationResult {
    try validateConfigurationInput(state: state, rules: rules, slot: nextWorkout)
    var updated = state
    let id: String
    let key: String
    var checkGap = false
    switch change {
    case let .create(base, variant, description):
        guard let selected = state.config.activeVariantIDs?[base] else {
            throw EngineError(code: "unknown_movement", field: "baseMovementId")
        }
        // Text-only saves inherit an explicitly selected mode; text is opaque.
        try createStarterVariant(state: &updated, base: base, id: variant, description: description,
            override: state.config.variants![selected]!.loadingModeOverride, rules: rules)
        id = variant
        key = "variant_created"
    case let .createLoadingMode(base, variant, description, mode):
        guard state.config.profileID == "starter-glute-v1", base == "db_floor_glute_bridge", mode == .bodyweight else {
            throw EngineError(code: "invalid_loading_override", field: "mode")
        }
        try createStarterVariant(state: &updated, base: base, id: variant, description: description, override: mode, rules: rules)
        id = variant
        key = "loading_variant_created"
    case let .select(base, variant):
        guard state.config.activeVariantIDs?[base] != nil, state.config.variants?[variant]?.baseMovementID == base else {
            throw EngineError(code: "invalid_variant", field: "variantId")
        }
        guard state.config.activeVariantIDs![base] != variant else { return unchangedConfiguration(state) }
        id = variant
        key = "variant_selected"
        checkGap = true
        updated.config.activeVariantIDs![base] = id
        resetStarterComparisons(&updated.exercises[id]!)
        if updated.exercises[id]!.mode != .paused { updated.exercises[id]!.mode = .baseline }
    case let .correctDescription(variant, description):
        guard let saved = state.config.variants?[variant] else { throw EngineError(code: "unknown_variant", field: "variantId") }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.modifications.utf8.elementsEqual(trimmed.utf8) else { return unchangedConfiguration(state) }
        id = variant
        key = "variant_description_corrected"
        updated.config.variants![id]!.modifications = trimmed
    }
    try validate(config: updated.config, rules: rules)
    var decisions = [try configurationDecision(id: id, action: .notice, ruleIDs: key == "loading_variant_created" ? ["P06"] : ["X12"], key: key,
        before: state.config, after: updated.config, ruleset: rules)]
    if checkGap, state.schedulingPolicy == nil, let decision = try markStarterInterruptedReturn(state: &updated, variantID: id, asOf: nextWorkout.date, rules: rules) {
        decisions.append(decision)
    }
    return try finishConfiguration(original: state, updated: updated, rules: rules, slot: nextWorkout, decisions: decisions)
}

private func createStarterVariant(state: inout ProgramState, base: String, id: String, description: String,
                                  override: LoadingMode?, rules: Ruleset) throws {
    guard state.config.movements.contains(where: { $0.id == base }) else {
        throw EngineError(code: "unknown_movement", field: "baseMovementId")
    }
    guard !id.isEmpty, state.config.variants![id] == nil else { throw EngineError(code: "variant_id_conflict", field: "variantId") }
    state.config.variants![id] = MovementVariant(id: id, baseMovementID: base,
        modifications: description.trimmingCharacters(in: .whitespacesAndNewlines), loadingModeOverride: override)
    state.config.activeVariantIDs![base] = id
    let dose = try resolveMovementDose(config: state.config, variantID: id, exercise: nil, rules: rules)
    state.exercises[id] = newStarterExercise(dose: dose, load: nil, paused: state.baseSafety![base]!.paused)
}

public func markStarterInterruptedReturn(state: inout ProgramState, variantID: String, asOf: LocalDate,
                                         rules: Ruleset) throws -> Decision? {
    try validateStarterState(state: state, rules: rules)
    guard let before = state.exercises[variantID], let variant = state.config.variants?[variantID],
          before.starterState != nil, before.exactRepState != nil else {
        throw EngineError(code: "invalid_state", field: "variantId")
    }
    guard before.mode != .paused, state.baseSafety![variant.baseMovementID]!.paused != true,
          before.exactRepState!.setupReviewRequired != true else { return nil }
    var after = before
    guard let last = before.exactRepState!.lastSuitableNormalDate else {
        guard before.mode != .baseline else { return nil }
        seedExactBaseline(&after)
        resetStarterComparisons(&after)
        state.exercises[variantID] = after
        return try exactDecision(id: variantID, action: .baseline, rule: "X03", key: "no_capacity_evidence",
            before: before, after: after, rules: rules)
    }
    guard asOf >= last else { throw EngineError(code: "backdated_date", field: "asOf") }
    guard !before.interruptedReturn, last.days(until: asOf) >= (try rules.resolvedParameters.interruptionDays) else { return nil }
    let movement = try resolveEffectiveMovement(config: state.config, variantID: variantID, rules: rules)
    try beginExactInterruptedReturn(&after, movement: movement, rules: rules)
    resetStarterComparisons(&after)
    if before.load != after.load, case .lowRep = after.starterState!.strengthHandling {
        after.starterState!.strengthHandling = nil
    }
    state.exercises[variantID] = after
    return try exactDecision(id: variantID, action: .recover, rule: "X08", key: "interruption_return",
        before: before, after: after, rules: rules)
}

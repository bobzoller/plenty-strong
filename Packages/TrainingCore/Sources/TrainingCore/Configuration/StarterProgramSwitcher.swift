import Foundation

/// Explicit append-only transition. Archive verification belongs to the writer /
/// replay boundary; all supplied metadata is strictly admitted here without IO.
public func changeStarterProgram(state: ProgramState, sourceRules: Ruleset, destinationRules: Ruleset,
                                 destinationDefinition: StarterProgramDefinition,
                                 choice: StarterProgramChoice, goal: Goal,
                                 verifiedHistory: [JournalEnvelope], nextWorkout: WorkoutSlot) throws -> ConfigurationResult {
    guard nextWorkout.date >= state.activePrescription.date else { throw EngineError(code: "backdated_date", field: "next") }
    try validateConfigurationInput(state: state, rules: sourceRules, slot: nextWorkout)
    guard [2, 3, 4].contains(state.schemaVersion), destinationDefinition.choice == choice,
          let uuid = UUID(uuidString: state.config.programID), state.config.programID == uuid.uuidString.lowercased() else {
        throw EngineError(code: "unsupported_starter_transition", field: "state")
    }
    if verifiedHistory.isEmpty {
        let original = try initializeProgram(config: state.config, rules: sourceRules,
            firstWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID))
        guard original.state == state else { throw EngineError(code: "invalid_starter_history", field: "missing_history") }
    }
    let path = try starterVerifiedPath(state: state, history: verifiedHistory)
    var config = try selectStarterProgram(definition: destinationDefinition, goal: goal, programID: uuid)
    try validate(config: config, rules: destinationRules)
    let ledger = try retainedStarterSafety(state: state, verifiedHistory: verifiedHistory, destinationRules: destinationRules)
    var priorExercises: [String: ExerciseState] = [:]
    for movement in config.movements {
        // Exact base identities preserve handling/load semantics. Angle-specific
        // press/row identities differ and therefore begin independently.
        let source: ProgramState?
        if state.config.movements.contains(where: { compatibleStarterMovement($0, movement) }) { source = state }
        else {
            // Only the selected verified parent path supplies a revisited setup.
            // Discarded branches never grant capacity or an active selection.
            source = path.reversed().map(\.returnedState).first { previous in
                previous.config.profileHash == config.profileHash &&
                    previous.config.movements.contains(where: { compatibleStarterMovement($0, movement) })
            }
        }
        if let source {
            let variants = source.config.variants!.values.filter { $0.baseMovementID == movement.id }
            for variant in variants {
                guard let old = source.exercises[variant.id],
                      old.load == nil || movement.availableLoads.contains(old.load!),
                      variant.loadingModeOverride == nil || (movement.id == "db_floor_glute_bridge" && variant.loadingModeOverride == .bodyweight) else {
                    throw EngineError(code: "invalid_starter_history", field: "variant")
                }
                config.variants![variant.id] = variant
                priorExercises[variant.id] = old
            }
            if let selected = source.config.activeVariantIDs?[movement.id] { config.activeVariantIDs![movement.id] = selected }
        }
    }
    // Admit the completed reconstructed configuration in this operation before
    // using the supplied-value per-variant dose helpers. No validation cache.
    try validate(config: config, rules: destinationRules)
    var updated = try initializeProgram(config: config, rules: destinationRules, firstWorkout: nextWorkout).state
    var retained = ledger
    for (family, restriction) in updated.retainedSafety! { retained[family] = unionStarterSafety(retained[family], restriction) }
    updated.retainedSafety = retained
    for movement in config.movements { updated.baseSafety![movement.id] = retained[destinationRules.safetyFamilies![movement.id]!]! }
    for (id, variant) in config.variants! {
        let dose = try resolveValidatedMovementDose(config: config, variantID: id, exercise: nil, rules: destinationRules)
        let restriction = updated.baseSafety![variant.baseMovementID]!
        let previous = priorExercises[id]
        var fresh = newStarterExercise(dose: dose, load: previous?.load, paused: restriction.paused)
        if let previous { fresh.setupRevision = previous.setupRevision; fresh.lastCompletedDate = previous.lastCompletedDate }
        updated.exercises[id] = fresh
    }
    updated.processedEvents = state.processedEvents
    updated.lastSessionDate = state.lastSessionDate
    return try finishConfiguration(original: state, updated: updated, rules: destinationRules, slot: nextWorkout, decisions: [])
}

private func compatibleStarterMovement(_ first: Movement, _ second: Movement) -> Bool {
    first.id == second.id && first.loadingMode == second.loadingMode && first.implementCount == second.implementCount &&
        first.repCounting == second.repCounting && first.availableLoads == second.availableLoads
}

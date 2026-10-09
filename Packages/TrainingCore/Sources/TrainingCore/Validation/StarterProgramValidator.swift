import Foundation

/// Semantic admission for the registered schema-4 state and its issued prescription.
/// Verified ancestry of removed families is checked by the journal/import boundary.
public func validateStarterProgram(state: ProgramState, rules: Ruleset) throws {
    try validateStarterState(state: state, rules: rules)
    let planned = state.activePrescription
    let expected = try makeValidatedStarterWorkout(state: state, rules: rules,
        slot: WorkoutSlot(date: planned.date, slotID: planned.slotID))
    guard planned == expected else { throw EngineError(code: "stale_prescription", field: "activePrescription") }
    if let last = state.lastSessionDate, planned.date <= last {
        throw EngineError(code: "non_future_workout", field: "activePrescription.date")
    }
}

/// Excludes the pending prescription so initialization/transition can construct it.
func validateStarterState(state: ProgramState, rules: Ruleset) throws {
    guard state.schemaVersion == 4, rules.contractVersion == 4,
          state.rulesetVersion == rules.version, state.rulesetHash == rules.hash else {
        throw EngineError(code: "ruleset_mismatch", field: "rules")
    }
    try validate(config: state.config, rules: rules)
    let parameters = rules.parameters!
    guard state.revision >= 0, state.revision < Int.max,
          let variants = state.config.variants, Set(state.exercises.keys) == Set(variants.keys),
          let safety = state.baseSafety, Set(safety.keys) == Set(state.config.movements.map(\.id)),
          let ledger = state.retainedSafety else {
        throw EngineError(code: "invalid_state", field: "starterState")
    }
    for (family, restriction) in ledger {
        guard !family.isEmpty, restriction.minimumRir >= parameters.normalMinimumRir,
              restriction.sourceEventIDs.allSatisfy({ !$0.isEmpty }),
              Set(restriction.sourceEventIDs).count == restriction.sourceEventIDs.count else {
            throw EngineError(code: "invalid_state", field: "retainedSafety")
        }
    }
    for movement in state.config.movements {
        guard let family = rules.safetyFamilies?[movement.id], let retained = ledger[family],
              let shared = safety[movement.id], shared == retained, shared.minimumRir >= movement.minimumRir else {
            throw EngineError(code: "invalid_state", field: "baseSafety.\(movement.id)")
        }
    }
    for (id, exercise) in state.exercises {
        let movement = try resolveValidatedEffectiveMovement(config: state.config, variantID: id, rules: rules)
        let dose = try resolveValidatedMovementDose(config: state.config, variantID: id, exercise: exercise, rules: rules)
        guard let starter = exercise.starterState, let exact = exercise.exactRepState,
              let revision = exercise.setupRevision, revision > 0, exercise.normalSets > 0,
              exercise.ceilingStreak == 0, exercise.strainStreak == 0, exercise.recentComparable.isEmpty,
              exact.shortfallStreak == 0,
              exercise.repFloor == dose.repFloor, exercise.repCeiling >= dose.initialRepCeiling,
              exercise.repCeiling <= dose.maximumRepCeiling,
              exact.normalTargets.count == exercise.normalSets,
              exact.normalTargets.allSatisfy({ (1...exercise.repCeiling).contains($0) }),
              exercise.nextSetOverride == nil || (1...exercise.normalSets).contains(exercise.nextSetOverride!),
              !exercise.interruptedReturn || exercise.nextSetOverride != nil,
              movement.loadingMode == .externalLoad ? (exercise.load == nil || movement.availableLoads.contains(exercise.load!)) : exercise.load == nil,
              exercise.mode != .paused || safety[movement.id]!.paused,
              starter.windows.count <= 3, Set(starter.windows.values.map(\.slotID)).count == starter.windows.count,
              !(exercise.mode == .paused || safety[movement.id]!.paused || exercise.interruptedReturn || exercise.nextSetOverride != nil ||
                exact.setupReviewRequired || dose.requiresHandlingReview) || starter.windows.isEmpty else {
            throw EngineError(code: "invalid_exact_state", field: "exercises.\(id)")
        }
        let expectedCount: Int
        switch starter.doseStage {
        case .introductory:
            guard dose.allowsIntroPromotion else { throw EngineError(code: "invalid_dose_stage", field: id) }
            expectedCount = dose.initialSets
        case .established:
            guard dose.allowsIntroPromotion else { throw EngineError(code: "invalid_dose_stage", field: id) }
            expectedCount = dose.establishedSets
        case .fixed:
            guard !dose.allowsIntroPromotion else { throw EngineError(code: "invalid_dose_stage", field: id) }
            expectedCount = dose.initialSets
        }
        guard exercise.normalSets == expectedCount else { throw EngineError(code: "invalid_dose_stage", field: id) }
        if starter.strengthHandling != nil {
            guard rules.starterDoses?[state.config.goal.rawValue]?[movement.id]?.requiresHandlingReview == true else {
                throw EngineError(code: "invalid_handling_choice", field: id)
            }
            if case let .lowRep(load) = starter.strengthHandling, !movement.availableLoads.contains(load) {
                throw EngineError(code: "unavailable_load", field: id)
            }
        }
        for (key, window) in starter.windows {
            try validateStarterWindow(window, key: key, state: state, id: id, exercise: exercise,
                movement: movement, dose: dose, rules: rules, parameters: parameters)
        }
    }
}

/// Hash the frozen issued workout identity; numeric goals are deliberately absent.
/// Position is already a field of ExactRepContext. Callers supply the preceding
/// normal doses from the input workout/state before advancing any movement.
func starterComparisonKey(profileHash: String, slotID: String, context: ExactRepContext,
                          precedingDose: [StarterPrecedingMovement]) throws -> String {
    func canonical(_ value: some Encodable) throws -> CanonicalValue {
        try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
    }
    return try CanonicalJSON.sha256(.object([
        "profileHash": .string(profileHash), "slotId": .string(slotID),
        "context": try canonical(context), "precedingDose": try canonical(precedingDose)
    ]))
}

private func validateStarterWindow(_ window: StarterComparisonWindow, key: String, state: ProgramState,
                                   id: String, exercise: ExerciseState, movement: Movement, dose: MovementDose,
                                   rules: Ruleset, parameters: RuleParameters) throws {
    let context = window.context
    guard let weekly = state.config.weeklySlots.first(where: { $0.id == window.slotID }),
          let position = weekly.movementIDs.firstIndex(of: movement.id),
          context.variantID == id, context.setupRevision == exercise.setupRevision, context.load == exercise.load,
          context.normalSetCount == exercise.normalSets, context.restSeconds == dose.restSeconds,
          context.repFloor == exercise.repFloor, context.repCeiling == exercise.repCeiling,
          context.minimumRir == max(parameters.normalMinimumRir, state.baseSafety![movement.id]!.minimumRir),
          context.effortScope == .allWorkingSets, context.rulesetHash == rules.hash,
          context.movementPosition == position,
          window.precedingDose.map(\.baseMovementID) == Array(weekly.movementIDs.prefix(position)),
          key == window.contextKey,
          key == (try starterComparisonKey(profileHash: state.config.profileHash!, slotID: window.slotID,
                                           context: context, precedingDose: window.precedingDose)),
          (0..<parameters.confirmationCount).contains(window.ceilingStreak),
          (0..<parameters.setbackCount).contains(window.strainStreak),
          (0..<parameters.setbackCount).contains(window.shortfallStreak),
          (0...1).contains(window.introStreak),
          exercise.starterState!.doseStage == .introductory || window.introStreak == 0,
          window.exposures.count <= parameters.plateauExposures,
          Set(window.exposures.map(\.eventID)).count == window.exposures.count,
          (window.ceilingStreak == 0 && window.strainStreak == 0 && window.shortfallStreak == 0 && window.introStreak == 0) || !window.exposures.isEmpty else {
        throw EngineError(code: "invalid_context_window", field: "exercises.\(id).windows")
    }
    // Preceding dose belongs to the frozen exposure, not today's partially advanced
    // state. A preceding movement may have graduated since this slot last ran.
    for preceding in window.precedingDose {
        guard let dose = rules.starterDoses?[state.config.goal.rawValue]?[preceding.baseMovementID],
              preceding.normalSetCount == dose.initialSets || preceding.normalSetCount == dose.establishedSets else {
            throw EngineError(code: "invalid_context_window", field: "precedingDose")
        }
    }
    var priorDate: LocalDate?
    var lastClassification: ExactExposureClassification?
    for exposure in window.exposures {
        try WorkoutScheduler.validate(slot: WorkoutSlot(date: exposure.date, slotID: window.slotID), config: state.config)
        try validateExactComparable(exposure, variant: state.config.variants![id]!, movement: movement, rules: rules)
        guard exposure.exactRepContext == context,
              exposure.effortInstruction == exactEffortInstruction(minimumRir: context.minimumRir, parameters: parameters),
              exposure.effort == .tooHard || exposure.actualSets.allSatisfy({ $0.reps <= exposure.repCeiling }),
              priorDate == nil || exposure.date > priorDate!,
              exercise.lastCompletedDate != nil && exposure.date <= exercise.lastCompletedDate!,
              state.lastSessionDate != nil && exposure.date <= state.lastSessionDate! else {
            throw EngineError(code: "invalid_context_window", field: "exposures")
        }
        let prescription = ExercisePrescription(movementID: id, kind: .working, phase: exposure.phase,
            load: context.load, sets: exposure.prescribedTargets!.map {
                SetPrescription(repFloor: context.repFloor, repCeiling: context.repCeiling,
                    effortInstruction: exposure.effortInstruction!, targetReps: $0)
            }, restSeconds: context.restSeconds, stopInstruction: parameters.stopInstruction,
            baseMovementID: movement.id, modificationsSnapshot: exposure.modificationsSnapshot)
        let classification = try ExactExposureClassifier.classify(log: exposure.log!, prescription: prescription,
            movement: movement, state: exercise, context: context)
        guard !classification.conflicting else {
            throw EngineError(code: "invalid_context_window", field: "exposures")
        }
        lastClassification = classification
        priorDate = exposure.date
    }
    if let last = window.exposures.last, let classified = lastClassification {
        let normal = last.phase == .normal
        let introEligible = normal && last.effort != .tooHard && classified.cleanKnown &&
            classified.sameLoad && classified.goalsMet && !classified.overshoot && !classified.aboveCeiling
        let ceilingEligible = normal && last.effort != .tooHard && classified.goalsMet && !classified.overshoot &&
            classified.actual.allSatisfy { $0 == context.repCeiling } &&
            (state.config.goal != .maintenance || last.effort == .tooEasy)
        guard window.introStreak == 0 || introEligible,
              window.ceilingStreak == 0 || ceilingEligible,
              window.strainStreak == 0 || classified.strain,
              window.shortfallStreak == 0 || (normal && classified.effortLimitedMiss && !classified.strain),
              window.strainStreak == 0 || (window.ceilingStreak == 0 && window.shortfallStreak == 0),
              window.ceilingStreak == 0 || window.shortfallStreak == 0 else {
            throw EngineError(code: "invalid_context_window", field: "windowCounters")
        }
    }
}

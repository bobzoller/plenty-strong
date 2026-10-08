import Foundation

/// Supported schema/catalog pairs are exhaustive. Legacy observations never acquire
/// exact targets or all-set effort merely because a newer client decodes them.
public enum ProgramPolicy: Equatable, Sendable {
    case numericV02
    case fixedCeilingsV1
    case fixedExactV1

    public static func resolve(schemaVersion: Int, rules: Ruleset) throws -> ProgramPolicy {
        try rules.validateIntegrity()
        switch (schemaVersion, rules.version, rules.hash) {
        case (1, "general-fitness-v0.2", RulesetCatalog.numericRulesetHash): return .numericV02
        case (2, "general-fitness-swift1", RulesetCatalog.fixedRulesetHash): return .fixedCeilingsV1
        case (3, "general-fitness-exact-v1", RulesetCatalog.exactRulesetHash): return .fixedExactV1
        default: throw EngineError(code: "unsupported_policy", field: "schemaVersion")
        }
    }

    public var usesVariants: Bool { self != .numericV02 }
    public var usesExactTargets: Bool { self == .fixedExactV1 }
}

/// Structural admission of raw observations, not progression qualification. In
/// particular a completed status does not certify positive or equal-side work.
/// Missing/zero/asymmetric observations survive unchanged for later classification.
public func validateIndexedExactLog(_ log: ExerciseLog, prescription: ExercisePrescription) throws {
    guard log.movementID == prescription.movementID, !log.prescriptionID.isEmpty,
          let base = prescription.baseMovementID, log.baseMovementID == base,
          let modifications = prescription.modificationsSnapshot, log.modificationsSnapshot == modifications,
          log.effortScope == .allWorkingSets,
          let skipped = log.skippedSetIndices, log.mixedLoads != nil else {
        throw EngineError(code: "invalid_snapshot", field: "log")
    }
    try validateExactPrescriptionShape(prescription)
    let count = prescription.sets.count
    var performed: Set<Int> = []
    for actual in log.actualSets {
        guard let index = actual.setIndex, (0..<count).contains(index), performed.insert(index).inserted,
              actual.reps >= 0, actual.leftReps == nil || actual.leftReps! >= 0,
              actual.rightReps == nil || actual.rightReps! >= 0 else {
            throw EngineError(code: "invalid_sets", field: "actualSets")
        }
    }
    guard Set(skipped).count == skipped.count, skipped.allSatisfy({ (0..<count).contains($0) }),
          performed.isDisjoint(with: Set(skipped)), log.status != .skipped || log.actualSets.isEmpty else {
        throw EngineError(code: "invalid_sets", field: "skippedSetIndices")
    }
}

/// Callable schema-3 admission helper. Transition/journal callers integrate this
/// at their own boundaries; this introduces no implicit migration or activation.
public func validateExactRepContract(state: ProgramState, rules: Ruleset) throws {
    let policy = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
    guard state.rulesetVersion == rules.version, state.rulesetHash == rules.hash else {
        throw EngineError(code: "ruleset_mismatch", field: "rules")
    }
    guard policy.usesExactTargets else { return }
    let parameters = try rules.resolvedParameters
    guard let variants = state.config.variants, !variants.isEmpty,
          Set(state.exercises.keys) == Set(variants.keys),
          let safety = state.baseSafety,
          Set(safety.keys) == Set(state.config.movements.map(\.id)) else {
        throw EngineError(code: "invalid_state", field: "variants")
    }
    for (id, exercise) in state.exercises {
        guard let exact = exercise.exactRepState, let variant = variants[id],
              let movement = state.config.movements.first(where: { $0.id == variant.baseMovementID }),
              exercise.normalSets > 0, exercise.repFloor >= 1, exercise.repCeiling >= exercise.repFloor,
              exercise.repCeiling <= (state.config.goal == .strength && movement.lowRepLoadingAllowed ? parameters.maximumStrengthRepCeiling : parameters.maximumRepCeiling),
              validTargets(exact.normalTargets, count: exercise.normalSets, ceiling: exercise.repCeiling),
              (0..<parameters.setbackCount).contains(exact.shortfallStreak),
              let revision = exercise.setupRevision, revision > 0,
              exercise.recentComparable.count <= parameters.plateauExposures else {
            throw EngineError(code: "invalid_exact_state", field: "exercises.\(id)")
        }
        for exposure in exercise.recentComparable {
            try validateExactComparable(exposure, variant: variant, movement: movement, rules: rules)
        }
    }
    let prescribedIDs = state.activePrescription.exercises.map(\.movementID)
    guard Set(prescribedIDs).count == prescribedIDs.count else {
        throw EngineError(code: "invalid_prescription", field: "activePrescription.exercises")
    }
    for prescription in state.activePrescription.exercises {
        guard let variant = variants[prescription.movementID],
              let exercise = state.exercises[prescription.movementID],
              prescription.baseMovementID == variant.baseMovementID,
              prescription.modificationsSnapshot == variant.modifications,
              prescription.sets.count <= exercise.normalSets,
              prescription.sets.allSatisfy({ $0.repCeiling <= exercise.repCeiling }),
              prescription.kind != .setupReview || exercise.exactRepState?.setupReviewRequired == true,
              exercise.exactRepState?.setupReviewRequired != true || prescription.kind == .setupReview || prescription.kind == .paused else {
            throw EngineError(code: "invalid_snapshot", field: "activePrescription")
        }
        try validateExactPrescriptionShape(prescription)
    }
}

private func validTargets(_ targets: [Int], count: Int, ceiling: Int) -> Bool {
    targets.count == count && targets.allSatisfy { $0 >= 1 && $0 <= ceiling }
}

private func validateExactPrescriptionShape(_ prescription: ExercisePrescription) throws {
    if prescription.kind == .setupReview || prescription.kind == .paused {
        guard prescription.sets.isEmpty else {
            throw EngineError(code: "invalid_prescription", field: "sets")
        }
        return
    }
    guard !prescription.sets.isEmpty, prescription.restSeconds > 0,
          prescription.sets.allSatisfy({ set in
              guard let target = set.targetReps else { return false }
              return set.repFloor >= 0 && set.repCeiling >= set.repFloor && target >= 1 && target <= set.repCeiling && !set.effortInstruction.isEmpty
          }) else {
        throw EngineError(code: "invalid_prescription", field: "sets.targetReps")
    }
}

private func validateExactComparable(_ exposure: Exposure, variant: MovementVariant, movement: Movement, rules: Ruleset) throws {
    guard let log = exposure.log, let context = exposure.exactRepContext, let targets = exposure.prescribedTargets,
          exposure.movementID == variant.id, exposure.baseMovementID == variant.baseMovementID,
          exposure.modificationsSnapshot != nil, exposure.modificationsSnapshot == log.modificationsSnapshot,
          log.baseMovementID == variant.baseMovementID, exposure.loadingMode == movement.loadingMode,
          exposure.repCounting == movement.repCounting, exposure.effortInstruction?.isEmpty == false,
          context.variantID == variant.id, context.setupRevision > 0, context.setupRevision == exposure.setupRevision,
          context.rulesetHash == rules.hash, context.effortScope == .allWorkingSets,
          context.normalSetCount > 0, context.normalSetCount == exposure.plannedSetCount,
          context.minimumRir >= movement.minimumRir, context.restSeconds > 0, context.movementPosition >= 0,
          context.repFloor >= 1, context.repFloor == exposure.repFloor, context.repCeiling == exposure.repCeiling,
          context.repCeiling >= context.repFloor,
          validTargets(targets, count: exposure.plannedSetCount, ceiling: exposure.repCeiling),
          context.load == exposure.load, exposure.load == log.actualLoad,
          (movement.loadingMode == .externalLoad ? (exposure.load != nil && movement.availableLoads.contains(exposure.load!)) : exposure.load == nil),
          exposure.actualSets == log.actualSets, exposure.effort == log.finalEffort, exposure.problem == log.problem,
          !exposure.eventID.isEmpty, exposure.phase == .normal, exposure.sessionMode == .normal,
          log.status == .completed, log.finalEffort != .unknown, log.problem == .none, log.mixedLoads == false,
          log.skippedSetIndices == [], log.actualSets.count == exposure.plannedSetCount,
          log.actualSets.allSatisfy({ actual in
              guard actual.reps > 0 else { return false }
              if movement.repCounting == .perSide {
                  return actual.leftReps == actual.reps && actual.rightReps == actual.reps
              }
              // Side data, when supplied, cannot hide an incomplete/asymmetric result.
              return (actual.leftReps == nil && actual.rightReps == nil) || (actual.leftReps == actual.reps && actual.rightReps == actual.reps)
          }) else {
        throw EngineError(code: "invalid_snapshot", field: "recentComparable")
    }
    let prescription = ExercisePrescription(movementID: variant.id, kind: .working, phase: exposure.phase,
        load: context.load, sets: targets.map {
            SetPrescription(repFloor: exposure.repFloor, repCeiling: exposure.repCeiling, effortInstruction: exposure.effortInstruction!, targetReps: $0)
        }, restSeconds: context.restSeconds, stopInstruction: "", baseMovementID: variant.baseMovementID,
        modificationsSnapshot: exposure.modificationsSnapshot)
    try validateIndexedExactLog(log, prescription: prescription)
}

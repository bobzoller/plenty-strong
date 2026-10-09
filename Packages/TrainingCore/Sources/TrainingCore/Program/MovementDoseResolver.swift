import Foundation

/// Pure supplied-value resolution. Modification text never changes load semantics.
public func resolveEffectiveMovement(config: ProgramConfig, variantID: String, rules: Ruleset) throws -> Movement {
    try validate(config: config, rules: rules)
    return try resolveValidatedEffectiveMovement(config: config, variantID: variantID, rules: rules)
}

/// Internal operation-local path: the caller must have admitted this same config
/// and rules in the current operation. There is no persisted/global trust cache.
func resolveValidatedEffectiveMovement(config: ProgramConfig, variantID: String, rules: Ruleset) throws -> Movement {
    guard let variant = config.variants?[variantID],
          var movement = config.movements.first(where: { $0.id == variant.baseMovementID }) else {
        throw EngineError(code: "invalid_variant", field: "variantId")
    }
    if let mode = variant.loadingModeOverride {
        guard rules.contractVersion == 4, config.profileID == "starter-glute-v1",
              movement.id == "db_floor_glute_bridge", mode == .bodyweight else {
            throw EngineError(code: "invalid_loading_override", field: "loadingModeOverride")
        }
        movement.loadingMode = .bodyweight
        movement.implementCount = 0
        movement.availableLoads = []
        movement.initialLoad = nil
        movement.automaticLoadProgressionAllowed = false
        movement.lowRepLoadingAllowed = false
        movement.requiredEquipment = []
    }
    return movement
}

/// Return the registered normal dose, adjusted only for explicit handling choice.
/// Promotion/state admission belongs to the schema-4 planner/validator boundary.
public func resolveMovementDose(config: ProgramConfig, variantID: String, exercise: ExerciseState?, rules: Ruleset) throws -> MovementDose {
    try validate(config: config, rules: rules)
    guard try ProgramPolicy.resolve(schemaVersion: rules.contractVersion ?? 1, rules: rules).usesStarterDoses else {
        throw EngineError(code: "missing_movement_dose", field: "starterDoses")
    }
    return try resolveValidatedMovementDose(config: config, variantID: variantID, exercise: exercise, rules: rules)
}

/// Same operation-local admission requirement as the effective-movement helper.
func resolveValidatedMovementDose(config: ProgramConfig, variantID: String, exercise: ExerciseState?, rules: Ruleset) throws -> MovementDose {
    let movement = try resolveValidatedEffectiveMovement(config: config, variantID: variantID, rules: rules)
    guard var dose = rules.starterDoses?[config.goal.rawValue]?[movement.id] else {
        throw EngineError(code: "missing_movement_dose", field: "starterDoses")
    }
    if dose.requiresHandlingReview {
        switch exercise?.starterState?.strengthHandling {
        case .standardRange:
            dose.repFloor = 8
            dose.initialRepCeiling = 12
            dose.maximumRepCeiling = 20
            dose.requiresHandlingReview = false
        case .lowRep(let confirmedLoad):
            // Setup changes must explicitly clear the choice at the configuration boundary.
            dose.requiresHandlingReview = exercise?.load != confirmedLoad || !movement.availableLoads.contains(confirmedLoad)
        case nil: break
        }
    }
    return dose
}

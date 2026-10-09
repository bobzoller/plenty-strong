import Foundation

public func selectFixedProgram(goal: Goal, programID: UUID) throws -> ProgramConfig {
    let profile = try RulesetCatalog.fixedProfile()
    let id = programID.uuidString.lowercased()
    var variants: [String: MovementVariant] = [:]
    var selections: [String: String] = [:]
    for movement in profile.movements {
        let variantID = try defaultVariantID(programID: id, baseMovementID: movement.id)
        variants[variantID] = MovementVariant(id: variantID, baseMovementID: movement.id, modifications: "")
        selections[movement.id] = variantID
    }
    let config = ProgramConfig(programID: id, goal: goal, daysPerWeek: profile.daysPerWeek,
        movements: profile.movements, weeklySlots: profile.weeklySlots,
        requiredMuscleGroups: profile.requiredMuscleGroups, initialLoads: profile.initialLoads,
        profileID: profile.profileID, profileHash: profile.contentHash,
        sourceProfileID: profile.sourceProfileID, sourceProfileHash: profile.sourceProfileHash,
        coveragePolicy: profile.coveragePolicy, variantPolicyVersion: profile.variantPolicyVersion,
        variants: variants, activeVariantIDs: selections)
    try validate(config: config, rules: RulesetCatalog.fixedV1())
    return config
}

public func defaultVariantID(programID: String, baseMovementID: String) throws -> String {
    try CanonicalJSON.sha256(.array([.string("movement-variant-v1"), .string(programID), .string(baseMovementID), .string("default")]))
}

public func validate(config: ProgramConfig, rules: Ruleset) throws {
    try rules.validateIntegrity()
    func reject(_ code: String, _ field: String) throws -> Never { throw EngineError(code: code, field: field) }
    guard !config.programID.isEmpty, [2, 3].contains(config.daysPerWeek) else { try reject("invalid_config", "config") }
    let baseIDs = config.movements.map(\.id)
    guard !baseIDs.isEmpty, baseIDs.allSatisfy({ !$0.isEmpty }), Set(baseIDs).count == baseIDs.count else { try reject("duplicate_movement", "movements") }
    guard config.weeklySlots.count == config.daysPerWeek,
          Set(config.weeklySlots.map(\.id)).count == config.weeklySlots.count,
          config.weeklySlots.allSatisfy({ !$0.id.isEmpty && !$0.movementIDs.isEmpty && Set($0.movementIDs).count == $0.movementIDs.count && Set($0.movementIDs).isSubset(of: Set(baseIDs)) }) else { try reject("invalid_slot", "weeklySlots") }
    guard Set(config.weeklySlots.flatMap(\.movementIDs)) == Set(baseIDs),
          Set(config.initialLoads.keys) == Set(baseIDs),
          !config.requiredMuscleGroups.isEmpty,
          Set(config.requiredMuscleGroups).count == config.requiredMuscleGroups.count else { try reject("invalid_coverage", "requiredMuscleGroups") }
    for movement in config.movements {
        let field = "movements.\(movement.id)"
        guard movement.minimumRir >= 2, movement.setupRevision > 0,
              !movement.primaryMuscles.isEmpty,
              Set(movement.primaryMuscles).count == movement.primaryMuscles.count,
              Set(movement.secondaryMuscles).count == movement.secondaryMuscles.count,
              Set(movement.primaryMuscles).isDisjoint(with: Set(movement.secondaryMuscles)) else { try reject("invalid_movement", field) }
        if movement.loadingMode != .externalLoad {
            guard movement.availableLoads.isEmpty, config.initialLoads[movement.id]! == nil,
                  !movement.automaticLoadProgressionAllowed, !movement.lowRepLoadingAllowed,
                  movement.implementCount == 0 else { try reject("invalid_non_numeric_load", field) }
        } else {
            guard !movement.availableLoads.isEmpty else { try reject("empty_load_catalog", field + ".availableLoads") }
            let first = movement.availableLoads[0]
            var previous: Decimal?
            for load in movement.availableLoads {
                guard (try? ExactLoad(canonicalAmount: load.amount)) != nil,
                      load.unit == first.unit, load.basis == first.basis,
                      let amount = Decimal(string: load.amount, locale: Locale(identifier: "en_US_POSIX")),
                      previous == nil || amount > previous! else { try reject("invalid_load_catalog", field + ".availableLoads") }
                previous = amount
            }
            if let implementCount = movement.implementCount {
                guard [1, 2].contains(implementCount), first.basis == (implementCount == 1 ? .total : .perImplement) else { try reject("load_basis_mismatch", field + ".availableLoads") }
            }
            if let load = config.initialLoads[movement.id]! {
                guard movement.availableLoads.contains(load) else { try reject("unavailable_load", "initialLoads.\(movement.id)") }
            }
        }
    }
    let policy = try ProgramPolicy.resolve(schemaVersion: rules.contractVersion ?? 1, rules: rules)
    guard policy.usesVariants == (config.coveragePolicy == "fixed_profile") else { try reject("rules_profile_mismatch", "rules.version") }
    if config.coveragePolicy == "fixed_profile" {
        // Catalog/selection reads and validates the full archive once at its explicit
        // boundary. Preparation, transitions and replay validate supplied frozen
        // metadata by its typed projection, with no Bundle or Data(contentsOf:) call.
        if policy.usesStarterDoses {
            guard rules.profileID == config.profileID, rules.profileHash == config.profileHash else {
                try reject("fixed_profile_mismatch", "profile")
            }
            try StarterProgramCatalog.validateProjection(config)
        } else {
            guard rules.profileHash == config.profileHash,
                  try CanonicalJSON.sha256(fixedMetadataContent(config: config)) == RulesetCatalog.fixedMetadataProjectionHash else {
                try reject("fixed_profile_mismatch", "profile")
            }
            guard config.variants?.values.allSatisfy({ $0.loadingModeOverride == nil }) != false else {
                try reject("invalid_loading_override", "loadingModeOverride")
            }
        }
        try validateVariants(config: config)
    } else {
        guard config.coveragePolicy == nil || config.coveragePolicy == "general" else { try reject("unknown_coverage_policy", "coveragePolicy") }
        guard config.muscleExposureCounts.values.allSatisfy({ $0 >= 2 }), config.variants == nil, config.activeVariantIDs == nil else { try reject("invalid_coverage", "requiredMuscleGroups") }
    }
}

private func validateVariants(config: ProgramConfig) throws {
    func reject(_ field: String) throws -> Never { throw EngineError(code: "invalid_variant", field: field) }
    let bases = Set(config.movements.map(\.id))
    guard config.variantPolicyVersion == "movement-variant-v1", let registry = config.variants,
          let selected = config.activeVariantIDs, Set(selected.keys) == bases else { try reject("variants") }
    for (id, variant) in registry {
        guard !id.isEmpty, id == variant.id, bases.contains(variant.baseMovementID),
              variant.modifications == variant.modifications.trimmingCharacters(in: .whitespacesAndNewlines),
              variant.modifications.count <= 200,
              !variant.modifications.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) else { try reject("variants.\(id)") }
        let defaultID = try defaultVariantID(programID: config.programID, baseMovementID: variant.baseMovementID)
        if let override = variant.loadingModeOverride {
            guard config.profileID == "starter-glute-v1", variant.baseMovementID == "db_floor_glute_bridge",
                  override == .bodyweight, id != defaultID else { try reject("variants.\(id).loadingModeOverride") }
        }
        if id == defaultID {
            guard variant.modifications.isEmpty else { try reject("variants.\(id).modifications") }
        } else {
            guard !variant.modifications.isEmpty || variant.loadingModeOverride != nil else { try reject("variants.\(id).modifications") }
        }
    }
    for base in bases {
        let defaultID = try defaultVariantID(programID: config.programID, baseMovementID: base)
        guard registry[defaultID]?.baseMovementID == base,
              let selectedID = selected[base], registry[selectedID]?.baseMovementID == base else { try reject("activeVariantIds.\(base)") }
    }
}

/// The typed frozen projection has its own pin: dynamic program/goal/load/variant
/// values are validated separately. Hashing supplied values performs no resource I/O.
func fixedMetadataContent(config: ProgramConfig) throws -> CanonicalValue {
    guard case .object(let encoded) = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(config)) else {
        throw EngineError(code: "invalid_config", field: "config")
    }
    let keys = ["profileId", "profileHash", "sourceProfileId", "sourceProfileHash", "variantPolicyVersion",
        "daysPerWeek", "coveragePolicy", "movements", "weeklySlots", "requiredMuscleGroups"]
    return .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, encoded[$0] ?? .null) }))
}

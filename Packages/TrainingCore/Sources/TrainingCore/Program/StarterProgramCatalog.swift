import Foundation

/// Registered archive boundaries read resources; projection checks consume only values.
public enum StarterProgramCatalog {
    public static let upperProfileHash = "b07b7a87ec555d280888b10c5a1b5f550bcb7b4b798861b0613a9e9a29cdb608"
    public static let gluteProfileHash = "ae1ae192c0e36884ca5e8f02be268784367230df0bb9bcf3efe0bb6638f3adb3"
    public static let gluteSourceProfileHash = "22875f2ef4cf3f27944a7db798bd60ca6aad1df4e1762b225be7d34fedac7a72"
    public static let upperRulesetHash = "de5704e5c965331b04703d0617001cb550574255ad3145b28bae66c656340de4"
    public static let gluteRulesetHash = "2223f42ac0fdb62fd1751344f055e9b9e7f39ffa0f25fee7a64647781a452c76"
    static let upperMetadataProjectionHash = "196a90c2437a49841f8751c2d5ffdc20f4413a1e5cc848669f8df56f7cb4cc23"
    static let gluteMetadataProjectionHash = "d563a5394cfcada54c5d50036a7bf697648c476c3aade8711a760b897ccda6f8"

    public static func definition(_ choice: StarterProgramChoice) throws -> StarterProgramDefinition {
        let registration = registration(choice)
        let data = try RulesetCatalog.resource(named: registration.profileID)
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: data),
              fields.removeValue(forKey: "contentHash") == .string(registration.profileHash),
              try CanonicalJSON.sha256(.object(fields)) == registration.profileHash else {
            throw EngineError(code: "profile_hash_mismatch", field: "profile.contentHash")
        }
        let definition = try JSONDecoder().decode(StarterProgramDefinition.self, from: data)
        guard definition.choice == choice, definition.schemaVersion == 4,
              definition.profileID == registration.profileID, definition.contentHash == registration.profileHash,
              definition.daysPerWeek == 3, definition.coveragePolicy == "fixed_profile",
              definition.variantPolicyVersion == "movement-variant-v1" else {
            throw EngineError(code: "unknown_profile", field: "profile.profileId")
        }
        return definition
    }

    public static func choice(for config: ProgramConfig) throws -> StarterProgramChoice {
        if config.profileID == "fixed-home-gym-v0.2" {
            guard try CanonicalJSON.sha256(fixedMetadataContent(config: config)) == RulesetCatalog.fixedMetadataProjectionHash else {
                throw EngineError(code: "fixed_profile_mismatch", field: "profile")
            }
            return .upperBody // Display only: this never activates schema 4.
        }
        let choice = try registeredChoice(profileID: config.profileID)
        try validateProjection(config)
        return choice
    }

    public static func validateProjection(_ config: ProgramConfig) throws {
        let registration = registration(try registeredChoice(profileID: config.profileID))
        guard config.profileHash == registration.profileHash,
              try CanonicalJSON.sha256(fixedMetadataContent(config: config)) == registration.projectionHash else {
            throw EngineError(code: "fixed_profile_mismatch", field: "profile")
        }
    }

    static func registeredChoice(profileID: String?) throws -> StarterProgramChoice {
        switch profileID {
        case "starter-upper-v1": .upperBody
        case "starter-glute-v1": .wholeBodyGlutes
        default: throw EngineError(code: "unknown_profile", field: "profile.profileId")
        }
    }

    static func validateRulesRegistration(_ rules: Ruleset) throws {
        let registration = registration(try registeredChoice(profileID: rules.profileID))
        guard rules.contractVersion == 4, rules.version == registration.rulesVersion,
              rules.hash == registration.rulesHash, rules.profileHash == registration.profileHash,
              rules.sourceRulesetHash == RulesetCatalog.exactRulesetHash,
              Set(rules.starterDoses?.keys.map { $0 } ?? []) == Set(Goal.allCases.map(\.rawValue)),
              rules.safetyFamilies?.isEmpty == false else {
            throw EngineError(code: "invalid_ruleset", field: "rules.catalog")
        }
        // The full canonical pin includes every typed dose, family and evidence record.
    }

    static func registration(_ choice: StarterProgramChoice) -> (profileID: String, profileHash: String, rulesVersion: String, rulesHash: String, projectionHash: String, resource: String) {
        switch choice {
        case .upperBody:
            ("starter-upper-v1", upperProfileHash, "general-fitness-upper-exact-v2", upperRulesetHash, upperMetadataProjectionHash, "ruleset-upper-exact-v2")
        case .wholeBodyGlutes:
            ("starter-glute-v1", gluteProfileHash, "general-fitness-glute-exact-v1", gluteRulesetHash, gluteMetadataProjectionHash, "ruleset-glute-exact-v1")
        }
    }
}

public func selectStarterProgram(choice: StarterProgramChoice, goal: Goal, programID: UUID) throws -> ProgramConfig {
    let definition = try StarterProgramCatalog.definition(choice)
    let config = try selectStarterProgram(definition: definition, goal: goal, programID: programID)
    try validate(config: config, rules: RulesetCatalog.starter(choice))
    return config
}

/// Writer/replay boundaries supply a previously verified pinned archive definition.
/// This overload never reads a bundle, filesystem, clock or mutable global state.
public func selectStarterProgram(definition: StarterProgramDefinition, goal: Goal, programID: UUID) throws -> ProgramConfig {
    let registration = StarterProgramCatalog.registration(definition.choice)
    let expectedEquipment = ["adjustable_dumbbells", "adjustable_bench"] + (definition.choice == .upperBody ? ["pull_up_bar"] : [])
    guard definition.schemaVersion == 4, definition.profileID == registration.profileID,
          definition.contentHash == registration.profileHash, definition.requiredEquipment == expectedEquipment,
          Set(definition.initialLoads.keys) == Set(definition.movements.map(\.id)),
          definition.initialLoads.values.allSatisfy({ $0 == nil }) else {
        throw EngineError(code: "unknown_profile", field: "definition")
    }
    let id = programID.uuidString.lowercased()
    var variants: [String: MovementVariant] = [:]
    var selected: [String: String] = [:]
    for movement in definition.movements {
        let variantID = try defaultVariantID(programID: id, baseMovementID: movement.id)
        variants[variantID] = MovementVariant(id: variantID, baseMovementID: movement.id, modifications: "")
        selected[movement.id] = variantID
    }
    let config = ProgramConfig(programID: id, goal: goal, daysPerWeek: definition.daysPerWeek,
        movements: definition.movements, weeklySlots: definition.weeklySlots,
        requiredMuscleGroups: definition.requiredMuscleGroups, initialLoads: definition.initialLoads,
        profileID: definition.profileID, profileHash: definition.contentHash,
        sourceProfileID: definition.sourceProfileID, sourceProfileHash: definition.sourceProfileHash,
        coveragePolicy: definition.coveragePolicy, variantPolicyVersion: definition.variantPolicyVersion,
        variants: variants, activeVariantIDs: selected)
    try StarterProgramCatalog.validateProjection(config)
    return config
}

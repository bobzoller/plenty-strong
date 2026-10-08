import Foundation

/// Only immutable, bundled resources are admitted; no caller-supplied executable policy.
public enum RulesetCatalog {
    public static let exactRulesetHash = "b5b1100ee68edbe76384c31a3c8e1af918b4f5e3737f701ed0a6745989c3c73f"
    public static let fixedProfileHash = "e63a0543d54108af99637ed52dacebc1276e766b4314bc095891248efd7ce8ce"
    public static let fixedRulesetHash = "cc6520f0de45d47979942d3dda21eccc2e9779638ef1c18c7fdc44c4862b8463"
    public static let numericRulesetHash = "cba4084ab7e12b7074a3b87aba813f72fbff2d0560992edd0b566661bfc60beb"
    // Typed metadata encoding omits absent optionals; full archive hash remains separate.
    // Independently derived from the bundled profile and checked by FixedProgramTests.
    static let fixedMetadataProjectionHash = "f7b42cc8c191fdde0a4791281910a819cdb90c497d8050e9491dd1d9ecf7a5ff"

    public static func fixedV1() throws -> Ruleset {
        let rules = try loadRules(named: "ruleset-swift1")
        let profile = try fixedProfile()
        guard rules.profileID == profile.profileID, rules.profileHash == profile.contentHash else {
            throw EngineError(code: "profile_hash_mismatch", field: "rules.profileHash")
        }
        return rules
    }

    public static func numericV02() throws -> Ruleset {
        try loadRules(named: "numeric-v02-ruleset")
    }

    public static func exactV1() throws -> Ruleset {
        let rules = try loadRules(named: "ruleset-exact-v1")
        let profile = try fixedProfile()
        guard rules.profileID == profile.profileID, rules.profileHash == profile.contentHash else {
            throw EngineError(code: "profile_hash_mismatch", field: "rules.profileHash")
        }
        return rules
    }

    public static func resolve(version: String, hash: String) throws -> Ruleset {
        switch (version, hash) {
        case ("general-fitness-v0.2", numericRulesetHash): try numericV02()
        case ("general-fitness-swift1", fixedRulesetHash): try fixedV1()
        case ("general-fitness-exact-v1", exactRulesetHash): try exactV1()
        default: throw EngineError(code: "unknown_ruleset", field: "rules.version")
        }
    }

    static func fixedProfile() throws -> FixedExerciseProfile {
        let data = try resource(named: "fixed-exercise-profile")
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: data),
              case .string(let expected) = fields.removeValue(forKey: "contentHash"),
              expected == fixedProfileHash,
              try CanonicalJSON.sha256(.object(fields)) == expected else {
            throw EngineError(code: "profile_hash_mismatch", field: "profile.contentHash")
        }
        let profile = try JSONDecoder().decode(FixedExerciseProfile.self, from: data)
        guard profile.schemaVersion == 2, profile.profileID == "fixed-home-gym-v0.2",
              profile.sourceProfileID == "fixed-home-gym-v0.1",
              profile.sourceProfileHash == "508cff9a8cc292defccd8c017da28af28007942946d268b8468f6c5a6cc8bb15",
              profile.variantPolicyVersion == "movement-variant-v1" else {
            throw EngineError(code: "unknown_profile", field: "profile.profileId")
        }
        return profile
    }

    private static func loadRules(named name: String) throws -> Ruleset {
        let data = try resource(named: name)
        if name == "ruleset-exact-v1" {
            guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: data),
                  fields.removeValue(forKey: "hash") == .string(exactRulesetHash),
                  try CanonicalJSON.sha256(.object(fields)) == exactRulesetHash else {
                throw EngineError(code: "invalid_ruleset", field: "rules.hash")
            }
        }
        let rules = try JSONDecoder().decode(Ruleset.self, from: data)
        try rules.validateIntegrity()
        return rules
    }

    private static func resource(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw EngineError(code: "missing_resource", field: name)
        }
        return try Data(contentsOf: url)
    }
}

import Foundation

public struct GoalPreset: Codable, Equatable, Sendable {
    public var normalSets: Int
    public var repFloor: Int
    public var repCeiling: Int
    public var restSeconds: Int
    public var twoDaySets: Int?
    public var fallbackFloor: Int?
    public var fallbackCeiling: Int?
    public var defaultDays: Int

    public init(normalSets: Int, repFloor: Int, repCeiling: Int, restSeconds: Int, twoDaySets: Int? = nil, fallbackFloor: Int? = nil, fallbackCeiling: Int? = nil, defaultDays: Int) {
        self.normalSets = normalSets
        self.repFloor = repFloor
        self.repCeiling = repCeiling
        self.restSeconds = restSeconds
        self.twoDaySets = twoDaySets
        self.fallbackFloor = fallbackFloor
        self.fallbackCeiling = fallbackCeiling
        self.defaultDays = defaultDays
    }

    enum CodingKeys: String, CodingKey {
        case normalSets
        case repFloor
        case repCeiling
        case restSeconds
        case twoDaySets
        case fallbackFloor
        case fallbackCeiling
        case defaultDays
    }

}

public struct RuleParameters: Codable, Equatable, Sendable {
    public var normalMinimumRir: Int
    public var normalEffortInstruction: String
    public var stopInstruction: String
    public var easierMinimumRir: Int
    public var confirmationCount: Int
    public var setbackCount: Int
    public var maximumLoadIncreasePercent: Int
    public var repCeilingExtension: Int
    public var maximumRepCeiling: Int
    public var maximumStrengthRepCeiling: Int
    public var interruptionDays: Int
    public var plateauExposures: Int
    public var ceilingCopyTemplate: String

    public init(normalMinimumRir: Int, normalEffortInstruction: String, stopInstruction: String, easierMinimumRir: Int, confirmationCount: Int, setbackCount: Int, maximumLoadIncreasePercent: Int, repCeilingExtension: Int, maximumRepCeiling: Int, maximumStrengthRepCeiling: Int, interruptionDays: Int, plateauExposures: Int, ceilingCopyTemplate: String) {
        self.normalMinimumRir = normalMinimumRir
        self.normalEffortInstruction = normalEffortInstruction
        self.stopInstruction = stopInstruction
        self.easierMinimumRir = easierMinimumRir
        self.confirmationCount = confirmationCount
        self.setbackCount = setbackCount
        self.maximumLoadIncreasePercent = maximumLoadIncreasePercent
        self.repCeilingExtension = repCeilingExtension
        self.maximumRepCeiling = maximumRepCeiling
        self.maximumStrengthRepCeiling = maximumStrengthRepCeiling
        self.interruptionDays = interruptionDays
        self.plateauExposures = plateauExposures
        self.ceilingCopyTemplate = ceilingCopyTemplate
    }

    enum CodingKeys: String, CodingKey {
        case normalMinimumRir
        case normalEffortInstruction
        case stopInstruction
        case easierMinimumRir
        case confirmationCount
        case setbackCount
        case maximumLoadIncreasePercent
        case repCeilingExtension
        case maximumRepCeiling
        case maximumStrengthRepCeiling
        case interruptionDays
        case plateauExposures
        case ceilingCopyTemplate
    }

}

public struct EvidenceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var url: String
    public var locator: String
    public var population: String
    public var limitations: String
    public var relevantPassageReference: String
    public var adaptationRationale: String

    public init(id: String, url: String, locator: String, population: String, limitations: String, relevantPassageReference: String, adaptationRationale: String) {
        self.id = id
        self.url = url
        self.locator = locator
        self.population = population
        self.limitations = limitations
        self.relevantPassageReference = relevantPassageReference
        self.adaptationRationale = adaptationRationale
    }

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case locator
        case population
        case limitations
        case relevantPassageReference
        case adaptationRationale
    }

}

public struct RuleRecord: Codable, Equatable, Sendable {
    public var id: String
    public var condition: String
    public var action: String
    public var basis: String
    public var sourceIDs: [String]
    public var evidenceClass: EvidenceClass
    public var relevantPassageReference: String
    public var adaptationRationale: String

    public init(id: String, condition: String, action: String, basis: String, sourceIDs: [String], evidenceClass: EvidenceClass, relevantPassageReference: String, adaptationRationale: String) {
        self.id = id
        self.condition = condition
        self.action = action
        self.basis = basis
        self.sourceIDs = sourceIDs
        self.evidenceClass = evidenceClass
        self.relevantPassageReference = relevantPassageReference
        self.adaptationRationale = adaptationRationale
    }

    enum CodingKeys: String, CodingKey {
        case id
        case condition
        case action
        case basis
        case sourceIDs = "sourceIds"
        case evidenceClass
        case relevantPassageReference
        case adaptationRationale
    }

}

public struct Ruleset: Codable, Equatable, Sendable {
    public var version: String
    public var sourceIDs: [String]
    public var ruleIDs: [String]
    public var presetTable: String
    public var rulebook: String
    public var hash: String
    public var presets: [String: GoalPreset]?
    public var parameters: RuleParameters?
    public var rules: [RuleRecord]?
    public var sources: [EvidenceRecord]?
    public var sourceRulesetHash: String?
    public var profileID: String?
    public var profileHash: String?
    public var contractVersion: Int?

    public init(version: String, sourceIDs: [String], ruleIDs: [String], presetTable: String, rulebook: String, hash: String, presets: [String: GoalPreset]? = nil, parameters: RuleParameters? = nil, rules: [RuleRecord]? = nil, sources: [EvidenceRecord]? = nil, sourceRulesetHash: String? = nil, profileID: String? = nil, profileHash: String? = nil, contractVersion: Int? = nil) {
        self.version = version
        self.sourceIDs = sourceIDs
        self.ruleIDs = ruleIDs
        self.presetTable = presetTable
        self.rulebook = rulebook
        self.hash = hash
        self.presets = presets
        self.parameters = parameters
        self.rules = rules
        self.sources = sources
        self.sourceRulesetHash = sourceRulesetHash
        self.profileID = profileID
        self.profileHash = profileHash
        self.contractVersion = contractVersion
    }

    enum CodingKeys: String, CodingKey {
        case version
        case sourceIDs = "sourceIds"
        case ruleIDs = "ruleIds"
        case presetTable
        case rulebook
        case hash
        case presets
        case parameters
        case rules
        case sources
        case sourceRulesetHash
        case profileID = "profileId"
        case profileHash
        case contractVersion
    }

    /// Archived numeric v0.2 has textual tables. Resolve its exact approved constants
    /// without adding fields to its encoded object/hash. Fixed catalogs store constants.
    public func preset(goal: Goal, daysPerWeek: Int) throws -> GoalPreset {
        guard ["general-fitness-v0.2", "general-fitness-swift1"].contains(version) else {
            throw EngineError(code: "unknown_ruleset", field: "rules.version")
        }
        try validateIntegrity()
        guard [2, 3].contains(daysPerWeek), version != "general-fitness-swift1" || daysPerWeek == 3 else {
            throw EngineError(code: "invalid_day_count", field: "daysPerWeek")
        }
        if version == "general-fitness-swift1" {
            guard let preset = presets?[goal.rawValue] else { throw EngineError(code: "missing_preset", field: "presets") }
            return preset
        }
        return GoalPreset(
            normalSets: goal == .size ? (daysPerWeek == 2 ? 4 : 3) : (goal == .strength ? 3 : 2),
            repFloor: goal == .strength ? 4 : 8, repCeiling: goal == .strength ? 6 : 12,
            restSeconds: goal == .strength ? 180 : 120, twoDaySets: goal == .size ? 4 : nil,
            fallbackFloor: goal == .strength ? 8 : nil, fallbackCeiling: goal == .strength ? 12 : nil,
            defaultDays: goal == .maintenance ? 2 : 3)
    }

    public var resolvedParameters: RuleParameters {
        get throws {
            guard ["general-fitness-v0.2", "general-fitness-swift1"].contains(version) else {
                throw EngineError(code: "unknown_ruleset", field: "rules.version")
            }
            try validateIntegrity()
            if version == "general-fitness-swift1" {
                guard let parameters else { throw EngineError(code: "missing_parameters", field: "parameters") }
                return parameters
            }
            return RuleParameters(normalMinimumRir: 2,
                normalEffortInstruction: "Stop with roughly two good reps left; stop earlier for pain or loss of control.",
                stopInstruction: "Stop for pain or loss of control.", easierMinimumRir: 4,
                confirmationCount: 2, setbackCount: 2, maximumLoadIncreasePercent: 10,
                repCeilingExtension: 2, maximumRepCeiling: 20, maximumStrengthRepCeiling: 8,
                interruptionDays: 28, plateauExposures: 6, ceilingCopyTemplate: "Up to {ceiling} good reps")
        }
    }

    public func validateIntegrity() throws {
        var canonical = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(self))
        guard case .object(var fields) = canonical else { throw EngineError(code: "invalid_ruleset", field: "rules") }
        fields.removeValue(forKey: "hash")
        canonical = .object(fields)
        guard try CanonicalJSON.sha256(canonical) == hash,
              sourceIDs == (1...13).map({ String(format: "E%02d", $0) }),
              ruleIDs == (1...16).map({ String(format: "R%02d", $0) }) else { throw EngineError(code: "invalid_ruleset", field: "rules.hash") }
        if version == "general-fitness-swift1" {
            guard hash == RulesetCatalog.fixedRulesetHash, sourceRulesetHash == RulesetCatalog.numericRulesetHash,
                  profileHash == RulesetCatalog.fixedProfileHash,
                  contractVersion == 2, presets?.count == 4, parameters != nil,
                  rules?.map(\.id) == ruleIDs, sources?.map(\.id) == sourceIDs,
                  sources!.allSatisfy({ !$0.url.isEmpty && !$0.locator.isEmpty && !$0.population.isEmpty && !$0.limitations.isEmpty && !$0.relevantPassageReference.isEmpty && !$0.adaptationRationale.isEmpty }),
                  rules!.allSatisfy({ Set($0.sourceIDs).isSubset(of: Set(sourceIDs)) && !$0.adaptationRationale.isEmpty }) else { throw EngineError(code: "invalid_ruleset", field: "rules.catalog") }
        } else if version != "general-fitness-v0.2" || hash != RulesetCatalog.numericRulesetHash {
            throw EngineError(code: "unknown_ruleset", field: "rules.version")
        }
    }
}

import Foundation

public enum StarterProgramChoice: String, Codable, CaseIterable, Sendable {
    case upperBody = "upper_body"
    case wholeBodyGlutes = "whole_body_glutes"
}

/// Read-only typed view of an immutable source archive. Doses belong to its rules.
public struct StarterProgramDefinition: Decodable, Equatable, Sendable {
    public let choice: StarterProgramChoice
    public let schemaVersion: Int
    public let profileID: String
    public let contentHash: String
    public let sourceProfileID: String
    public let sourceProfileHash: String
    public let variantPolicyVersion: String
    public let daysPerWeek: Int
    public let coveragePolicy: String
    public let movements: [Movement]
    public let weeklySlots: [WeeklySlot]
    public let requiredMuscleGroups: [String]
    public let initialLoads: [String: Load?]
    public let requiredEquipment: [String]

    enum CodingKeys: String, CodingKey {
        case choice, schemaVersion, contentHash, sourceProfileHash, variantPolicyVersion
        case daysPerWeek, coveragePolicy, movements, weeklySlots, requiredMuscleGroups, initialLoads, requiredEquipment
        case profileID = "profileId"
        case sourceProfileID = "sourceProfileId"
    }
}

public struct MovementDose: Codable, Equatable, Sendable {
    public var initialSets: Int
    public var establishedSets: Int
    public var repFloor: Int
    public var initialRepCeiling: Int
    public var restSeconds: Int
    public var maximumRepCeiling: Int
    public var allowsIntroPromotion: Bool
    public var requiresHandlingReview: Bool

    public init(initialSets: Int, establishedSets: Int, repFloor: Int, initialRepCeiling: Int, restSeconds: Int, maximumRepCeiling: Int, allowsIntroPromotion: Bool, requiresHandlingReview: Bool) {
        self.initialSets = initialSets
        self.establishedSets = establishedSets
        self.repFloor = repFloor
        self.initialRepCeiling = initialRepCeiling
        self.restSeconds = restSeconds
        self.maximumRepCeiling = maximumRepCeiling
        self.allowsIntroPromotion = allowsIntroPromotion
        self.requiresHandlingReview = requiresHandlingReview
    }
}

public enum StarterDoseStage: String, Codable, Equatable, Sendable {
    case introductory, established, fixed
}

/// A confirmation records the selected load; a changed load needs a new review.
/// Setup revision is bound by the variant's independent state and context windows.
public enum StrengthHandlingChoice: Codable, Equatable, Sendable {
    case standardRange
    case lowRep(load: Load)
}

public struct StarterExerciseState: Codable, Equatable, Sendable {
    public var doseStage: StarterDoseStage
    public var strengthHandling: StrengthHandlingChoice?
    public var windows: [String: StarterComparisonWindow]

    public init(doseStage: StarterDoseStage, strengthHandling: StrengthHandlingChoice?, windows: [String: StarterComparisonWindow]) {
        self.doseStage = doseStage
        self.strengthHandling = strengthHandling
        self.windows = windows
    }
}

public struct StarterPrecedingMovement: Codable, Equatable, Sendable {
    public var baseMovementID: String
    public var normalSetCount: Int

    public init(baseMovementID: String, normalSetCount: Int) {
        self.baseMovementID = baseMovementID
        self.normalSetCount = normalSetCount
    }

    enum CodingKeys: String, CodingKey {
        case baseMovementID = "baseMovementId"
        case normalSetCount
    }
}

public struct StarterComparisonWindow: Codable, Equatable, Sendable {
    public var slotID: String
    public var contextKey: String
    public var context: ExactRepContext
    public var precedingDose: [StarterPrecedingMovement]
    public var ceilingStreak: Int
    public var strainStreak: Int
    public var shortfallStreak: Int
    public var introStreak: Int
    public var exposures: [Exposure]

    public init(slotID: String, contextKey: String, context: ExactRepContext, precedingDose: [StarterPrecedingMovement], ceilingStreak: Int, strainStreak: Int, shortfallStreak: Int, introStreak: Int, exposures: [Exposure]) {
        self.slotID = slotID
        self.contextKey = contextKey
        self.context = context
        self.precedingDose = precedingDose
        self.ceilingStreak = ceilingStreak
        self.strainStreak = strainStreak
        self.shortfallStreak = shortfallStreak
        self.introStreak = introStreak
        self.exposures = exposures
    }

    enum CodingKeys: String, CodingKey {
        case slotID = "slotId"
        case contextKey, context, precedingDose, ceilingStreak, strainStreak, shortfallStreak, introStreak, exposures
    }
}

import Foundation

public enum MissedGoalReason: String, Codable, Equatable, Sendable, CaseIterable {
    case effortLimit = "effort_limit"
    case timeInterruption = "time_interruption"
    case otherUnknown = "other_unknown"
}

public enum EffortScope: String, Codable, Equatable, Sendable, CaseIterable {
    case allWorkingSets = "all_working_sets"
}

public struct ExactRepState: Codable, Equatable, Sendable {
    public var normalTargets: [Int]
    public var shortfallStreak: Int
    public var lastSuitableNormalDate: LocalDate?
    public var setupReviewRequired: Bool

    public init(normalTargets: [Int], shortfallStreak: Int, lastSuitableNormalDate: LocalDate?, setupReviewRequired: Bool) {
        self.normalTargets = normalTargets
        self.shortfallStreak = shortfallStreak
        self.lastSuitableNormalDate = lastSuitableNormalDate
        self.setupReviewRequired = setupReviewRequired
    }

    enum CodingKeys: String, CodingKey {
        case normalTargets
        case shortfallStreak
        case lastSuitableNormalDate
        case setupReviewRequired
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        normalTargets = try c.decode([Int].self, forKey: .normalTargets)
        shortfallStreak = try c.decode(Int.self, forKey: .shortfallStreak)
        lastSuitableNormalDate = try c.decodeIfPresent(LocalDate.self, forKey: .lastSuitableNormalDate)
        setupReviewRequired = try c.decode(Bool.self, forKey: .setupReviewRequired)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(normalTargets, forKey: .normalTargets)
        try c.encode(shortfallStreak, forKey: .shortfallStreak)
        try c.encodeIfPresent(lastSuitableNormalDate, forKey: .lastSuitableNormalDate)
        try c.encode(setupReviewRequired, forKey: .setupReviewRequired)
    }
}

public struct ExactRepContext: Codable, Equatable, Sendable {
    public var variantID: String
    public var setupRevision: Int
    public var load: Load?
    public var normalSetCount: Int
    public var minimumRir: Int
    public var effortScope: EffortScope
    public var restSeconds: Int
    public var movementPosition: Int
    public var repFloor: Int
    public var repCeiling: Int
    public var rulesetHash: String

    public init(variantID: String, setupRevision: Int, load: Load?, normalSetCount: Int, minimumRir: Int, effortScope: EffortScope, restSeconds: Int, movementPosition: Int, repFloor: Int, repCeiling: Int, rulesetHash: String) {
        self.variantID = variantID
        self.setupRevision = setupRevision
        self.load = load
        self.normalSetCount = normalSetCount
        self.minimumRir = minimumRir
        self.effortScope = effortScope
        self.restSeconds = restSeconds
        self.movementPosition = movementPosition
        self.repFloor = repFloor
        self.repCeiling = repCeiling
        self.rulesetHash = rulesetHash
    }

    enum CodingKeys: String, CodingKey {
        case variantID = "variantId"
        case setupRevision
        case load
        case normalSetCount
        case minimumRir
        case effortScope
        case restSeconds
        case movementPosition
        case repFloor
        case repCeiling
        case rulesetHash
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variantID = try c.decode(String.self, forKey: .variantID)
        setupRevision = try c.decode(Int.self, forKey: .setupRevision)
        load = try c.decodeIfPresent(Load.self, forKey: .load)
        normalSetCount = try c.decode(Int.self, forKey: .normalSetCount)
        minimumRir = try c.decode(Int.self, forKey: .minimumRir)
        effortScope = try c.decode(EffortScope.self, forKey: .effortScope)
        restSeconds = try c.decode(Int.self, forKey: .restSeconds)
        movementPosition = try c.decode(Int.self, forKey: .movementPosition)
        repFloor = try c.decode(Int.self, forKey: .repFloor)
        repCeiling = try c.decode(Int.self, forKey: .repCeiling)
        rulesetHash = try c.decode(String.self, forKey: .rulesetHash)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(variantID, forKey: .variantID)
        try c.encode(setupRevision, forKey: .setupRevision)
        try c.encodeIfPresent(load, forKey: .load)
        try c.encode(normalSetCount, forKey: .normalSetCount)
        try c.encode(minimumRir, forKey: .minimumRir)
        try c.encode(effortScope, forKey: .effortScope)
        try c.encode(restSeconds, forKey: .restSeconds)
        try c.encode(movementPosition, forKey: .movementPosition)
        try c.encode(repFloor, forKey: .repFloor)
        try c.encode(repCeiling, forKey: .repCeiling)
        try c.encode(rulesetHash, forKey: .rulesetHash)
    }
}

public struct ExactRepParameters: Codable, Equatable, Sendable {
    public var normalIncrementTotal: Int
    public var easyIncrementPerSet: Int
    public var minimumTargetReps: Int
    public var returnMaximumLoadPercent: Int

    public init(normalIncrementTotal: Int = 1, easyIncrementPerSet: Int = 2, minimumTargetReps: Int = 1, returnMaximumLoadPercent: Int = 90) {
        self.normalIncrementTotal = normalIncrementTotal
        self.easyIncrementPerSet = easyIncrementPerSet
        self.minimumTargetReps = minimumTargetReps
        self.returnMaximumLoadPercent = returnMaximumLoadPercent
    }

    enum CodingKeys: String, CodingKey {
        case normalIncrementTotal
        case easyIncrementPerSet
        case minimumTargetReps
        case returnMaximumLoadPercent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        normalIncrementTotal = try c.decode(Int.self, forKey: .normalIncrementTotal)
        easyIncrementPerSet = try c.decode(Int.self, forKey: .easyIncrementPerSet)
        minimumTargetReps = try c.decode(Int.self, forKey: .minimumTargetReps)
        returnMaximumLoadPercent = try c.decode(Int.self, forKey: .returnMaximumLoadPercent)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(normalIncrementTotal, forKey: .normalIncrementTotal)
        try c.encode(easyIncrementPerSet, forKey: .easyIncrementPerSet)
        try c.encode(minimumTargetReps, forKey: .minimumTargetReps)
        try c.encode(returnMaximumLoadPercent, forKey: .returnMaximumLoadPercent)
    }
}

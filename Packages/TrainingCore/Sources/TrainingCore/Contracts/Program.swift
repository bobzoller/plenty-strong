import Foundation

public enum Goal: String, Codable, Equatable, Sendable, CaseIterable {
    case fatLoss = "fat_loss"
    case size
    case strength
    case maintenance
}

public enum LoadingMode: String, Codable, Equatable, Sendable, CaseIterable {
    case externalLoad = "external_load"
    case bodyweight
    case userManagedAssistance = "user_managed_assistance"
}

public enum LoadUnit: String, Codable, Equatable, Sendable, CaseIterable {
    case kg
    case lb
}

public enum LoadBasis: String, Codable, Equatable, Sendable, CaseIterable {
    case perImplement = "per_implement"
    case total
}

public enum RepCounting: String, Codable, Equatable, Sendable, CaseIterable {
    case total
    case perSide = "per_side"
}

public enum ExerciseMode: String, Codable, Equatable, Sendable, CaseIterable {
    case baseline
    case normal
    case paused
}

public struct Load: Codable, Equatable, Sendable {
    public var amount: String
    public var unit: LoadUnit
    public var basis: LoadBasis

    public init(amount: String, unit: LoadUnit, basis: LoadBasis) {
        self.amount = amount
        self.unit = unit
        self.basis = basis
    }

    enum CodingKeys: String, CodingKey {
        case amount
        case unit
        case basis
    }

}

public struct Movement: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var primaryMuscles: [String]
    public var secondaryMuscles: [String]
    public var lowRepLoadingPermission: Bool?
    public var loadProgressionPermission: Bool?
    public var repExtensionPermission: Bool?
    public var minimumRir: Int
    public var availableLoads: [Load]
    public var loadingModeValue: LoadingMode?
    public var implementCount: Int?
    public var repCountingValue: RepCounting?
    public var setupRevisionValue: Int?
    public var requiredEquipmentValue: [String]?
    public var initialLoad: Load?

    public init(id: String, name: String? = nil, primaryMuscles: [String], secondaryMuscles: [String], lowRepLoadingPermission: Bool? = nil, loadProgressionPermission: Bool? = nil, repExtensionPermission: Bool? = nil, minimumRir: Int, availableLoads: [Load], loadingModeValue: LoadingMode? = nil, implementCount: Int? = nil, repCountingValue: RepCounting? = nil, setupRevisionValue: Int? = nil, requiredEquipmentValue: [String]? = nil, initialLoad: Load? = nil) {
        self.id = id
        self.name = name
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.lowRepLoadingPermission = lowRepLoadingPermission
        self.loadProgressionPermission = loadProgressionPermission
        self.repExtensionPermission = repExtensionPermission
        self.minimumRir = minimumRir
        self.availableLoads = availableLoads
        self.loadingModeValue = loadingModeValue
        self.implementCount = implementCount
        self.repCountingValue = repCountingValue
        self.setupRevisionValue = setupRevisionValue
        self.requiredEquipmentValue = requiredEquipmentValue
        self.initialLoad = initialLoad
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case primaryMuscles
        case secondaryMuscles
        case lowRepLoadingPermission = "lowRepLoadingAllowed"
        case loadProgressionPermission = "automaticLoadProgressionAllowed"
        case repExtensionPermission = "automaticRepRangeExtensionAllowed"
        case minimumRir
        case availableLoads
        case loadingModeValue = "loadingMode"
        case implementCount
        case repCountingValue = "repCounting"
        case setupRevisionValue = "setupRevision"
        case requiredEquipmentValue = "requiredEquipment"
        case initialLoad
    }

    public var loadingMode: LoadingMode { get { loadingModeValue ?? .externalLoad } set { loadingModeValue = newValue } }
    public var repCounting: RepCounting { get { repCountingValue ?? .total } set { repCountingValue = newValue } }
    public var setupRevision: Int { get { setupRevisionValue ?? 1 } set { setupRevisionValue = newValue } }
    public var requiredEquipment: [String] { get { requiredEquipmentValue ?? [] } set { requiredEquipmentValue = newValue } }
    public var lowRepLoadingAllowed: Bool { get { lowRepLoadingPermission ?? false } set { lowRepLoadingPermission = newValue } }
    public var automaticLoadProgressionAllowed: Bool { get { loadProgressionPermission ?? false } set { loadProgressionPermission = newValue } }
    public var automaticRepRangeExtensionAllowed: Bool { get { repExtensionPermission ?? false } set { repExtensionPermission = newValue } }
}

public struct WeeklySlot: Codable, Equatable, Sendable {
    public var id: String
    public var weekday: Int?
    public var movementIDs: [String]

    public init(id: String, weekday: Int? = nil, movementIDs: [String]) {
        self.id = id
        self.weekday = weekday
        self.movementIDs = movementIDs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case weekday
        case movementIDs = "movementIds"
    }

}

public struct WorkoutSlot: Codable, Equatable, Sendable {
    public var date: LocalDate
    public var slotID: String

    public init(date: LocalDate, slotID: String) {
        self.date = date
        self.slotID = slotID
    }

    enum CodingKeys: String, CodingKey {
        case date
        case slotID = "slotId"
    }

}

public struct MovementVariant: Codable, Equatable, Sendable {
    public var id: String
    public var baseMovementID: String
    public var modifications: String

    public init(id: String, baseMovementID: String, modifications: String) {
        self.id = id
        self.baseMovementID = baseMovementID
        self.modifications = modifications
    }

    enum CodingKeys: String, CodingKey {
        case id
        case baseMovementID = "baseMovementId"
        case modifications
    }

}

public struct MovementSafetyState: Codable, Equatable, Sendable {
    public var paused: Bool
    public var minimumRir: Int
    public var sourceEventIDs: [String]

    public init(paused: Bool, minimumRir: Int, sourceEventIDs: [String]) {
        self.paused = paused
        self.minimumRir = minimumRir
        self.sourceEventIDs = sourceEventIDs
    }

    enum CodingKeys: String, CodingKey {
        case paused
        case minimumRir
        case sourceEventIDs = "sourceEventIds"
    }

}

public struct ProgramConfig: Codable, Equatable, Sendable {
    public var programID: String
    public var goal: Goal
    public var daysPerWeek: Int
    public var movements: [Movement]
    public var weeklySlots: [WeeklySlot]
    public var requiredMuscleGroups: [String]
    public var initialLoads: [String: Load?]
    public var profileID: String?
    public var profileHash: String?
    public var sourceProfileID: String?
    public var sourceProfileHash: String?
    public var coveragePolicy: String?
    public var variantPolicyVersion: String?
    public var variants: [String: MovementVariant]?
    public var activeVariantIDs: [String: String]?

    public init(programID: String, goal: Goal, daysPerWeek: Int, movements: [Movement], weeklySlots: [WeeklySlot], requiredMuscleGroups: [String], initialLoads: [String: Load?], profileID: String? = nil, profileHash: String? = nil, sourceProfileID: String? = nil, sourceProfileHash: String? = nil, coveragePolicy: String? = nil, variantPolicyVersion: String? = nil, variants: [String: MovementVariant]? = nil, activeVariantIDs: [String: String]? = nil) {
        self.programID = programID
        self.goal = goal
        self.daysPerWeek = daysPerWeek
        self.movements = movements
        self.weeklySlots = weeklySlots
        self.requiredMuscleGroups = requiredMuscleGroups
        self.initialLoads = initialLoads
        self.profileID = profileID
        self.profileHash = profileHash
        self.sourceProfileID = sourceProfileID
        self.sourceProfileHash = sourceProfileHash
        self.coveragePolicy = coveragePolicy
        self.variantPolicyVersion = variantPolicyVersion
        self.variants = variants
        self.activeVariantIDs = activeVariantIDs
    }

    enum CodingKeys: String, CodingKey {
        case programID = "programId"
        case goal
        case daysPerWeek
        case movements
        case weeklySlots
        case requiredMuscleGroups
        case initialLoads
        case profileID = "profileId"
        case profileHash
        case sourceProfileID = "sourceProfileId"
        case sourceProfileHash
        case coveragePolicy
        case variantPolicyVersion
        case variants
        case activeVariantIDs = "activeVariantIds"
    }

    /// Counts distinct weekly slots containing a primary or secondary muscle contribution.
    public var muscleExposureCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: requiredMuscleGroups.map { muscle in
            (muscle, weeklySlots.filter { slot in
                movements.contains { movement in slot.movementIDs.contains(movement.id) && (movement.primaryMuscles + movement.secondaryMuscles).contains(muscle) }
            }.count)
        })
    }
}

public struct ExerciseState: Codable, Equatable, Sendable {
    public var load: Load?
    public var mode: ExerciseMode
    public var normalSets: Int
    public var repFloor: Int
    public var repCeiling: Int
    public var ceilingStreak: Int
    public var strainStreak: Int
    public var lastCompletedDate: LocalDate?
    public var nextSetOverride: Int?
    public var interruptedReturn: Bool
    public var recentComparable: [Exposure]
    public var setupRevision: Int?

    public var exactRepState: ExactRepState?

    public init(load: Load?, mode: ExerciseMode, normalSets: Int, repFloor: Int, repCeiling: Int, ceilingStreak: Int, strainStreak: Int, lastCompletedDate: LocalDate?, nextSetOverride: Int?, interruptedReturn: Bool, recentComparable: [Exposure], setupRevision: Int? = nil, exactRepState: ExactRepState? = nil) {
        self.load = load
        self.mode = mode
        self.normalSets = normalSets
        self.repFloor = repFloor
        self.repCeiling = repCeiling
        self.ceilingStreak = ceilingStreak
        self.strainStreak = strainStreak
        self.lastCompletedDate = lastCompletedDate
        self.nextSetOverride = nextSetOverride
        self.interruptedReturn = interruptedReturn
        self.recentComparable = recentComparable
        self.setupRevision = setupRevision
        self.exactRepState = exactRepState
    }

    enum CodingKeys: String, CodingKey {
        case load
        case mode
        case normalSets
        case repFloor
        case repCeiling
        case ceilingStreak
        case strainStreak
        case lastCompletedDate
        case nextSetOverride
        case interruptedReturn
        case recentComparable
        case setupRevision
        case exactRepState
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        load = try c.decode(Load?.self, forKey: .load)
        mode = try c.decode(ExerciseMode.self, forKey: .mode)
        normalSets = try c.decode(Int.self, forKey: .normalSets)
        repFloor = try c.decode(Int.self, forKey: .repFloor)
        repCeiling = try c.decode(Int.self, forKey: .repCeiling)
        ceilingStreak = try c.decode(Int.self, forKey: .ceilingStreak)
        strainStreak = try c.decode(Int.self, forKey: .strainStreak)
        lastCompletedDate = try c.decode(LocalDate?.self, forKey: .lastCompletedDate)
        nextSetOverride = try c.decode(Int?.self, forKey: .nextSetOverride)
        interruptedReturn = try c.decode(Bool.self, forKey: .interruptedReturn)
        recentComparable = try c.decode([Exposure].self, forKey: .recentComparable)
        setupRevision = try c.decodeIfPresent(Int.self, forKey: .setupRevision)
        exactRepState = try c.decodeIfPresent(ExactRepState.self, forKey: .exactRepState)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(load, forKey: .load)
        try c.encode(mode, forKey: .mode)
        try c.encode(normalSets, forKey: .normalSets)
        try c.encode(repFloor, forKey: .repFloor)
        try c.encode(repCeiling, forKey: .repCeiling)
        try c.encode(ceilingStreak, forKey: .ceilingStreak)
        try c.encode(strainStreak, forKey: .strainStreak)
        try c.encode(lastCompletedDate, forKey: .lastCompletedDate)
        try c.encode(nextSetOverride, forKey: .nextSetOverride)
        try c.encode(interruptedReturn, forKey: .interruptedReturn)
        try c.encode(recentComparable, forKey: .recentComparable)
        try c.encodeIfPresent(setupRevision, forKey: .setupRevision)
        try c.encodeIfPresent(exactRepState, forKey: .exactRepState)
    }
}

public struct ProgramState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var rulesetVersion: String
    public var rulesetHash: String
    public var config: ProgramConfig
    public var revision: Int
    public var exercises: [String: ExerciseState]
    public var lastSessionDate: LocalDate?
    public var activePrescription: WorkoutPrescription
    public var processedEvents: [String: String]
    public var baseSafety: [String: MovementSafetyState]?

    public init(schemaVersion: Int, rulesetVersion: String, rulesetHash: String, config: ProgramConfig, revision: Int, exercises: [String: ExerciseState], lastSessionDate: LocalDate?, activePrescription: WorkoutPrescription, processedEvents: [String: String], baseSafety: [String: MovementSafetyState]? = nil) {
        self.schemaVersion = schemaVersion
        self.rulesetVersion = rulesetVersion
        self.rulesetHash = rulesetHash
        self.config = config
        self.revision = revision
        self.exercises = exercises
        self.lastSessionDate = lastSessionDate
        self.activePrescription = activePrescription
        self.processedEvents = processedEvents
        self.baseSafety = baseSafety
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case rulesetVersion
        case rulesetHash
        case config
        case revision
        case exercises
        case lastSessionDate
        case activePrescription
        case processedEvents
        case baseSafety
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        rulesetVersion = try c.decode(String.self, forKey: .rulesetVersion)
        rulesetHash = try c.decode(String.self, forKey: .rulesetHash)
        config = try c.decode(ProgramConfig.self, forKey: .config)
        revision = try c.decode(Int.self, forKey: .revision)
        exercises = try c.decode([String: ExerciseState].self, forKey: .exercises)
        lastSessionDate = try c.decode(LocalDate?.self, forKey: .lastSessionDate)
        activePrescription = try c.decode(WorkoutPrescription.self, forKey: .activePrescription)
        processedEvents = try c.decode([String: String].self, forKey: .processedEvents)
        baseSafety = try c.decodeIfPresent([String: MovementSafetyState].self, forKey: .baseSafety)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(rulesetVersion, forKey: .rulesetVersion)
        try c.encode(rulesetHash, forKey: .rulesetHash)
        try c.encode(config, forKey: .config)
        try c.encode(revision, forKey: .revision)
        try c.encode(exercises, forKey: .exercises)
        try c.encode(lastSessionDate, forKey: .lastSessionDate)
        try c.encode(activePrescription, forKey: .activePrescription)
        try c.encode(processedEvents, forKey: .processedEvents)
        try c.encodeIfPresent(baseSafety, forKey: .baseSafety)
    }
}

/// Read-only projection of frozen metadata. Hash the full raw resource, never this
/// projection: the archive also contains equipment, acceptance examples and provenance.
struct FixedExerciseProfile: Decodable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profileID: String
    public var contentHash: String
    public var sourceProfileID: String?
    public var sourceProfileHash: String?
    public var variantPolicyVersion: String?
    public var daysPerWeek: Int
    public var coveragePolicy: String
    public var movements: [Movement]
    public var weeklySlots: [WeeklySlot]
    public var requiredMuscleGroups: [String]
    public var initialLoads: [String: Load?]

    public init(schemaVersion: Int, profileID: String, contentHash: String, sourceProfileID: String? = nil, sourceProfileHash: String? = nil, variantPolicyVersion: String? = nil, daysPerWeek: Int, coveragePolicy: String, movements: [Movement], weeklySlots: [WeeklySlot], requiredMuscleGroups: [String], initialLoads: [String: Load?]) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.contentHash = contentHash
        self.sourceProfileID = sourceProfileID
        self.sourceProfileHash = sourceProfileHash
        self.variantPolicyVersion = variantPolicyVersion
        self.daysPerWeek = daysPerWeek
        self.coveragePolicy = coveragePolicy
        self.movements = movements
        self.weeklySlots = weeklySlots
        self.requiredMuscleGroups = requiredMuscleGroups
        self.initialLoads = initialLoads
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profileID = "profileId"
        case contentHash
        case sourceProfileID = "sourceProfileId"
        case sourceProfileHash
        case variantPolicyVersion
        case daysPerWeek
        case coveragePolicy
        case movements
        case weeklySlots
        case requiredMuscleGroups
        case initialLoads
    }

}

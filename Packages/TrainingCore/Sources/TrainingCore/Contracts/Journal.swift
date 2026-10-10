import Foundation

public enum VariantChange: Codable, Equatable, Sendable {
    case create(baseMovementID: String, variantID: String, modifications: String)
    case createLoadingMode(baseMovementID: String, variantID: String, modifications: String, mode: LoadingMode)
    case select(baseMovementID: String, variantID: String)
    case correctDescription(variantID: String, modifications: String)
    enum CodingKeys: String, CodingKey { case kind, modifications, mode; case baseMovementID = "baseMovementId"; case variantID = "variantId" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "create": self = .create(baseMovementID: try c.decode(String.self, forKey: .baseMovementID), variantID: try c.decode(String.self, forKey: .variantID), modifications: try c.decode(String.self, forKey: .modifications))
        case "createLoadingMode": self = .createLoadingMode(baseMovementID: try c.decode(String.self, forKey: .baseMovementID), variantID: try c.decode(String.self, forKey: .variantID), modifications: try c.decode(String.self, forKey: .modifications), mode: try c.decode(LoadingMode.self, forKey: .mode))
        case "select": self = .select(baseMovementID: try c.decode(String.self, forKey: .baseMovementID), variantID: try c.decode(String.self, forKey: .variantID))
        case "correctDescription": self = .correctDescription(variantID: try c.decode(String.self, forKey: .variantID), modifications: try c.decode(String.self, forKey: .modifications))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown VariantChange kind")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .create(baseMovementID, variantID, modifications):
            try c.encode("create", forKey: .kind)
            try c.encode(baseMovementID, forKey: .baseMovementID)
            try c.encode(variantID, forKey: .variantID)
            try c.encode(modifications, forKey: .modifications)
        case let .createLoadingMode(baseMovementID, variantID, modifications, mode):
            try c.encode("createLoadingMode", forKey: .kind)
            try c.encode(baseMovementID, forKey: .baseMovementID)
            try c.encode(variantID, forKey: .variantID)
            try c.encode(modifications, forKey: .modifications)
            try c.encode(mode, forKey: .mode)
        case let .select(baseMovementID, variantID):
            try c.encode("select", forKey: .kind)
            try c.encode(baseMovementID, forKey: .baseMovementID)
            try c.encode(variantID, forKey: .variantID)
        case let .correctDescription(variantID, modifications):
            try c.encode("correctDescription", forKey: .kind)
            try c.encode(variantID, forKey: .variantID)
            try c.encode(modifications, forKey: .modifications)
        }
    }
}

public enum ConfigurationChange: Codable, Equatable, Sendable {
    case reviewStrengthHandling(variantID: String, choice: StrengthHandlingChoice)
    case goal(Goal)
    case minimumRir(baseMovementID: String, value: Int)
    case resetSetup(variantID: String)
    case safeResume(baseMovementID: String, externalClearanceConfirmed: Bool)
    enum CodingKeys: String, CodingKey { case kind, value, externalClearanceConfirmed, choice; case baseMovementID = "baseMovementId"; case variantID = "variantId" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "reviewStrengthHandling": self = .reviewStrengthHandling(variantID: try c.decode(String.self, forKey: .variantID), choice: try c.decode(StrengthHandlingChoice.self, forKey: .choice))
        case "goal": self = .goal(try c.decode(Goal.self, forKey: .value))
        case "minimumRir": self = .minimumRir(baseMovementID: try c.decode(String.self, forKey: .baseMovementID), value: try c.decode(Int.self, forKey: .value))
        case "resetSetup": self = .resetSetup(variantID: try c.decode(String.self, forKey: .variantID))
        case "safeResume": self = .safeResume(baseMovementID: try c.decode(String.self, forKey: .baseMovementID), externalClearanceConfirmed: try c.decode(Bool.self, forKey: .externalClearanceConfirmed))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown ConfigurationChange kind")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .reviewStrengthHandling(variantID, choice):
            try c.encode("reviewStrengthHandling", forKey: .kind)
            try c.encode(variantID, forKey: .variantID)
            try c.encode(choice, forKey: .choice)
        case let .goal(value):
            try c.encode("goal", forKey: .kind)
            try c.encode(value, forKey: .value)
        case let .minimumRir(baseMovementID, value):
            try c.encode("minimumRir", forKey: .kind)
            try c.encode(baseMovementID, forKey: .baseMovementID)
            try c.encode(value, forKey: .value)
        case let .resetSetup(variantID):
            try c.encode("resetSetup", forKey: .kind)
            try c.encode(variantID, forKey: .variantID)
        case let .safeResume(baseMovementID, externalClearanceConfirmed):
            try c.encode("safeResume", forKey: .kind)
            try c.encode(baseMovementID, forKey: .baseMovementID)
            try c.encode(externalClearanceConfirmed, forKey: .externalClearanceConfirmed)
        }
    }
}

/// Each pure configuration/schedule command keeps these exact typed inputs.
/// Repository guards, started-draft invalidation and atomic persistence belong to
/// the adapter; replay must never substitute current dates, variants or labels.
public enum JournalCommand: Codable, Equatable, Sendable {
    case activateFlexibleScheduling
    case changeStarterProgram(choice: StarterProgramChoice, goal: Goal, next: WorkoutSlot)
    case activatePolicy(sourceRulesetHash: String, destinationRulesetHash: String, normalEvidenceEventIDs: [String], next: WorkoutSlot)
    case initialize(config: ProgramConfig, firstWorkout: WorkoutSlot)
    case workout(completedWorkout: CompletedWorkout, next: WorkoutSlot)
    case reconfigure(change: ConfigurationChange, next: WorkoutSlot)
    case variantChange(change: VariantChange, next: WorkoutSlot)
    case reschedule(slot: WorkoutSlot)
    case interruption(asOf: LocalDate)
    case resolveConflict(selection: BranchSelection, preservedHeadHashes: [String], originalArchiveHashes: [String], next: WorkoutSlot)
    enum CodingKeys: String, CodingKey { case kind, config, firstWorkout, completedWorkout, next, change, slot, asOf, selection, preservedHeadHashes, originalArchiveHashes, sourceRulesetHash, destinationRulesetHash, normalEvidenceEventIDs, choice, goal }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "activateFlexibleScheduling": self = .activateFlexibleScheduling
        case "changeStarterProgram": self = .changeStarterProgram(choice: try c.decode(StarterProgramChoice.self, forKey: .choice), goal: try c.decode(Goal.self, forKey: .goal), next: try c.decode(WorkoutSlot.self, forKey: .next))
        case "activatePolicy": self = .activatePolicy(sourceRulesetHash: try c.decode(String.self, forKey: .sourceRulesetHash), destinationRulesetHash: try c.decode(String.self, forKey: .destinationRulesetHash), normalEvidenceEventIDs: try c.decode([String].self, forKey: .normalEvidenceEventIDs), next: try c.decode(WorkoutSlot.self, forKey: .next))
        case "initialize": self = .initialize(config: try c.decode(ProgramConfig.self, forKey: .config), firstWorkout: try c.decode(WorkoutSlot.self, forKey: .firstWorkout))
        case "workout": self = .workout(completedWorkout: try c.decode(CompletedWorkout.self, forKey: .completedWorkout), next: try c.decode(WorkoutSlot.self, forKey: .next))
        case "reconfigure": self = .reconfigure(change: try c.decode(ConfigurationChange.self, forKey: .change), next: try c.decode(WorkoutSlot.self, forKey: .next))
        case "variantChange": self = .variantChange(change: try c.decode(VariantChange.self, forKey: .change), next: try c.decode(WorkoutSlot.self, forKey: .next))
        case "reschedule": self = .reschedule(slot: try c.decode(WorkoutSlot.self, forKey: .slot))
        case "interruption": self = .interruption(asOf: try c.decode(LocalDate.self, forKey: .asOf))
        case "resolveConflict": self = .resolveConflict(selection: try c.decode(BranchSelection.self, forKey: .selection), preservedHeadHashes: try c.decode([String].self, forKey: .preservedHeadHashes), originalArchiveHashes: try c.decode([String].self, forKey: .originalArchiveHashes), next: try c.decode(WorkoutSlot.self, forKey: .next))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown JournalCommand kind")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .activateFlexibleScheduling:
            try c.encode("activateFlexibleScheduling", forKey: .kind)
        case let .changeStarterProgram(choice, goal, next):
            try c.encode("changeStarterProgram", forKey: .kind)
            try c.encode(choice, forKey: .choice)
            try c.encode(goal, forKey: .goal)
            try c.encode(next, forKey: .next)
        case let .activatePolicy(source, destination, evidence, next):
            try c.encode("activatePolicy", forKey: .kind)
            try c.encode(source, forKey: .sourceRulesetHash)
            try c.encode(destination, forKey: .destinationRulesetHash)
            try c.encode(evidence, forKey: .normalEvidenceEventIDs)
            try c.encode(next, forKey: .next)
        case let .initialize(config, firstWorkout):
            try c.encode("initialize", forKey: .kind)
            try c.encode(config, forKey: .config)
            try c.encode(firstWorkout, forKey: .firstWorkout)
        case let .workout(completedWorkout, next):
            try c.encode("workout", forKey: .kind)
            try c.encode(completedWorkout, forKey: .completedWorkout)
            try c.encode(next, forKey: .next)
        case let .reconfigure(change, next):
            try c.encode("reconfigure", forKey: .kind)
            try c.encode(change, forKey: .change)
            try c.encode(next, forKey: .next)
        case let .variantChange(change, next):
            try c.encode("variantChange", forKey: .kind)
            try c.encode(change, forKey: .change)
            try c.encode(next, forKey: .next)
        case let .reschedule(slot):
            try c.encode("reschedule", forKey: .kind)
            try c.encode(slot, forKey: .slot)
        case let .interruption(asOf):
            try c.encode("interruption", forKey: .kind)
            try c.encode(asOf, forKey: .asOf)
        case let .resolveConflict(selection, preservedHeadHashes, originalArchiveHashes, next):
            try c.encode("resolveConflict", forKey: .kind)
            try c.encode(selection, forKey: .selection)
            try c.encode(preservedHeadHashes, forKey: .preservedHeadHashes)
            try c.encode(originalArchiveHashes, forKey: .originalArchiveHashes)
            try c.encode(next, forKey: .next)
        }
    }
}

/// Schema 2 journaling/replay must validate variant-keyed states, base safety for every
/// fixed base, positive per-variant setup revisions, and complete app log/prescription/
/// exposure snapshots. Legacy omissions are decode compatibility, never permission to
/// accept incomplete app events. Only parentless initialize commands are roots; all
/// other commands require a parent and the exact input state/revision hash. O6 owns
/// that validation and envelope hashing; these values do not infer missing data.
public struct JournalEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var datasetID: String
    public var programID: String
    public var eventID: String
    public var eventHash: String
    public var parentEnvelopeHash: String?
    public var inputRevision: Int
    public var inputStateHash: String?
    public var rulesetVersion: String
    public var rulesetHash: String
    public var profileID: String
    public var profileHash: String
    public var sourceProfileID: String
    public var sourceProfileHash: String
    public var command: JournalCommand
    public var returnedState: ProgramState
    public var returnedPrescription: WorkoutPrescription
    public var decisions: [Decision]
    public var envelopeHash: String

    public init(schemaVersion: Int, datasetID: String, programID: String, eventID: String, eventHash: String, parentEnvelopeHash: String?, inputRevision: Int, inputStateHash: String?, rulesetVersion: String, rulesetHash: String, profileID: String, profileHash: String, sourceProfileID: String, sourceProfileHash: String, command: JournalCommand, returnedState: ProgramState, returnedPrescription: WorkoutPrescription, decisions: [Decision], envelopeHash: String) {
        self.schemaVersion = schemaVersion
        self.datasetID = datasetID
        self.programID = programID
        self.eventID = eventID
        self.eventHash = eventHash
        self.parentEnvelopeHash = parentEnvelopeHash
        self.inputRevision = inputRevision
        self.inputStateHash = inputStateHash
        self.rulesetVersion = rulesetVersion
        self.rulesetHash = rulesetHash
        self.profileID = profileID
        self.profileHash = profileHash
        self.sourceProfileID = sourceProfileID
        self.sourceProfileHash = sourceProfileHash
        self.command = command
        self.returnedState = returnedState
        self.returnedPrescription = returnedPrescription
        self.decisions = decisions
        self.envelopeHash = envelopeHash
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case datasetID = "datasetId"
        case programID = "programId"
        case eventID = "eventId"
        case eventHash
        case parentEnvelopeHash
        case inputRevision
        case inputStateHash
        case rulesetVersion
        case rulesetHash
        case profileID = "profileId"
        case profileHash
        case sourceProfileID = "sourceProfileId"
        case sourceProfileHash
        case command
        case returnedState
        case returnedPrescription
        case decisions
        case envelopeHash
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        datasetID = try c.decode(String.self, forKey: .datasetID)
        programID = try c.decode(String.self, forKey: .programID)
        eventID = try c.decode(String.self, forKey: .eventID)
        eventHash = try c.decode(String.self, forKey: .eventHash)
        parentEnvelopeHash = try c.decode(String?.self, forKey: .parentEnvelopeHash)
        inputRevision = try c.decode(Int.self, forKey: .inputRevision)
        inputStateHash = try c.decode(String?.self, forKey: .inputStateHash)
        rulesetVersion = try c.decode(String.self, forKey: .rulesetVersion)
        rulesetHash = try c.decode(String.self, forKey: .rulesetHash)
        profileID = try c.decode(String.self, forKey: .profileID)
        profileHash = try c.decode(String.self, forKey: .profileHash)
        sourceProfileID = try c.decode(String.self, forKey: .sourceProfileID)
        sourceProfileHash = try c.decode(String.self, forKey: .sourceProfileHash)
        command = try c.decode(JournalCommand.self, forKey: .command)
        returnedState = try c.decode(ProgramState.self, forKey: .returnedState)
        returnedPrescription = try c.decode(WorkoutPrescription.self, forKey: .returnedPrescription)
        decisions = try c.decode([Decision].self, forKey: .decisions)
        envelopeHash = try c.decode(String.self, forKey: .envelopeHash)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(datasetID, forKey: .datasetID)
        try c.encode(programID, forKey: .programID)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(eventHash, forKey: .eventHash)
        try c.encode(parentEnvelopeHash, forKey: .parentEnvelopeHash)
        try c.encode(inputRevision, forKey: .inputRevision)
        try c.encode(inputStateHash, forKey: .inputStateHash)
        try c.encode(rulesetVersion, forKey: .rulesetVersion)
        try c.encode(rulesetHash, forKey: .rulesetHash)
        try c.encode(profileID, forKey: .profileID)
        try c.encode(profileHash, forKey: .profileHash)
        try c.encode(sourceProfileID, forKey: .sourceProfileID)
        try c.encode(sourceProfileHash, forKey: .sourceProfileHash)
        try c.encode(command, forKey: .command)
        try c.encode(returnedState, forKey: .returnedState)
        try c.encode(returnedPrescription, forKey: .returnedPrescription)
        try c.encode(decisions, forKey: .decisions)
        try c.encode(envelopeHash, forKey: .envelopeHash)
    }
}

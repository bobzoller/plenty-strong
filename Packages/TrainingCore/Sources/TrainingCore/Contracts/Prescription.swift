import Foundation

public enum PrescriptionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case working
    case baselineSetup = "baseline_setup"
    case paused
}

public enum PrescriptionPhase: String, Codable, Equatable, Sendable, CaseIterable {
    case baseline
    case normal
    case easier
    case returning = "return"
}

public enum DecisionAction: String, Codable, Equatable, Sendable, CaseIterable {
    case hold
    case increaseLoad = "increase_load"
    case reduceLoad = "reduce_load"
    case extendRepCeiling = "extend_rep_ceiling"
    case recover
    case pause
    case baseline
    case notice
}

public enum EvidenceClass: String, Codable, Equatable, Sendable, CaseIterable {
    case appAdaptation = "app_adaptation"
    case softwareRequirement = "software_requirement"
}

public struct SetPrescription: Codable, Equatable, Sendable {
    public var repFloor: Int
    public var repCeiling: Int
    public var effortInstruction: String

    public init(repFloor: Int, repCeiling: Int, effortInstruction: String) {
        self.repFloor = repFloor
        self.repCeiling = repCeiling
        self.effortInstruction = effortInstruction
    }

    enum CodingKeys: String, CodingKey {
        case repFloor
        case repCeiling
        case effortInstruction
    }

}

public struct ExercisePrescription: Codable, Equatable, Sendable {
    public var movementID: String
    public var kind: PrescriptionKind
    public var phase: PrescriptionPhase
    public var load: Load?
    public var sets: [SetPrescription]
    public var restSeconds: Int
    public var stopInstruction: String
    public var baseMovementID: String?
    public var modificationsSnapshot: String?

    public init(movementID: String, kind: PrescriptionKind, phase: PrescriptionPhase, load: Load?, sets: [SetPrescription], restSeconds: Int, stopInstruction: String, baseMovementID: String? = nil, modificationsSnapshot: String? = nil) {
        self.movementID = movementID
        self.kind = kind
        self.phase = phase
        self.load = load
        self.sets = sets
        self.restSeconds = restSeconds
        self.stopInstruction = stopInstruction
        self.baseMovementID = baseMovementID
        self.modificationsSnapshot = modificationsSnapshot
    }

    enum CodingKeys: String, CodingKey {
        case movementID = "movementId"
        case kind
        case phase
        case load
        case sets
        case restSeconds
        case stopInstruction
        case baseMovementID = "baseMovementId"
        case modificationsSnapshot
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movementID = try c.decode(String.self, forKey: .movementID)
        kind = try c.decode(PrescriptionKind.self, forKey: .kind)
        phase = try c.decode(PrescriptionPhase.self, forKey: .phase)
        load = try c.decode(Load?.self, forKey: .load)
        sets = try c.decode([SetPrescription].self, forKey: .sets)
        restSeconds = try c.decode(Int.self, forKey: .restSeconds)
        stopInstruction = try c.decode(String.self, forKey: .stopInstruction)
        baseMovementID = try c.decodeIfPresent(String.self, forKey: .baseMovementID)
        modificationsSnapshot = try c.decodeIfPresent(String.self, forKey: .modificationsSnapshot)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(movementID, forKey: .movementID)
        try c.encode(kind, forKey: .kind)
        try c.encode(phase, forKey: .phase)
        try c.encode(load, forKey: .load)
        try c.encode(sets, forKey: .sets)
        try c.encode(restSeconds, forKey: .restSeconds)
        try c.encode(stopInstruction, forKey: .stopInstruction)
        try c.encodeIfPresent(baseMovementID, forKey: .baseMovementID)
        try c.encodeIfPresent(modificationsSnapshot, forKey: .modificationsSnapshot)
    }
}

public struct WorkoutPrescription: Codable, Equatable, Sendable {
    public var id: String
    public var date: LocalDate
    public var slotID: String
    public var exercises: [ExercisePrescription]

    public init(id: String, date: LocalDate, slotID: String, exercises: [ExercisePrescription]) {
        self.id = id
        self.date = date
        self.slotID = slotID
        self.exercises = exercises
    }

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case slotID = "slotId"
        case exercises
    }

}

public struct Decision: Codable, Equatable, Sendable {
    public var movementID: String?
    public var action: DecisionAction
    public var ruleIDs: [String]
    public var sourceIDs: [String]
    public var evidenceClass: EvidenceClass
    public var explanationKey: String
    public var before: [String: CanonicalValue]
    public var after: [String: CanonicalValue]

    public init(movementID: String?, action: DecisionAction, ruleIDs: [String], sourceIDs: [String], evidenceClass: EvidenceClass, explanationKey: String, before: [String: CanonicalValue], after: [String: CanonicalValue]) {
        self.movementID = movementID
        self.action = action
        self.ruleIDs = ruleIDs
        self.sourceIDs = sourceIDs
        self.evidenceClass = evidenceClass
        self.explanationKey = explanationKey
        self.before = before
        self.after = after
    }

    enum CodingKeys: String, CodingKey {
        case movementID = "movementId"
        case action
        case ruleIDs = "ruleIds"
        case sourceIDs = "sourceIds"
        case evidenceClass
        case explanationKey
        case before
        case after
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movementID = try c.decode(String?.self, forKey: .movementID)
        action = try c.decode(DecisionAction.self, forKey: .action)
        ruleIDs = try c.decode([String].self, forKey: .ruleIDs)
        sourceIDs = try c.decode([String].self, forKey: .sourceIDs)
        evidenceClass = try c.decode(EvidenceClass.self, forKey: .evidenceClass)
        explanationKey = try c.decode(String.self, forKey: .explanationKey)
        before = try c.decode([String: CanonicalValue].self, forKey: .before)
        after = try c.decode([String: CanonicalValue].self, forKey: .after)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(movementID, forKey: .movementID)
        try c.encode(action, forKey: .action)
        try c.encode(ruleIDs, forKey: .ruleIDs)
        try c.encode(sourceIDs, forKey: .sourceIDs)
        try c.encode(evidenceClass, forKey: .evidenceClass)
        try c.encode(explanationKey, forKey: .explanationKey)
        try c.encode(before, forKey: .before)
        try c.encode(after, forKey: .after)
    }
}

public struct EngineError: Codable, Equatable, Sendable {
    public var code: String
    public var field: String

    public init(code: String, field: String) {
        self.code = code
        self.field = field
    }

    enum CodingKeys: String, CodingKey {
        case code
        case field
    }

}

extension EngineError: Error {}

public struct AdvanceInput: Codable, Equatable, Sendable {
    public var state: ProgramState
    public var event: CompletedWorkout
    public var rules: Ruleset
    public var nextSlotID: String
    public var nextWorkoutDate: LocalDate

    public init(state: ProgramState, event: CompletedWorkout, rules: Ruleset, nextSlotID: String, nextWorkoutDate: LocalDate) {
        self.state = state
        self.event = event
        self.rules = rules
        self.nextSlotID = nextSlotID
        self.nextWorkoutDate = nextWorkoutDate
    }

    enum CodingKeys: String, CodingKey {
        case state
        case event
        case rules
        case nextSlotID = "nextSlotId"
        case nextWorkoutDate
    }

}

public enum AdvanceResult: Codable, Equatable, Sendable {
    case applied(nextState: ProgramState, nextWorkout: WorkoutPrescription, decisions: [Decision])
    case noOp(nextState: ProgramState, reason: ReplayReason)
    case rejected(nextState: ProgramState, errors: [String])
    enum CodingKeys: String, CodingKey { case kind, nextState, nextWorkout, decisions, reason, errors }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "applied": self = .applied(nextState: try c.decode(ProgramState.self, forKey: .nextState), nextWorkout: try c.decode(WorkoutPrescription.self, forKey: .nextWorkout), decisions: try c.decode([Decision].self, forKey: .decisions))
        case "no_op": self = .noOp(nextState: try c.decode(ProgramState.self, forKey: .nextState), reason: try c.decode(ReplayReason.self, forKey: .reason))
        case "rejected": self = .rejected(nextState: try c.decode(ProgramState.self, forKey: .nextState), errors: try c.decode([String].self, forKey: .errors))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown AdvanceResult kind")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .applied(nextState, nextWorkout, decisions):
            try c.encode("applied", forKey: .kind)
            try c.encode(nextState, forKey: .nextState)
            try c.encode(nextWorkout, forKey: .nextWorkout)
            try c.encode(decisions, forKey: .decisions)
        case let .noOp(nextState, reason):
            try c.encode("no_op", forKey: .kind)
            try c.encode(nextState, forKey: .nextState)
            try c.encode(reason, forKey: .reason)
        case let .rejected(nextState, errors):
            try c.encode("rejected", forKey: .kind)
            try c.encode(nextState, forKey: .nextState)
            try c.encode(errors, forKey: .errors)
        }
    }
}

public enum ReplayReason: String, Codable, Equatable, Sendable, CaseIterable {
    case eventReplayed = "event_replayed"
}

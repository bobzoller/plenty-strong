import Foundation

public enum Effort: String, Codable, Equatable, Sendable, CaseIterable {
    case tooEasy = "too_easy"
    case onTarget = "on_target"
    case tooHard = "too_hard"
    case unknown
}

public enum LogStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case completed
    case partial
    case skipped
    case stopped
}

public enum Problem: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    case pain
    case controlLost = "control_lost"
}

public enum SessionMode: String, Codable, Equatable, Sendable, CaseIterable {
    case normal
    case easier
}

public struct ActualSet: Codable, Equatable, Sendable {
    public var reps: Int
    public var leftReps: Int?
    public var rightReps: Int?

    public var setIndex: Int?
    public var missedGoalReason: MissedGoalReason?

    public init(reps: Int, leftReps: Int? = nil, rightReps: Int? = nil, setIndex: Int? = nil, missedGoalReason: MissedGoalReason? = nil) {
        self.reps = reps
        self.leftReps = leftReps
        self.rightReps = rightReps
        self.setIndex = setIndex
        self.missedGoalReason = missedGoalReason
    }

    enum CodingKeys: String, CodingKey {
        case reps
        case leftReps
        case rightReps
        case setIndex
        case missedGoalReason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reps = try c.decode(Int.self, forKey: .reps)
        leftReps = try c.decodeIfPresent(Int.self, forKey: .leftReps)
        rightReps = try c.decodeIfPresent(Int.self, forKey: .rightReps)
        setIndex = try c.decodeIfPresent(Int.self, forKey: .setIndex)
        missedGoalReason = try c.decodeIfPresent(MissedGoalReason.self, forKey: .missedGoalReason)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reps, forKey: .reps)
        try c.encodeIfPresent(leftReps, forKey: .leftReps)
        try c.encodeIfPresent(rightReps, forKey: .rightReps)
        try c.encodeIfPresent(setIndex, forKey: .setIndex)
        try c.encodeIfPresent(missedGoalReason, forKey: .missedGoalReason)
    }

}

public struct ExerciseLog: Codable, Equatable, Sendable {
    public var movementID: String
    public var prescriptionID: String
    public var status: LogStatus
    public var actualLoad: Load?
    public var actualSets: [ActualSet]
    public var finalEffort: Effort
    public var problem: Problem
    public var baseMovementID: String?
    public var modificationsSnapshot: String?

    public var effortScope: EffortScope?
    public var skippedSetIndices: [Int]?
    public var mixedLoads: Bool?

    public init(movementID: String, prescriptionID: String, status: LogStatus, actualLoad: Load?, actualSets: [ActualSet], finalEffort: Effort, problem: Problem, baseMovementID: String? = nil, modificationsSnapshot: String? = nil, effortScope: EffortScope? = nil, skippedSetIndices: [Int]? = nil, mixedLoads: Bool? = nil) {
        self.movementID = movementID
        self.prescriptionID = prescriptionID
        self.status = status
        self.actualLoad = actualLoad
        self.actualSets = actualSets
        self.finalEffort = finalEffort
        self.problem = problem
        self.baseMovementID = baseMovementID
        self.modificationsSnapshot = modificationsSnapshot
        self.effortScope = effortScope
        self.skippedSetIndices = skippedSetIndices
        self.mixedLoads = mixedLoads
    }

    enum CodingKeys: String, CodingKey {
        case movementID = "movementId"
        case prescriptionID = "prescriptionId"
        case status
        case actualLoad
        case actualSets
        case finalEffort
        case problem
        case baseMovementID = "baseMovementId"
        case modificationsSnapshot
        case effortScope
        case skippedSetIndices
        case mixedLoads
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movementID = try c.decode(String.self, forKey: .movementID)
        prescriptionID = try c.decode(String.self, forKey: .prescriptionID)
        status = try c.decode(LogStatus.self, forKey: .status)
        actualLoad = try c.decode(Load?.self, forKey: .actualLoad)
        actualSets = try c.decode([ActualSet].self, forKey: .actualSets)
        finalEffort = try c.decode(Effort.self, forKey: .finalEffort)
        problem = try c.decode(Problem.self, forKey: .problem)
        baseMovementID = try c.decodeIfPresent(String.self, forKey: .baseMovementID)
        modificationsSnapshot = try c.decodeIfPresent(String.self, forKey: .modificationsSnapshot)
        effortScope = try c.decodeIfPresent(EffortScope.self, forKey: .effortScope)
        skippedSetIndices = try c.decodeIfPresent([Int].self, forKey: .skippedSetIndices)
        mixedLoads = try c.decodeIfPresent(Bool.self, forKey: .mixedLoads)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(movementID, forKey: .movementID)
        try c.encode(prescriptionID, forKey: .prescriptionID)
        try c.encode(status, forKey: .status)
        try c.encode(actualLoad, forKey: .actualLoad)
        try c.encode(actualSets, forKey: .actualSets)
        try c.encode(finalEffort, forKey: .finalEffort)
        try c.encode(problem, forKey: .problem)
        try c.encodeIfPresent(baseMovementID, forKey: .baseMovementID)
        try c.encodeIfPresent(modificationsSnapshot, forKey: .modificationsSnapshot)
        try c.encodeIfPresent(effortScope, forKey: .effortScope)
        try c.encodeIfPresent(skippedSetIndices, forKey: .skippedSetIndices)
        try c.encodeIfPresent(mixedLoads, forKey: .mixedLoads)
    }
}

public struct CompletedWorkout: Codable, Equatable, Sendable {
    public var eventID: String
    public var date: LocalDate
    public var slotID: String
    public var prescriptionID: String
    public var plannedPrescriptionID: String
    public var sessionMode: SessionMode
    public var exercises: [ExerciseLog]
    public var timing: SessionTiming? = nil

    public init(eventID: String, date: LocalDate, slotID: String, prescriptionID: String, plannedPrescriptionID: String, sessionMode: SessionMode, exercises: [ExerciseLog]) {
        self.eventID = eventID
        self.date = date
        self.slotID = slotID
        self.prescriptionID = prescriptionID
        self.plannedPrescriptionID = plannedPrescriptionID
        self.sessionMode = sessionMode
        self.exercises = exercises
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case date
        case slotID = "slotId"
        case prescriptionID = "prescriptionId"
        case plannedPrescriptionID = "plannedPrescriptionId"
        case sessionMode
        case exercises
        case timing
    }

}

/// Archived v0.2 exposures omit app snapshot fields. Schema 2 journal/replay validation
/// must require log, movementID (variant), baseMovementID, modificationsSnapshot,
/// effortInstruction, loadingMode, setupRevision and repCounting; snapshots must match
/// the accepted original command/prescription. Absence never means an invented default.
public struct Exposure: Codable, Equatable, Sendable {
    public var eventID: String
    public var date: LocalDate
    public var log: ExerciseLog?
    public var movementID: String?
    public var baseMovementID: String?
    public var modificationsSnapshot: String?
    public var load: Load?
    public var plannedSetCount: Int
    public var repFloor: Int
    public var repCeiling: Int
    public var effortInstruction: String?
    public var actualSets: [ActualSet]
    public var effort: Effort
    public var problem: Problem
    public var sessionMode: SessionMode
    public var phase: PrescriptionPhase
    public var loadingMode: LoadingMode?
    public var setupRevision: Int?
    public var repCounting: RepCounting?

    public var prescribedTargets: [Int]?
    public var exactRepContext: ExactRepContext?

    public init(eventID: String, date: LocalDate, log: ExerciseLog? = nil, movementID: String? = nil, baseMovementID: String? = nil, modificationsSnapshot: String? = nil, load: Load?, plannedSetCount: Int, repFloor: Int, repCeiling: Int, effortInstruction: String? = nil, actualSets: [ActualSet], effort: Effort, problem: Problem, sessionMode: SessionMode, phase: PrescriptionPhase, loadingMode: LoadingMode? = nil, setupRevision: Int? = nil, repCounting: RepCounting? = nil, prescribedTargets: [Int]? = nil, exactRepContext: ExactRepContext? = nil) {
        self.eventID = eventID
        self.date = date
        self.log = log
        self.movementID = movementID
        self.baseMovementID = baseMovementID
        self.modificationsSnapshot = modificationsSnapshot
        self.load = load
        self.plannedSetCount = plannedSetCount
        self.repFloor = repFloor
        self.repCeiling = repCeiling
        self.effortInstruction = effortInstruction
        self.actualSets = actualSets
        self.effort = effort
        self.problem = problem
        self.sessionMode = sessionMode
        self.phase = phase
        self.loadingMode = loadingMode
        self.setupRevision = setupRevision
        self.repCounting = repCounting
        self.prescribedTargets = prescribedTargets
        self.exactRepContext = exactRepContext
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case date
        case log
        case movementID = "movementId"
        case baseMovementID = "baseMovementId"
        case modificationsSnapshot
        case load
        case plannedSetCount
        case repFloor
        case repCeiling
        case effortInstruction
        case actualSets
        case effort
        case problem
        case sessionMode
        case phase
        case loadingMode
        case setupRevision
        case repCounting
        case prescribedTargets
        case exactRepContext
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decode(String.self, forKey: .eventID)
        date = try c.decode(LocalDate.self, forKey: .date)
        log = try c.decodeIfPresent(ExerciseLog.self, forKey: .log)
        movementID = try c.decodeIfPresent(String.self, forKey: .movementID)
        baseMovementID = try c.decodeIfPresent(String.self, forKey: .baseMovementID)
        modificationsSnapshot = try c.decodeIfPresent(String.self, forKey: .modificationsSnapshot)
        load = try c.decode(Load?.self, forKey: .load)
        plannedSetCount = try c.decode(Int.self, forKey: .plannedSetCount)
        repFloor = try c.decode(Int.self, forKey: .repFloor)
        repCeiling = try c.decode(Int.self, forKey: .repCeiling)
        effortInstruction = try c.decodeIfPresent(String.self, forKey: .effortInstruction)
        actualSets = try c.decode([ActualSet].self, forKey: .actualSets)
        effort = try c.decode(Effort.self, forKey: .effort)
        problem = try c.decode(Problem.self, forKey: .problem)
        sessionMode = try c.decode(SessionMode.self, forKey: .sessionMode)
        phase = try c.decode(PrescriptionPhase.self, forKey: .phase)
        loadingMode = try c.decodeIfPresent(LoadingMode.self, forKey: .loadingMode)
        setupRevision = try c.decodeIfPresent(Int.self, forKey: .setupRevision)
        repCounting = try c.decodeIfPresent(RepCounting.self, forKey: .repCounting)
        prescribedTargets = try c.decodeIfPresent([Int].self, forKey: .prescribedTargets)
        exactRepContext = try c.decodeIfPresent(ExactRepContext.self, forKey: .exactRepContext)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eventID, forKey: .eventID)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(log, forKey: .log)
        try c.encodeIfPresent(movementID, forKey: .movementID)
        try c.encodeIfPresent(baseMovementID, forKey: .baseMovementID)
        try c.encodeIfPresent(modificationsSnapshot, forKey: .modificationsSnapshot)
        try c.encode(load, forKey: .load)
        try c.encode(plannedSetCount, forKey: .plannedSetCount)
        try c.encode(repFloor, forKey: .repFloor)
        try c.encode(repCeiling, forKey: .repCeiling)
        try c.encodeIfPresent(effortInstruction, forKey: .effortInstruction)
        try c.encode(actualSets, forKey: .actualSets)
        try c.encode(effort, forKey: .effort)
        try c.encode(problem, forKey: .problem)
        try c.encode(sessionMode, forKey: .sessionMode)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(loadingMode, forKey: .loadingMode)
        try c.encodeIfPresent(setupRevision, forKey: .setupRevision)
        try c.encodeIfPresent(repCounting, forKey: .repCounting)
        try c.encodeIfPresent(prescribedTargets, forKey: .prescribedTargets)
        try c.encodeIfPresent(exactRepContext, forKey: .exactRepContext)
    }
}

/// Side observations remain raw; the summary never sums left and right.
public func normalizeSideLog(_ log: ExerciseLog, movement: Movement) throws -> ExerciseLog {
    var result = log
    for index in result.actualSets.indices {
        let set = result.actualSets[index]
        guard set.reps >= 0, (set.leftReps ?? 0) >= 0, (set.rightReps ?? 0) >= 0 else {
            throw EngineError(code: "invalid_reps", field: "actualSets")
        }
        guard movement.repCounting == .perSide else {
            guard set.leftReps == nil && set.rightReps == nil else { throw EngineError(code: "unexpected_side_reps", field: "actualSets") }
            continue
        }
        // Archived {reps} represents the confirmed per-side count. App raw sides are optional.
        if set.leftReps == nil && set.rightReps == nil {
            if (log.baseMovementID != nil || log.modificationsSnapshot != nil) && result.status == .completed { result.status = .partial }
            continue
        }
        if let left = set.leftReps, let right = set.rightReps {
            // Completed app counts are per-side counts, never the sum of sides.
            // Check the original completed row even if another set was partial.
            if (log.baseMovementID != nil || log.modificationsSnapshot != nil) &&
                log.status == .completed && left == right && left > 0 {
                guard set.reps == left else {
                    throw EngineError(code: "inconsistent_side_reps", field: "actualSets")
                }
            }
            result.actualSets[index].reps = min(left, right)
            if left != right || left == 0 { if result.status == .completed { result.status = .partial } }
        } else if result.status == .completed { result.status = .partial }
    }
    return result
}

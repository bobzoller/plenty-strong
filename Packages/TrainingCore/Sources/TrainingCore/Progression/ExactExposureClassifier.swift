import Foundation

struct ExactExposureClassification: Equatable {
    var actual: [Int]
    var priorTargets: [Int]
    var missReasons: [MissedGoalReason?]
    var complete: Bool
    var equalSides: Bool
    var confirmedLoad: Bool
    var sameLoad: Bool
    var knownEffort: Bool
    var effortLimitedMiss: Bool
    var cleanKnown: Bool
    var goalsMet: Bool
    var overshoot: Bool
    var aboveCeiling: Bool
    var firstSetFloorMiss: Bool
    var conflicting: Bool
    var strain: Bool
}

enum ExactExposureClassifier {
    static func classify(log: ExerciseLog, prescription: ExercisePrescription, movement: Movement,
                         state: ExerciseState, context: ExactRepContext) throws -> ExactExposureClassification {
        try validateIndexedExactLog(log, prescription: prescription)
        let ordered = log.actualSets.sorted { $0.setIndex! < $1.setIndex! }
        let targets = prescription.sets.compactMap(\.targetReps)
        let actual = ordered.map(\.reps)
        let complete = !targets.isEmpty && log.status == .completed && log.skippedSetIndices == [] &&
            ordered.map(\.setIndex) == targets.indices.map(Optional.some) && actual.allSatisfy { $0 > 0 }
        let equalSides = ordered.allSatisfy { set in
            if movement.repCounting == .perSide { return set.leftReps == set.reps && set.rightReps == set.reps }
            return (set.leftReps == nil && set.rightReps == nil) || (set.leftReps == set.reps && set.rightReps == set.reps)
        }
        let confirmed = movement.loadingMode == .externalLoad ?
            (log.actualLoad != nil && movement.availableLoads.contains(log.actualLoad!)) : log.actualLoad == nil
        let timeLimited = ordered.contains { $0.reps < targets[$0.setIndex!] && $0.missedGoalReason == .timeInterruption }
        let clean = !timeLimited && complete && equalSides && confirmed && log.mixedLoads == false && log.problem == .none && log.finalEffort != .unknown
        let met = complete && zip(actual, targets).allSatisfy { $0 >= $1 }
        let floorMiss = complete && actual.first! < state.repFloor
        let conflicting = log.finalEffort == .tooEasy && (!met || floorMiss)
        let missed = ordered.filter { $0.reps < targets[$0.setIndex!] }
        return ExactExposureClassification(actual: actual, priorTargets: targets, missReasons: ordered.map(\.missedGoalReason),
            complete: complete, equalSides: equalSides, confirmedLoad: confirmed, sameLoad: log.actualLoad == state.load,
            knownEffort: log.finalEffort != .unknown,
            effortLimitedMiss: !missed.isEmpty && missed.allSatisfy { $0.missedGoalReason == .effortLimit },
            cleanKnown: clean, goalsMet: met, overshoot: met && actual != targets,
            aboveCeiling: actual.contains { $0 > context.repCeiling }, firstSetFloorMiss: floorMiss,
            conflicting: conflicting, strain: clean && !conflicting && (log.finalEffort == .tooHard || floorMiss))
    }
}

/// Targets are stored separately and deliberately absent from comparison identity.
func sameExactContext(_ lhs: ExactRepContext, _ rhs: ExactRepContext) -> Bool { lhs == rhs }

func exactContext(state: ProgramState, id: String, prescription: ExercisePrescription, position: Int,
                  actualLoad: Load?, rules: Ruleset) throws -> ExactRepContext {
    let variant = state.config.variants![id]!
    let movement = state.config.movements.first { $0.id == variant.baseMovementID }!
    let exercise = state.exercises[id]!
    let parameters = try rules.resolvedParameters
    return ExactRepContext(variantID: id, setupRevision: exercise.setupRevision!, load: actualLoad,
        normalSetCount: exercise.normalSets, minimumRir: max(parameters.normalMinimumRir,
            max(movement.minimumRir, state.baseSafety![variant.baseMovementID]!.minimumRir)),
        effortScope: .allWorkingSets, restSeconds: prescription.restSeconds, movementPosition: position,
        repFloor: exercise.repFloor, repCeiling: exercise.repCeiling, rulesetHash: rules.hash)
}

func exactObservation(event: CompletedWorkout, log: ExerciseLog, prescription: ExercisePrescription,
                      movement: Movement, context: ExactRepContext) -> Exposure {
    Exposure(eventID: event.eventID, date: event.date, log: log, movementID: log.movementID,
        baseMovementID: log.baseMovementID, modificationsSnapshot: log.modificationsSnapshot,
        load: log.actualLoad, plannedSetCount: context.normalSetCount, repFloor: context.repFloor,
        repCeiling: context.repCeiling, effortInstruction: prescription.sets.first?.effortInstruction,
        actualSets: log.actualSets, effort: log.finalEffort, problem: log.problem,
        sessionMode: event.sessionMode, phase: prescription.phase, loadingMode: movement.loadingMode,
        setupRevision: context.setupRevision, repCounting: movement.repCounting,
        prescribedTargets: prescription.sets.compactMap(\.targetReps), exactRepContext: context)
}

func resetExactComparisons(_ exercise: inout ExerciseState) {
    resetComparisons(&exercise)
    exercise.exactRepState?.shortfallStreak = 0
}

import Foundation

/// One-time two-to-three-set growth. Eligibility is deliberately stricter than
/// ordinary rep progression; easier and skipped work cannot alter normal credit.
public func applyStarterIntroductoryDose(exercise: inout ExerciseState, dose: MovementDose,
                                        observation: Exposure, windowKey: String) throws -> Bool {
    guard observation.sessionMode != .easier, observation.log?.status != .skipped else { return false }
    guard let starter = exercise.starterState, var window = starter.windows[windowKey],
          let context = observation.exactRepContext, context == window.context,
          window.contextKey == windowKey else {
        throw EngineError(code: "invalid_context_window", field: "introductoryDose")
    }
    guard dose.allowsIntroPromotion, starter.doseStage == .introductory,
          dose.initialSets == 2, dose.establishedSets == 3,
          exercise.normalSets == dose.initialSets, !dose.requiresHandlingReview,
          exercise.mode == .normal, !exercise.interruptedReturn, exercise.nextSetOverride == nil,
          exercise.exactRepState?.setupReviewRequired == false else {
        window.introStreak = 0
        exercise.starterState!.windows[windowKey] = window
        return false
    }
    let log = observation.log
    let actual = observation.actualSets.sorted { ($0.setIndex ?? -1) < ($1.setIndex ?? -1) }
    let qualified = observation.phase == .normal && observation.problem == .none &&
        observation.effort != .unknown && observation.effort != .tooHard &&
        !observation.eventID.isEmpty &&
        (window.exposures.last.map { observation.date > $0.date && observation.eventID != $0.eventID } ?? (window.introStreak == 0)) &&
        observation.load == exercise.load && context.load == exercise.load &&
        observation.plannedSetCount == exercise.normalSets && context.normalSetCount == exercise.normalSets &&
        context.setupRevision == exercise.setupRevision && context.repFloor == exercise.repFloor &&
        context.repCeiling == exercise.repCeiling && context.restSeconds == dose.restSeconds &&
        ((observation.loadingMode == .bodyweight && observation.load == nil) ||
            (observation.loadingMode == .externalLoad && observation.load != nil)) &&
        observation.prescribedTargets == actual.map(\.reps) &&
        actual.count == exercise.normalSets && (actual.first?.reps ?? 0) >= exercise.repFloor && actual.map(\.setIndex) == actual.indices.map(Optional.some) &&
        actual.allSatisfy { $0.reps > 0 && $0.reps <= exercise.repCeiling &&
            (observation.repCounting == .perSide ? ($0.leftReps == $0.reps && $0.rightReps == $0.reps) :
                ($0.leftReps == nil && $0.rightReps == nil) || ($0.leftReps == $0.reps && $0.rightReps == $0.reps)) } &&
        log?.status == .completed && log?.skippedSetIndices == [] && log?.mixedLoads == false &&
        log?.effortScope == .allWorkingSets && log?.actualLoad == observation.load &&
        log?.actualSets == observation.actualSets && log?.finalEffort == observation.effort && log?.problem == Problem.none
    guard qualified else {
        window.introStreak = 0
        exercise.starterState!.windows[windowKey] = window
        return false
    }
    guard window.introStreak == 1 else {
        window.introStreak = 1
        exercise.starterState!.windows[windowKey] = window
        return false
    }
    var promoted = exercise
    promoted.exactRepState!.normalTargets = actual.map(\.reps)
    promoted = try resizeExactExerciseState(promoted, to: dose.establishedSets)
    promoted.starterState!.doseStage = .established
    resetStarterComparisons(&promoted)
    exercise = promoted
    return true
}

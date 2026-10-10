import Foundation

/// Existing native completion qualification shared by outcome confirmation and
/// correction demotion. Structural admission and progression remain separate.
public func qualifiesCompletedExercise(_ log: ExerciseLog, prescription row: ExercisePrescription,
                                       movement: Movement, schemaVersion: Int) -> Bool {
    let indexedComplete = ![3, 4].contains(schemaVersion) ||
        (log.skippedSetIndices == [] && log.mixedLoads == false &&
         Set(log.actualSets.compactMap(\.setIndex)) == Set(row.sets.indices))
    return indexedComplete && row.kind != .paused && !row.sets.isEmpty && log.problem == .none &&
        log.actualSets.count == row.sets.count && log.actualSets.allSatisfy { set in
            set.reps > 0 && (movement.repCounting != .perSide ||
                (set.leftReps != nil && set.leftReps == set.rightReps && set.reps == set.leftReps))
        } && (movement.loadingMode != .externalLoad || log.actualLoad != nil)
}

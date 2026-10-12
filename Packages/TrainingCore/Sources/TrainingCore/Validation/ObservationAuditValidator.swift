import Foundation

/// Proves a declared trail against issued contracts, without qualifying originals
/// for progression or changing their raw values, load, skips or effort scope.
public enum ObservationAuditValidator {
    public static func originalLogs(effective: [ExerciseLog], audit: ObservationAudit?,
                                    prescription: WorkoutPrescription, config: ProgramConfig,
                                    schemaVersion: Int) throws -> [ExerciseLog] {
        guard let audit else { return effective }
        guard audit.version == 1 else { throw invalid("version") }
        guard [2, 3, 4, 5].contains(schemaVersion) else { throw invalid("schemaVersion") }
        guard Set(effective.map(\.movementID)).count == effective.count,
              Set(prescription.exercises.map(\.movementID)).count == prescription.exercises.count else {
            throw invalid("movementID")
        }
        var operations: Set<UUID> = []
        var protectedOutcomes: [String: LogStatus] = [:]
        var acknowledgedMovements: Set<String> = []
        for correction in audit.corrections {
            guard operations.insert(correction.operationID).inserted,
                  let log = effective.first(where: { $0.movementID == correction.movementID }),
                  let row = prescription.exercises.first(where: { $0.movementID == correction.movementID }),
                  let movement = config.movements.first(where: { $0.id == row.baseMovementID }),
                  log.prescriptionID == prescription.id,
                  log.baseMovementID == row.baseMovementID,
                  log.modificationsSnapshot == row.modificationsSnapshot,
                  row.kind != .paused, row.kind != .setupReview,
                  correction.setIndex >= 0, correction.setIndex < row.sets.count,
                  correction.before != correction.after else { throw invalid("binding") }
            // A later declared safety stop can dominate an earlier correction;
            // records do not independently prove when the safety flag was added.
            let safetyStop = log.problem != .none && log.status == .stopped
            // A correction cannot turn an explicit stop into another working attempt.
            guard correction.beforeStatus != .skipped, correction.afterStatus != .skipped,
                  correction.beforeStatus == correction.afterStatus ||
                    (correction.beforeStatus == .completed && correction.afterStatus == .partial),
                  log.problem == .none || safetyStop,
                  !acknowledgedMovements.contains(log.movementID) || correction.outcomeAcknowledged,
                  protectedOutcomes[log.movementID].map({
                      $0 == correction.beforeStatus || (safetyStop && correction.beforeStatus == .stopped)
                  }) ?? true else {
                throw invalid("outcome")
            }
            if correction.outcomeAcknowledged { acknowledgedMovements.insert(log.movementID) }
            // Demotion closes a declared completion even in legacy nil-ack drafts.
            // Only an initial unacknowledged partial remains eligible for its first outcome.
            if correction.afterStatus == .stopped ||
                (correction.afterStatus == .partial && (correction.outcomeAcknowledged || correction.beforeStatus == .completed)) {
                protectedOutcomes[log.movementID] = correction.afterStatus
            }
            if let protected = protectedOutcomes[log.movementID], log.status != protected && !safetyStop { throw invalid("outcome") }
            for (actual, status) in [(correction.before, correction.beforeStatus), (correction.after, correction.afterStatus)] {
                guard actual.reps >= 0, (actual.leftReps ?? 0) >= 0, (actual.rightReps ?? 0) >= 0 else {
                    throw invalid("actualSets")
                }
                if schemaVersion >= 3 {
                    guard actual.setIndex == correction.setIndex else { throw invalid("setIndex") }
                    if log.problem == .none && (status == .completed || !correction.outcomeAcknowledged),
                       let target = row.sets[correction.setIndex].targetReps,
                       actual.reps < target, actual.missedGoalReason == nil {
                        throw invalid("missedGoalReason")
                    }
                } else {
                    guard actual.setIndex == nil, actual.missedGoalReason == nil,
                          movement.repCounting == .perSide || (actual.leftReps == nil && actual.rightReps == nil) else {
                        throw invalid("legacyActualSets")
                    }
                }
            }
        }

        var originals = effective
        // Reverse equality proves both final replacement binding and continuity of
        // every same-set chain, including interleaved movement corrections.
        for correction in audit.corrections.reversed() {
            let (logIndex, setPosition) = try binding(correction, logs: originals, schemaVersion: schemaVersion)
            guard originals[logIndex].actualSets[setPosition] == correction.after else { throw invalid("chain") }
            originals[logIndex].actualSets[setPosition] = correction.before
            originals[logIndex].status = correction.beforeStatus
        }
        for log in originals {
            guard let row = prescription.exercises.first(where: { $0.movementID == log.movementID }) else { throw invalid("movementID") }
            if schemaVersion >= 3 {
                try validateIndexedExactLog(log, prescription: row)
            } else {
                // Legacy unindexed observations may retain raw overflow. An audit
                // neither removes those extras nor makes them issued correction keys.
                guard (log.actualSets.count <= row.sets.count ||
                       (log.actualSets.allSatisfy({ $0.setIndex == nil }) && (log.skippedSetIndices ?? []).isEmpty)),
                      log.status != .skipped || log.actualSets.isEmpty,
                      log.actualSets.allSatisfy({ $0.reps >= 0 && ($0.leftReps ?? 0) >= 0 && ($0.rightReps ?? 0) >= 0 }) else {
                    throw invalid("actualSets")
                }
            }
        }
        var replayed = originals
        for correction in audit.corrections {
            let (logIndex, setPosition) = try binding(correction, logs: replayed, schemaVersion: schemaVersion)
            guard replayed[logIndex].actualSets[setPosition] == correction.before else { throw invalid("chain") }
            replayed[logIndex].actualSets[setPosition] = correction.after
        }
        // Outcome confirmation and effort feedback may follow a correction; they
        // are not set edits. Protected outcomes were checked above independently.
        for index in replayed.indices { replayed[index].status = effective[index].status }
        guard replayed == effective else { throw invalid("replay") }
        return originals
    }

    private static func binding(_ correction: SetCorrection, logs: [ExerciseLog], schemaVersion: Int) throws -> (Int, Int) {
        guard let logIndex = logs.firstIndex(where: { $0.movementID == correction.movementID }) else { throw invalid("movementID") }
        let sets = logs[logIndex].actualSets
        if schemaVersion >= 3 {
            let positions = sets.indices.filter { sets[$0].setIndex == correction.setIndex }
            guard positions.count == 1 else { throw invalid("setIndex") }
            return (logIndex, positions[0])
        }
        guard sets.indices.contains(correction.setIndex), sets[correction.setIndex].setIndex == nil else { throw invalid("setIndex") }
        return (logIndex, correction.setIndex)
    }

    private static func invalid(_ field: String) -> EngineError {
        EngineError(code: "invalid_observation_audit", field: "observationAudit.\(field)")
    }
}

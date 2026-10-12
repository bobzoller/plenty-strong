import Foundation
import TrainingCore

/// Durable forward position. Back navigation is a separate, transient projection.
enum WorkoutStep: Codable, Equatable, Sendable {
    case introduction(movementID: String)
    case set(movementID: String, index: Int)
    case rest(sourceMovementID: String, sourceSetIndex: Int, destination: WorkoutRestDestination)
    case summary(movementID: String)
    case workoutReview
}

enum WorkoutRestDestination: Codable, Equatable, Sendable {
    case set(movementID: String, index: Int)
    case introduction(movementID: String)
}

struct WorkoutFlow: Codable, Equatable, Sendable {
    var version: Int = 1
    var forward: WorkoutStep
    var reviewedSummaryMovementIDs: [String]
}

/// Frozen inputs for the existing finalization transaction; persistence is owned
/// by the repository, never by reconciliation or a view projection.
struct PendingWorkoutFinish: Codable, Equatable, Sendable {
    var version: Int = 1
    var event: CompletedWorkout
    var next: WorkoutSlot
    var expectedRevision: Int
}

enum WorkoutFlowResolver {
    static func reconciled(_ draft: WorkoutDraft) throws -> WorkoutFlow {
        try validate(draft)
        if let flow = draft.flow { return flow }
        let acknowledged = Set(draft.acknowledgedMovementIDs ?? [])
        guard let row = draft.displayed.exercises.first(where: { !acknowledged.contains($0.movementID) }),
              let log = draft.logs.first(where: { $0.movementID == row.movementID }) else {
            return WorkoutFlow(forward: .workoutReview, reviewedSummaryMovementIDs: [])
        }
        let occupied = occupiedIndices(log)
        let step: WorkoutStep
        if log.problem != .none || log.status != .partial || hasDemotedCompletion(log, draft: draft) || (!occupied.isEmpty && nextIndex(log, row: row) == nil) {
            step = .summary(movementID: row.movementID)
        } else if occupied.isEmpty {
            step = .introduction(movementID: row.movementID)
        } else if let index = nextIndex(log, row: row) {
            step = .set(movementID: row.movementID, index: index)
        } else {
            step = .summary(movementID: row.movementID)
        }
        // A legacy deadline has no source/destination identity. It never proves
        // rest ownership, a reviewed summary, or a completed movement.
        return WorkoutFlow(forward: step, reviewedSummaryMovementIDs: [])
    }

    static func afterSummary(_ draft: WorkoutDraft, sourceIndex: Int) throws -> WorkoutStep {
        var projection = draft; projection.flow = nil
        let next = try WorkoutFlowResolver.reconciled(projection).forward
        let row = draft.displayed.exercises[sourceIndex], log = draft.logs[sourceIndex]
        if case let .introduction(nextID) = next, draft.displayed.exercises.indices.contains(sourceIndex + 1),
           draft.displayed.exercises[sourceIndex + 1].movementID == nextID,
           row.kind != .paused, row.kind != .setupReview,
           log.problem == .none, log.status != .stopped, log.status != .skipped, draft.restDeadline != nil, draft.restStartedAt != nil,
           let last = log.actualSets.enumerated().map({ $0.element.setIndex ?? $0.offset }).max(),
           row.sets.indices.contains(last) {
            return .rest(sourceMovementID: row.movementID, sourceSetIndex: last, destination: .introduction(movementID: nextID))
        }
        return next
    }

    static func validate(_ draft: WorkoutDraft) throws {
        if let anchor = draft.restStartedAt {
            guard anchor.timeIntervalSince1970.isFinite, WorkoutDraft.supportedRestDeadlineRange.contains(anchor),
                  let deadline = draft.restDeadline, deadline.timeIntervalSince1970.isFinite,
                  WorkoutDraft.supportedRestDeadlineRange.contains(deadline),
                  [120.0, 180.0].contains(deadline.timeIntervalSince(anchor)) else { throw invalid("rest_anchor") }
        }
        let rows = draft.displayed.exercises
        let ids = rows.map(\.movementID)
        let acknowledged = Set(draft.acknowledgedMovementIDs ?? [])
        guard Set(ids).count == ids.count, draft.logs.map(\.movementID) == ids,
              acknowledged.count == (draft.acknowledgedMovementIDs ?? []).count,
              acknowledged.isSubset(of: Set(ids)) else { throw invalid("binding") }
        for (row, log) in zip(rows, draft.logs) {
            let actual = performedIndices(log), skipped = log.skippedSetIndices ?? []
            let indexed = log.actualSets.contains { $0.setIndex != nil }
            guard !indexed || log.actualSets.allSatisfy({ $0.setIndex != nil }),
                  Set(actual).count == actual.count, Set(skipped).count == skipped.count,
                  Set(actual).isDisjoint(with: Set(skipped)),
                  // Legacy array-position observations were admitted without a
                  // prescribed-count bound. Retain raw overflow; reconciliation
                  // closes at Summary and cursor admission remains bounded.
                  ((!indexed && skipped.isEmpty) || (actual + skipped).allSatisfy({ row.sets.indices.contains($0) })) else { throw invalid("set_binding") }
        }
        if let flow = draft.flow {
            let reviewed = Set(flow.reviewedSummaryMovementIDs)
            guard flow.version == 1 else { throw invalid("version") }
            guard reviewed.count == flow.reviewedSummaryMovementIDs.count,
                  reviewed.isSubset(of: acknowledged) else { throw invalid("reviewedSummaryMovementIDs") }
            let firstUnhandled = ids.first(where: { !acknowledged.contains($0) })
            switch flow.forward {
            case let .introduction(id):
                let (row, log) = try binding(id, draft: draft)
                guard id == firstUnhandled, occupiedIndices(log).isEmpty,
                      log.problem == .none, log.status != .stopped, row.sets.isEmpty || log.status == .partial else { throw invalid("introduction") }
            case let .set(id, index):
                let (row, log) = try binding(id, draft: draft)
                guard id == firstUnhandled, row.kind != .paused, row.kind != .setupReview,
                      log.problem == .none, log.status == .partial, !hasDemotedCompletion(log, draft: draft),
                      nextIndex(log, row: row) == index else { throw invalid("set") }
            case let .summary(id):
                let (row, log) = try binding(id, draft: draft)
                guard acknowledged.contains(id) || (id == firstUnhandled &&
                    (log.problem != .none || log.status != .partial || nextIndex(log, row: row) == nil || hasDemotedCompletion(log, draft: draft))) else { throw invalid("summary") }
            case .workoutReview:
                // A correction may invalidate one review while this cursor stays
                // on Workout review. Finish readiness is checked independently.
                guard acknowledged == Set(ids) else { throw invalid("workoutReview") }
            case let .rest(source, sourceIndex, destination):
                let (row, log) = try binding(source, draft: draft)
                guard let deadline = draft.restDeadline, deadline.timeIntervalSince1970.isFinite,
                      WorkoutDraft.supportedRestDeadlineRange.contains(deadline),
                      row.sets.indices.contains(sourceIndex), performedIndices(log).contains(sourceIndex),
                      log.problem == .none, log.status != .stopped, log.status != .skipped,
                      row.kind != .paused, row.kind != .setupReview else { throw invalid("rest_source") }
                switch destination {
                case let .set(id, index):
                    guard occupiedIndices(log).max() == sourceIndex, id == source, source == firstUnhandled, log.status == .partial,
                          !hasDemotedCompletion(log, draft: draft), nextIndex(log, row: row) == index, index > sourceIndex else { throw invalid("rest_destination") }
                case let .introduction(id):
                    let (destinationRow, destinationLog) = try binding(id, draft: draft)
                    // Corrections can invalidate source review while retaining this cursor.
                    guard performedIndices(log).max() == sourceIndex,
                          occupiedIndices(log).max() == sourceIndex || draft.restStartedAt != nil,
                          acknowledged.contains(source), id == firstUnhandled,
                          let sourcePosition = ids.firstIndex(of: source), let destinationPosition = ids.firstIndex(of: id),
                          destinationPosition == sourcePosition + 1,
                          occupiedIndices(destinationLog).isEmpty, destinationLog.problem == .none,
                          destinationLog.status != .stopped,
                          destinationRow.sets.isEmpty || destinationLog.status == .partial else { throw invalid("rest_destination") }
                }
            }
        }
        if let pending = draft.pendingFinish { try validatePending(pending, draft: draft) }
    }

    private static func validatePending(_ pending: PendingWorkoutFinish, draft: WorkoutDraft) throws {
        let event = pending.event, ids = Set(draft.displayed.exercises.map(\.movementID))
        var expected = CompletedWorkout(eventID: draft.id.uuidString.lowercased(), date: draft.date,
            slotID: draft.displayed.slotID, prescriptionID: draft.displayed.id,
            plannedPrescriptionID: draft.planned.id, sessionMode: draft.sessionMode,
            exercises: draft.logs, observationAudit: draft.observationAudit)
        expected.timing = event.timing
        if let flow = draft.flow {
            guard flow.forward == .workoutReview, Set(draft.acknowledgedMovementIDs ?? []) == ids,
                  Set(flow.reviewedSummaryMovementIDs) == ids else { throw invalid("pendingFinish.review") }
        } else if let acknowledged = draft.acknowledgedMovementIDs {
            guard Set(acknowledged) == ids else { throw invalid("pendingFinish.outcomes") }
        } else {
            guard draft.logs.allSatisfy({ $0.status != .partial || $0.problem != .none }) else {
                throw invalid("pendingFinish.outcomes")
            }
        }
        guard pending.version == 1,
              pending.expectedRevision == draft.expectedRevision,
              // Canonical bytes bind raw text as well as values; Swift String
              // equality alone accepts canonically equivalent Unicode edits.
              try BackupService.bytes(event) == BackupService.bytes(expected),
              pending.next.date > max(draft.date, draft.planned.date) else { throw invalid("pendingFinish") }
        if let start = draft.startedAtMilliseconds {
            guard let timing = event.timing, timing.startedAtMilliseconds == start,
                  timing.timeZoneID == draft.timeZoneID else { throw invalid("pendingFinish.timing") }
            _ = try timing.validate(sessionDate: draft.date, plannedDate: draft.planned.date)
        } else {
            guard event.timing == nil else { throw invalid("pendingFinish.timing") }
        }
    }

    /// The repository/backup boundary validates the complete trail. A truthful
    /// demotion retains the declared completion's Summary even without an inferred
    /// acknowledgement, and cannot create another working attempt.
    static func hasDemotedCompletion(_ log: ExerciseLog, draft: WorkoutDraft) -> Bool {
        draft.observationAudit?.version == 1 && draft.observationAudit?.corrections.contains(where: {
            $0.movementID.utf8.elementsEqual(log.movementID.utf8) && $0.beforeStatus == .completed && $0.afterStatus == .partial
        }) == true
    }

    private static func binding(_ id: String, draft: WorkoutDraft) throws -> (ExercisePrescription, ExerciseLog) {
        guard let row = draft.displayed.exercises.first(where: { $0.movementID == id }),
              let log = draft.logs.first(where: { $0.movementID == id }) else { throw invalid("movementID") }
        return (row, log)
    }
    private static func performedIndices(_ log: ExerciseLog) -> [Int] {
        log.actualSets.enumerated().map { $0.element.setIndex ?? $0.offset }
    }
    private static func occupiedIndices(_ log: ExerciseLog) -> Set<Int> {
        Set(performedIndices(log) + (log.skippedSetIndices ?? []))
    }
    private static func nextIndex(_ log: ExerciseLog, row: ExercisePrescription) -> Int? {
        let occupied = occupiedIndices(log)
        return row.sets.indices.first(where: { !occupied.contains($0) })
    }
    private static func invalid(_ field: String) -> EngineError {
        EngineError(code: "integrity_conflict", field: "draft_flow.\(field)")
    }
}

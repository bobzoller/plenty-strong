import Foundation

/// Qualification uses a normalized copy; the caller's original log and side
/// observations remain untouched and are the journal's authoritative evidence.
struct ClassifiedExposure {
    let original: ExerciseLog
    let normalized: ExerciseLog
    let prescription: ExercisePrescription
    let knownLoad: Bool

    init(log: ExerciseLog, prescription: ExercisePrescription, movement: Movement) throws {
        original = log
        normalized = try normalizeSideLog(log, movement: movement)
        self.prescription = prescription
        knownLoad = movement.loadingMode != .externalLoad || log.actualLoad != nil
    }

    var complete: Bool {
        normalized.status == .completed && !normalized.actualSets.isEmpty &&
        normalized.actualSets.count == prescription.sets.count && normalized.actualSets.allSatisfy { $0.reps > 0 }
    }
    var aboveCeiling: Bool {
        zip(normalized.actualSets, prescription.sets).contains { $0.reps > $1.repCeiling }
    }
    var strained: Bool {
        normalized.finalEffort == .tooHard || zip(normalized.actualSets, prescription.sets).contains { $0.reps < $1.repFloor }
    }
    var cleanKnown: Bool {
        complete && knownLoad && normalized.problem == .none && normalized.finalEffort != .unknown && !aboveCeiling
    }
    var cleanReturn: Bool { cleanKnown && !strained }
    var atCeiling: Bool {
        zip(normalized.actualSets, prescription.sets).allSatisfy { $0.reps == $1.repCeiling }
    }

    func observation(event: CompletedWorkout, movement: Movement, exercise: ExerciseState, app: Bool) -> Exposure {
        Exposure(eventID: event.eventID, date: event.date, log: app ? original : nil,
            movementID: app ? original.movementID : nil, baseMovementID: app ? original.baseMovementID : nil,
            modificationsSnapshot: app ? original.modificationsSnapshot : nil, load: original.actualLoad,
            plannedSetCount: prescription.sets.count, repFloor: prescription.sets.first?.repFloor ?? exercise.repFloor,
            repCeiling: prescription.sets.first?.repCeiling ?? exercise.repCeiling,
            effortInstruction: app ? prescription.sets.first?.effortInstruction : nil,
            actualSets: original.actualSets, effort: original.finalEffort, problem: original.problem,
            sessionMode: event.sessionMode, phase: prescription.phase,
            loadingMode: app ? movement.loadingMode : nil, setupRevision: app ? exercise.setupRevision : nil,
            repCounting: app ? movement.repCounting : nil)
    }
}

func sameContext(_ exposure: Exposure, current: Exposure, app: Bool) -> Bool {
    exposure.load == current.load && exposure.plannedSetCount == current.plannedSetCount &&
    exposure.repFloor == current.repFloor && exposure.repCeiling == current.repCeiling &&
    (!app || (exposure.movementID == current.movementID && exposure.baseMovementID == current.baseMovementID &&
        exposure.setupRevision == current.setupRevision && exposure.loadingMode == current.loadingMode &&
        exposure.repCounting == current.repCounting)) &&
    (exposure.effortInstruction == nil && !app || exposure.effortInstruction == current.effortInstruction)
}

func plateauEligible(_ exposure: Exposure) -> Bool {
    exposure.phase == .normal && exposure.sessionMode == .normal && exposure.problem == .none &&
    exposure.effort == .onTarget && exposure.log?.status != .partial && exposure.log?.status != .skipped &&
    exposure.actualSets.count == exposure.plannedSetCount && exposure.actualSets.allSatisfy {
        let reps = min($0.leftReps ?? $0.reps, $0.rightReps ?? $0.reps)
        return reps >= exposure.repFloor && reps <= exposure.repCeiling &&
            (($0.leftReps == nil && $0.rightReps == nil) || $0.leftReps == $0.rightReps)
    }
}

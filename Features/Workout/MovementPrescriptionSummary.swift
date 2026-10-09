import TrainingCore

struct PriorPerformance {
    let date: LocalDate
    let actualSets: [ActualSet]
    let actualLoad: Load?
    let sessionMode: SessionMode
    let phase: PrescriptionPhase?
    let effortScope: EffortScope?
    let status: LogStatus
    let skippedSetIndices: [Int]?
    let contextLabels: [String]
}

struct MovementPrescriptionSummary {
    let prior: PriorPerformance?
    let targetReps: [Int]?
    let prescribedLoad: Load?
    let actualSets: [ActualSet]
    let isPriorComparable: Bool
    let policy: ProgramPolicy?
    let row: ExercisePrescription
    let actualLoad: Load?
    let skippedSetIndices: [Int]

    static func make(row: ExercisePrescription, state: ProgramState, history: [JournalEnvelope], draft: WorkoutDraft?) -> Self {
        let currentLog = draft?.programID == state.config.programID ? draft?.logs.first { $0.movementID == row.movementID } : nil
        let comparisonLoad = currentLog?.actualLoad ?? row.load
        let rules = try? RulesetCatalog.resolve(version: state.rulesetVersion, hash: state.rulesetHash)
        var policy = rules.flatMap { try? ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: $0) }
        let targets = row.sets.compactMap(\.targetReps)
        if policy?.usesExactTargets == true, targets.count != row.sets.count || zip(targets, row.sets).contains(where: { $0 < 1 || $0 > $1.repCeiling }) { policy = nil }
        let cutoff = draft?.date ?? state.activePrescription.date
        let candidates = history.enumerated().compactMap { index, envelope -> (Int, JournalEnvelope, CompletedWorkout, ExerciseLog)? in
            guard envelope.programID == state.config.programID, case let .workout(event, _) = envelope.command,
                  event.date < cutoff, let log = event.exercises.first(where: { $0.movementID == row.movementID }),
                  !log.actualSets.isEmpty else { return nil }
            return (index, envelope, event, log)
        }
        let last = candidates.max { a, b in a.2.date == b.2.date ? a.0 < b.0 : a.2.date < b.2.date }
        var prior: PriorPerformance?
        var comparable = false
        if let (_, envelope, event, log) = last {
            let issued = issuedWorkout(envelope: envelope, history: history)
            let priorRow = issued?.displayed.exercises.first { $0.movementID == row.movementID }
            var labels: [String] = []
            if log.actualLoad != comparisonLoad { labels.append("Different load") }
            if event.sessionMode == .easier { labels.append("Easier session") }
            if log.status != .completed { labels.append(log.status == .partial ? "Partial work" : "Stopped work") }
            if let issued, !issued.policy.usesExactTargets { labels.append("Legacy / final-set effort context") }
            else if log.effortScope != .allWorkingSets { labels.append("All-set effort scope unavailable") }
            if issued == nil { labels.append("Previous goals unavailable") }
            if let phase = priorRow?.phase, phase != .normal { labels.append(phase == .returning ? "Return workout" : phase == .baseline ? "Baseline workout" : "Easier workout") }
            if let issued, let previous = priorRow, policy?.usesExactTargets == true, issued.policy.usesExactTargets,
               let oldExercise = issued.state.exercises[row.movementID], let exercise = state.exercises[row.movementID],
               let movement = effectiveMovement(state: state, variantID: row.movementID) {
                comparable = event.sessionMode == .normal && draft?.sessionMode != .easier && previous.phase == .normal && row.phase == .normal &&
                    log.status == .completed && log.problem == .none && log.finalEffort != .unknown && log.effortScope == .allWorkingSets && log.mixedLoads == false && log.skippedSetIndices == [] &&
                    log.actualLoad == row.load && comparisonLoad == row.load && (movement.loadingMode != .externalLoad || log.actualLoad != nil) &&
                    (currentLog == nil || (currentLog?.effortScope == .allWorkingSets && currentLog?.mixedLoads == false)) &&
                    log.actualSets.map(\.setIndex).sorted { ($0 ?? -1) < ($1 ?? -1) } == previous.sets.indices.map(Optional.some) &&
                    log.actualSets.allSatisfy { set in set.reps > 0 && (movement.repCounting == .perSide ? set.leftReps == set.reps && set.rightReps == set.reps : (set.leftReps == nil && set.rightReps == nil) || (set.leftReps == set.reps && set.rightReps == set.reps)) } &&
                    (exercise.recentComparable + (exercise.starterState?.windows.values.flatMap(\.exposures) ?? [])).contains(where: { $0.eventID == event.eventID && $0.log == log }) &&
                    oldExercise.setupRevision == exercise.setupRevision && oldExercise.normalSets == exercise.normalSets && oldExercise.repFloor == exercise.repFloor && oldExercise.repCeiling == exercise.repCeiling &&
                    (policy != .starterExactV1 || (issued.displayed.slotID == (draft?.displayed ?? state.activePrescription).slotID &&
                        issued.state.config.profileHash == state.config.profileHash &&
                        issued.displayed.exercises.prefix(while: { $0.movementID != row.movementID }).map { ($0.baseMovementID ?? $0.movementID) + ":" + String(issued.state.exercises[$0.movementID]?.normalSets ?? -1) } ==
                        (draft?.displayed ?? state.activePrescription).exercises.prefix(while: { $0.movementID != row.movementID }).map { ($0.baseMovementID ?? $0.movementID) + ":" + String(state.exercises[$0.movementID]?.normalSets ?? -1) })) &&
                    previous.restSeconds == row.restSeconds && previous.sets.first?.effortInstruction == row.sets.first?.effortInstruction &&
                    previous.modificationsSnapshot == row.modificationsSnapshot && previous.baseMovementID == row.baseMovementID && issued.state.rulesetHash == state.rulesetHash &&
                    issued.displayed.exercises.firstIndex(where: { $0.movementID == row.movementID }) == (draft?.displayed ?? state.activePrescription).exercises.firstIndex(where: { $0.movementID == row.movementID })
            }
            if !comparable, labels.isEmpty { labels.append("Context only — comparison conditions differ") }
            prior = PriorPerformance(date: event.date, actualSets: log.actualSets, actualLoad: log.actualLoad, sessionMode: event.sessionMode,
                phase: priorRow?.phase, effortScope: log.effortScope, status: log.status, skippedSetIndices: log.skippedSetIndices, contextLabels: labels)
        }
        return Self(prior: prior, targetReps: policy?.usesExactTargets == true ? targets : nil, prescribedLoad: policy == nil ? nil : row.load,
            actualSets: currentLog?.actualSets ?? [], isPriorComparable: comparable, policy: policy, row: row,
            actualLoad: currentLog?.actualLoad, skippedSetIndices: currentLog?.skippedSetIndices ?? [])
    }

    struct IssuedWorkout {
        let state: ProgramState
        let planned: WorkoutPrescription
        let displayed: WorkoutPrescription
        let policy: ProgramPolicy
    }
    /// Reprojects immutable input through its pinned core policy and checks both
    /// recorded IDs. Never borrows a current row, sibling, or next prescription.
    static func issuedWorkout(envelope: JournalEnvelope, history: [JournalEnvelope]) -> IssuedWorkout? {
        guard case let .workout(event, _) = envelope.command, let parentHash = envelope.parentEnvelopeHash else { return nil }
        let parents = history.filter { $0.envelopeHash == parentHash && $0.programID == envelope.programID && $0.datasetID == envelope.datasetID }
        guard parents.count == 1, let parent = parents.first, parent.returnedState.config.programID == envelope.programID,
              parent.returnedState.revision == envelope.inputRevision, (try? BackupService.hash(parent.returnedState)) == envelope.inputStateHash,
              parent.returnedState.schemaVersion == envelope.schemaVersion, parent.returnedState.rulesetVersion == envelope.rulesetVersion,
              parent.returnedState.rulesetHash == envelope.rulesetHash,
              let rules = try? RulesetCatalog.resolve(version: envelope.rulesetVersion, hash: envelope.rulesetHash),
              let policy = try? ProgramPolicy.resolve(schemaVersion: envelope.schemaVersion, rules: rules),
              let planned = try? prepareWorkout(state: parent.returnedState, rules: rules),
              let displayed = try? prepareWorkout(state: parent.returnedState, rules: rules, easierToday: event.sessionMode == .easier),
              planned.id == event.plannedPrescriptionID, displayed.id == event.prescriptionID,
              displayed.date == event.date, displayed.slotID == event.slotID,
              event.exercises.allSatisfy({ $0.prescriptionID == displayed.id }) else { return nil }
        return IssuedWorkout(state: parent.returnedState, planned: planned, displayed: displayed, policy: policy)
    }

    /// Registered variant metadata resolved against this exact stored state.
    /// Legacy schema 1 has no variants. Resolution failures never infer overrides.
    static func effectiveMovement(state: ProgramState, variantID: String) -> Movement? {
        guard let rules = try? RulesetCatalog.resolve(version: state.rulesetVersion, hash: state.rulesetHash),
              let policy = try? ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules) else { return nil }
        if policy.usesVariants {
            guard var movement = try? resolveEffectiveMovement(config: state.config, variantID: variantID, rules: rules) else { return nil }
            if movement.id == "db_floor_glute_bridge", movement.loadingMode == .bodyweight { movement.name = "Bodyweight Floor Glute Bridge" }
            return movement
        }
        return state.config.movements.first { $0.id == variantID }
    }
    static func reps(_ sets: [ActualSet], repCounting: RepCounting) -> String {
        let contiguous = sets.enumerated().allSatisfy { $0.element.setIndex == nil || $0.element.setIndex == $0.offset }
        if repCounting != .perSide, contiguous, sets.allSatisfy({ $0.leftReps == nil && $0.rightReps == nil }) {
            return sets.map { String($0.reps) }.joined(separator: " / ") + " reps"
        }
        return sets.enumerated().map { offset, set in
            let prefix = "Set \((set.setIndex ?? offset) + 1): "
            if repCounting == .perSide || set.leftReps != nil || set.rightReps != nil {
                if set.leftReps == nil && set.rightReps == nil { return prefix + "recorded reps \(set.reps); left unrecorded, right unrecorded" }
                return prefix + "left \(set.leftReps.map(String.init) ?? "unrecorded"), right \(set.rightReps.map(String.init) ?? "unrecorded")"
            }
            return prefix + "\(set.reps) reps"
        }.joined(separator: "; ")
    }
    static func load(_ load: Load) -> String { "\(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")" }
    static func goal(_ row: ExercisePrescription, policy: ProgramPolicy?, repCounting: RepCounting) -> String {
        guard let policy else { return "Prescription unavailable" }
        if row.kind == .paused { return "Paused — no working sets" }
        if row.kind == .setupReview { return "Setup review required — no working sets" }
        if policy.usesExactTargets {
            let targets = row.sets.compactMap(\.targetReps)
            guard targets.count == row.sets.count, !targets.isEmpty else { return "Prescription unavailable" }
            return targets.map(String.init).joined(separator: " / ") + " reps" + (repCounting == .perSide ? " per side" : "")
        }
        return row.sets.first.map { "Up to \($0.repCeiling) good reps" + (repCounting == .perSide ? " per side" : "") } ?? "No working sets"
    }
}

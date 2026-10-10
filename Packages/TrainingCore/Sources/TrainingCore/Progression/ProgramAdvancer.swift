import Foundation

/// Ordered, transactional value transition. The journal boundary owns expected
/// revision checks and immutable original commands, including ineligible rows.
public func advanceProgram(_ input: AdvanceInput) -> AdvanceResult {
    do {
        try rejectLegacyStarterFields(input.state)
        switch try ProgramPolicy.resolve(schemaVersion: input.state.schemaVersion, rules: input.rules) {
        case .starterExactV1: return advanceStarterProgram(input)
        case .fixedExactV1: return advanceExactProgram(input)
        case .numericV02, .fixedCeilingsV1: break
        }
        let eventHash = try CanonicalJSON.sha256(canonicalValue(input.event))
        // Replay precedes calendar/planned-ID checks; O6 applies this same ordering
        // before its revision guard. A replay never reinterprets old observations.
        if let previous = input.state.processedEvents[input.event.eventID] {
            return previous == eventHash ? .noOp(nextState: input.state, reason: .eventReplayed) :
                .rejected(nextState: input.state, errors: ["event_id_conflict"])
        }
        let displayed = try validateAdvance(input)
        let app = input.state.schemaVersion == 2
        let parameters = try input.rules.resolvedParameters
        let preset = try input.rules.preset(goal: input.state.config.goal, daysPerWeek: input.state.config.daysPerWeek)
        var state = input.state
        var decisions: [Decision] = []
        for prescription in displayed.exercises {
            let id = prescription.movementID
            let base = app ? state.config.variants![id]!.baseMovementID : id
            let movement = state.config.movements.first { $0.id == base }!
            let log = input.event.exercises.first { $0.movementID == id }!
            let classified = try ClassifiedExposure(log: log, prescription: prescription, movement: movement)
            let before = state.exercises[id]!
            var exercise = before
            let observation = classified.observation(event: input.event, movement: movement, exercise: before, app: app)
            let changedLoad = log.status != .skipped && !log.actualSets.isEmpty && log.actualLoad != nil && log.actualLoad != before.load
            // The explicit adapter may already have prepared this return while
            // retaining the real last completion. Do not detect the same gap again.
            let gap = !before.interruptedReturn && (before.lastCompletedDate.map {
                $0.days(until: input.event.date) >= parameters.interruptionDays
            } ?? false)
            let outcome: MovementOutcome
            if log.problem != .none {
                exercise.mode = .paused
                resetComparisons(&exercise)
                outcome = MovementOutcome(action: .pause, rules: ["R01"], key: "movement_paused")
                if app {
                    state.baseSafety![base]!.paused = true
                    if !state.baseSafety![base]!.sourceEventIDs.contains(input.event.eventID) {
                        state.baseSafety![base]!.sourceEventIDs.append(input.event.eventID)
                    }
                }
            } else if before.mode == .paused || state.baseSafety?[base]?.paused == true {
                // An ordinary workout cannot perform an implicit safe-resume.
                outcome = MovementOutcome(action: .hold, rules: ["R01"], key: "paused_preserved")
            } else if input.event.sessionMode == .easier {
                if changedLoad {
                    exercise.load = log.actualLoad
                    exercise.mode = .baseline
                    resetComparisons(&exercise)
                }
                outcome = MovementOutcome(action: .hold, rules: ["R03", "R04"], key: "easier_session_recorded")
            } else if gap || before.interruptedReturn {
                // A valid changed actual load is retained even on an ineligible return.
                if changedLoad { exercise.load = log.actualLoad; exercise.mode = .baseline }
                outcome = interruptionRule(exercise: &exercise, classified: classified, gap: gap, app: app)
            } else if before.mode == .baseline || (before.load == nil && movement.loadingMode == .externalLoad) {
                outcome = baselineRule(exercise: &exercise, classified: classified, movement: movement)
            } else if changedLoad {
                exercise.load = log.actualLoad
                exercise.mode = .baseline
                resetComparisons(&exercise)
                outcome = MovementOutcome(action: .baseline, rules: ["R07"], key: "actual_load_changed")
            } else if log.status == .skipped {
                outcome = MovementOutcome(action: .hold, rules: ["R07"], key: "skip_recorded")
            } else if !classified.cleanKnown || log.actualLoad != before.load {
                exercise.ceilingStreak = 0
                exercise.strainStreak = 0
                outcome = MovementOutcome(action: .hold, rules: ["R07"], key: "ineligible_observation",
                    notice: classified.aboveCeiling ? "rep_ceiling_exceeded" : nil)
            } else if before.nextSetOverride != nil {
                outcome = recoveryDoseRule(exercise: &exercise, classified: classified)
            } else {
                if let last = exercise.recentComparable.last, !sameContext(last, current: observation, app: app) {
                    resetComparisons(&exercise)
                }
                outcome = try progressionRule(exercise: &exercise, classified: classified, movement: movement,
                    goal: state.config.goal, preset: preset, parameters: parameters)
            }
            if classified.complete { exercise.lastCompletedDate = input.event.date }
            if outcome.appendComparable {
                exercise.recentComparable = Array((exercise.recentComparable + [observation]).suffix(parameters.plateauExposures))
            }
            state.exercises[id] = exercise
            // A strain-at-minimum-dose pause also gates every sibling setup.
            if app && exercise.mode == .paused && before.mode != .paused {
                state.baseSafety![base]!.paused = true
                if !state.baseSafety![base]!.sourceEventIDs.contains(input.event.eventID) {
                    state.baseSafety![base]!.sourceEventIDs.append(input.event.eventID)
                }
            }
            decisions.append(try decision(id: id, action: outcome.action, rules: outcome.rules, key: outcome.key,
                before: before, after: exercise, ruleset: input.rules))
            if let notice = outcome.notice {
                decisions.append(try decision(id: id, action: .notice, rules: outcome.rules, key: notice,
                    before: before, after: exercise, ruleset: input.rules))
            }
            if [.size, .strength].contains(state.config.goal), outcome.action == .hold,
               ["capacity_hold", "ceiling_confirmation", "maintenance_success"].contains(outcome.key),
               outcome.notice == nil, hasPlateau(exercise.recentComparable, current: observation, app: app, count: parameters.plateauExposures) {
                decisions.append(try decision(id: id, action: .notice, rules: ["R16"], key: "plateau_check",
                    before: before, after: exercise, ruleset: input.rules))
            }
        }
        state.revision += 1
        state.lastSessionDate = input.event.date
        state.processedEvents[input.event.eventID] = eventHash
        let workout = try plannedWorkout(state: state, rules: input.rules,
            slot: WorkoutSlot(date: input.nextWorkoutDate, slotID: input.nextSlotID))
        state.activePrescription = workout
        return .applied(nextState: state, nextWorkout: workout, decisions: decisions)
    } catch let error as EngineError {
        return .rejected(nextState: input.state, errors: [error.code])
    } catch {
        // Checked decimal/canonical failures cannot yield a partially applied state.
        return .rejected(nextState: input.state, errors: ["invalid_numeric_value"])
    }
}

private func validateAdvance(_ input: AdvanceInput) throws -> WorkoutPrescription {
    let state = input.state
    let event = input.event
    guard state.rulesetVersion == input.rules.version, state.rulesetHash == input.rules.hash else {
        throw EngineError(code: "ruleset_mismatch", field: "rules")
    }
    let planned = try prepareWorkout(state: state, rules: input.rules)
    let app = state.schemaVersion == 2
    let preset = try input.rules.preset(goal: state.config.goal, daysPerWeek: state.config.daysPerWeek)
    let parameters = try input.rules.resolvedParameters
    let expectedIDs = app ? Set(state.config.variants!.keys) : Set(state.config.movements.map(\.id))
    guard Set(state.exercises.keys) == expectedIDs, state.revision >= 0, state.revision < Int.max else {
        throw EngineError(code: "invalid_state", field: "exercises")
    }
    for (id, exercise) in state.exercises {
        let base = app ? state.config.variants![id]!.baseMovementID : id
        let movement = state.config.movements.first { $0.id == base }!
        let range = initialRepRange(movement: movement, goal: state.config.goal, preset: preset)
        let maximum = state.config.goal == .strength && movement.lowRepLoadingAllowed ? parameters.maximumStrengthRepCeiling : parameters.maximumRepCeiling
        guard exercise.normalSets == preset.normalSets, exercise.repFloor == range.floor,
              (range.ceiling...maximum).contains(exercise.repCeiling),
              (0..<parameters.confirmationCount).contains(exercise.ceilingStreak),
              (0..<parameters.setbackCount).contains(exercise.strainStreak),
              exercise.nextSetOverride == nil || (1...exercise.normalSets).contains(exercise.nextSetOverride!),
              !exercise.interruptedReturn || exercise.nextSetOverride != nil,
              exercise.recentComparable.count <= parameters.plateauExposures,
              exercise.load == nil || movement.availableLoads.contains(exercise.load!) else {
            throw EngineError(code: "invalid_state", field: "exercises.\(id)")
        }
        if app {
            guard let safety = state.baseSafety?[base], safety.minimumRir >= movement.minimumRir,
                  exercise.mode != .paused || safety.paused else {
                throw EngineError(code: "invalid_state", field: "baseSafety.\(base)")
            }
            for exposure in exercise.recentComparable {
                guard let log = exposure.log, exposure.movementID == id, exposure.baseMovementID == base,
                      log.movementID == id, log.baseMovementID == base,
                      exposure.modificationsSnapshot != nil, exposure.modificationsSnapshot == log.modificationsSnapshot,
                      exposure.effortInstruction?.isEmpty == false, exposure.loadingMode == movement.loadingMode,
                      exposure.setupRevision != nil && exposure.setupRevision! > 0,
                      exposure.repCounting == movement.repCounting,
                      exposure.load == log.actualLoad, exposure.actualSets == log.actualSets,
                      exposure.effort == log.finalEffort, exposure.problem == log.problem,
                      exposure.phase == .normal, exposure.sessionMode == .normal,
                      !exposure.eventID.isEmpty, !log.prescriptionID.isEmpty,
                      exposure.plannedSetCount > 0, exposure.repFloor >= 0, exposure.repCeiling >= exposure.repFloor else {
                    throw EngineError(code: "invalid_snapshot", field: "recentComparable.\(id)")
                }
                let normalized = try normalizeSideLog(log, movement: movement)
                guard normalized.status == .completed, normalized.actualSets.count == exposure.plannedSetCount,
                      normalized.actualSets.allSatisfy({ $0.reps > 0 }), log.finalEffort != .unknown,
                      log.problem == .none,
                      movement.loadingMode != .externalLoad || exposure.load != nil,
                      log.actualLoad == nil || movement.availableLoads.contains(log.actualLoad!) else {
                    throw EngineError(code: "invalid_snapshot", field: "recentComparable.\(id)")
                }
            }
        }
    }
    guard planned == (try plannedWorkout(state: state, rules: input.rules,
            slot: WorkoutSlot(date: planned.date, slotID: planned.slotID))) else {
        throw EngineError(code: "invalid_prescription", field: "activePrescription")
    }
    try validateCompletionDates(input)
    guard state.config.weeklySlots.contains(where: { $0.id == input.nextSlotID }) else {
        throw EngineError(code: "invalid_slot", field: "nextSlotId")
    }
    let displayed = try prepareWorkout(state: state, rules: input.rules, easierToday: event.sessionMode == .easier)
    guard event.slotID == planned.slotID, event.plannedPrescriptionID == planned.id, event.prescriptionID == displayed.id else {
        throw EngineError(code: "stale_prescription", field: "prescriptionId")
    }
    let ids = event.exercises.map(\.movementID)
    guard ids.count == Set(ids).count, Set(ids) == Set(displayed.exercises.map(\.movementID)) else {
        throw EngineError(code: "invalid_rows", field: "exercises")
    }
    for log in event.exercises {
        let prescription = displayed.exercises.first { $0.movementID == log.movementID }!
        let base = app ? state.config.variants![log.movementID]!.baseMovementID : log.movementID
        let movement = state.config.movements.first { $0.id == base }!
        guard log.prescriptionID == displayed.id else { throw EngineError(code: "stale_prescription", field: "exercises.prescriptionId") }
        if app {
            guard log.baseMovementID == base, log.modificationsSnapshot == prescription.modificationsSnapshot else {
                throw EngineError(code: "invalid_snapshot", field: "exercises")
            }
        }
        if let load = log.actualLoad {
            guard movement.loadingMode == .externalLoad, movement.availableLoads.contains(load) else {
                throw EngineError(code: "unavailable_load", field: "actualLoad")
            }
        }
        guard log.actualSets.count <= prescription.sets.count,
              log.status != .skipped || log.actualSets.isEmpty,
              log.status != .completed || (!log.actualSets.isEmpty && log.actualSets.count == prescription.sets.count && log.actualSets.allSatisfy({ $0.reps > 0 })) else {
            throw EngineError(code: "invalid_sets", field: "actualSets")
        }
        _ = try normalizeSideLog(log, movement: movement)
    }
    return displayed
}

private func canonicalValue(_ value: some Encodable) throws -> CanonicalValue {
    try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
}

private func decision(id: String, action: DecisionAction, rules: [String], key: String,
                      before: ExerciseState, after: ExerciseState, ruleset: Ruleset) throws -> Decision {
    // These are the source policy's approved evidence links, also frozen in app rules.
    let legacyEvidence = ["R03": ["E12"], "R06": ["E01", "E07"], "R07": ["E07"],
        "R10": ["E01", "E05"], "R11": ["E03"], "R12": ["E10"], "R13": ["E02", "E03"], "R14": ["E05", "E11"]]
    let sources = rules.flatMap { id in ruleset.rules?.first(where: { $0.id == id })?.sourceIDs ?? legacyEvidence[id] ?? [] }
    guard case .object(let b) = try canonicalValue(before), case .object(let a) = try canonicalValue(after) else {
        throw EngineError(code: "invalid_state", field: "decisions")
    }
    return Decision(movementID: id, action: action, ruleIDs: rules, sourceIDs: Array(Set(sources)).sorted(),
        evidenceClass: .appAdaptation, explanationKey: key, before: b, after: a)
}

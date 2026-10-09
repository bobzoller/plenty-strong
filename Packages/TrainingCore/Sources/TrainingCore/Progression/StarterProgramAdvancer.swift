import Foundation

/// Schema-4 transition: shared targets/load, bounded evidence per frozen context.
public func advanceStarterProgram(_ input: AdvanceInput) -> AdvanceResult {
    do {
        try validateStarterProgram(state: input.state, rules: input.rules)
        let eventHash = try CanonicalJSON.sha256(exactCanonical(input.event))
        if let previous = input.state.processedEvents[input.event.eventID] {
            return previous == eventHash ? .noOp(nextState: input.state, reason: .eventReplayed) :
                .rejected(nextState: input.state, errors: ["event_id_conflict"])
        }
        let displayed = try validateStarterAdvance(input)
        let parameters = input.rules.parameters!
        // All identities, doses and effective movements derive from the admitted
        // frozen input. No per-movement mutation can change another's context.
        let windows = try Dictionary(uniqueKeysWithValues: displayed.exercises.map {
            ($0.movementID, try admittedStarterWindow(state: input.state, prescription: displayed,
                variantID: $0.movementID, rules: input.rules))
        })
        var state = input.state
        var decisions: [Decision] = []
        for prescription in displayed.exercises {
            let id = prescription.movementID
            let base = prescription.baseMovementID!
            let movement = try resolveValidatedEffectiveMovement(config: input.state.config, variantID: id, rules: input.rules)
            let before = input.state.exercises[id]!
            let dose = try resolveValidatedMovementDose(config: input.state.config, variantID: id, exercise: before, rules: input.rules)
            let log = input.event.exercises.first { $0.movementID == id }!
            var exercise = state.exercises[id]!
            var window = windows[id]!
            let classified = try ExactExposureClassifier.classify(log: log, prescription: prescription,
                movement: movement, state: before, context: window.context)
            let observation = exactObservation(event: input.event, log: log, prescription: prescription,
                movement: movement, context: window.context)
            var action: DecisionAction = .hold
            var rule = "X02"
            var key = "ineligible_observation"
            var notice: String?
            var append = false
            var suitable = false
            let returning = before.interruptedReturn || before.nextSetOverride != nil
            if log.problem != .none {
                let family = input.rules.safetyFamilies![base]!
                state.retainedSafety![family]!.paused = true
                if !state.retainedSafety![family]!.sourceEventIDs.contains(input.event.eventID) {
                    state.retainedSafety![family]!.sourceEventIDs.append(input.event.eventID)
                }
                for sibling in projectStarterFamilySafety(&state, family: family, rules: input.rules) {
                    state.exercises[sibling]!.mode = .paused
                    resetStarterComparisons(&state.exercises[sibling]!)
                }
                exercise = state.exercises[id]!
                action = .pause; rule = "X01"; key = "movement_paused"
            } else if exercise.mode == .paused || state.baseSafety![base]!.paused {
                rule = "X01"; key = "paused_preserved"
            } else if before.exactRepState!.setupReviewRequired || dose.requiresHandlingReview {
                rule = "P05"; key = "setup_review_required"
            } else if input.event.sessionMode == .easier {
                if log.status != .skipped && !log.actualSets.isEmpty && log.mixedLoads == false &&
                    classified.confirmedLoad && !classified.sameLoad {
                    exercise.load = log.actualLoad
                    starterSeedBaseline(&exercise, loadChanged: true)
                }
                rule = "X09"; key = "easier_session_recorded"
            } else if !returning && before.exactRepState!.lastSuitableNormalDate.map({
                $0.days(until: input.event.date) >= parameters.interruptionDays
            }) == true {
                try beginExactInterruptedReturn(&exercise, movement: movement, rules: input.rules)
                resetStarterComparisons(&exercise)
                if before.load != exercise.load { clearStarterLoadHandling(&exercise) }
                action = .recover; rule = "X08"; key = "interruption_return"
            } else if log.status == .skipped {
                key = "skip_recorded"
            } else if log.mixedLoads == false && !log.actualSets.isEmpty && classified.confirmedLoad && !classified.sameLoad {
                exercise.load = log.actualLoad
                starterSeedBaseline(&exercise, loadChanged: true)
                if returning && classified.cleanKnown && !classified.conflicting && !classified.aboveCeiling && log.finalEffort != .tooHard {
                    exercise.exactRepState!.lastSuitableNormalDate = nil
                }
                action = .baseline; key = "actual_load_changed"
            } else if !classified.cleanKnown || !classified.sameLoad {
                removeStarterSlotWindow(&exercise, slot: window.slotID)
                if classified.aboveCeiling { notice = "rep_ceiling_exceeded" }
            } else if returning {
                resetStarterComparisons(&exercise)
                rule = "X08"; key = "return_observation_held"
                if !classified.conflicting && !classified.aboveCeiling && log.finalEffort != .tooHard {
                    starterSeedBaseline(&exercise)
                    exercise.exactRepState!.lastSuitableNormalDate = nil
                    action = .baseline; key = "return_baseline_restored"
                }
            } else if classified.conflicting {
                removeStarterSlotWindow(&exercise, slot: window.slotID)
                notice = "observation_conflict"
            } else if classified.strain {
                window.introStreak = 0; window.ceilingStreak = 0; window.shortfallStreak = 0
                rule = "X06"
                if window.strainStreak + 1 >= parameters.setbackCount {
                    if let lower = lowerExactLoad(movement: movement, current: exercise.load) {
                        exercise.load = lower
                        starterSeedBaseline(&exercise, loadChanged: true)
                        action = .reduceLoad; key = "strain_reduce_load"
                    } else {
                        exercise.exactRepState!.setupReviewRequired = true
                        resetStarterComparisons(&exercise)
                        key = "setup_review_required"
                    }
                } else {
                    window.strainStreak += 1
                    key = "first_set_floor_hold"
                    if log.finalEffort == .tooHard {
                        let plan = try starterPlan(classified, exercise: exercise, goal: state.config.goal,
                            effort: log.finalEffort, shortfall: 0)
                        exercise.exactRepState!.normalTargets = plan.targets
                        key = "strain_reduce_targets"
                    }
                    append = true
                }
            } else if classified.aboveCeiling {
                removeStarterSlotWindow(&exercise, slot: window.slotID)
                notice = "rep_ceiling_exceeded"
            } else {
                window.strainStreak = 0
                if before.mode == .baseline {
                    let plan = try starterPlan(classified, exercise: exercise, goal: state.config.goal,
                        effort: log.finalEffort, shortfall: 0)
                    exercise.exactRepState!.normalTargets = plan.targets
                    window.shortfallStreak = 0; window.ceilingStreak = 0; window.introStreak = 0
                    exercise.mode = .normal
                    action = .baseline; rule = "X03"; key = "baseline_fitted"
                    append = true; suitable = true
                } else {
                    saveStarterWindow(window, exercise: &exercise)
                    if try applyStarterIntroductoryDose(exercise: &exercise, dose: dose,
                        observation: observation, windowKey: window.contextKey) {
                        action = .baseline; rule = "P02"; key = "introductory_sets_promoted"
                        suitable = true
                    } else {
                        window = exercise.starterState!.windows[window.contextKey]!
                        append = true; suitable = true
                        let ceiling = classified.goalsMet && !classified.overshoot &&
                            classified.actual.allSatisfy { $0 == exercise.repCeiling } &&
                            (state.config.goal != .maintenance || log.finalEffort == .tooEasy)
                        if ceiling {
                            window.shortfallStreak = 0
                            rule = "X05"; key = "ceiling_confirmation"
                            if window.ceilingStreak + 1 < parameters.confirmationCount {
                                window.ceilingStreak += 1
                            } else if let higher = try permittedHigherExactLoad(movement: movement, current: exercise.load) {
                                exercise.load = higher
                                starterSeedBaseline(&exercise, loadChanged: true)
                                action = .increaseLoad; key = "load_increased"; append = false
                            } else {
                                window.ceilingStreak = 0
                                if movement.automaticRepRangeExtensionAllowed && exercise.repCeiling < dose.maximumRepCeiling {
                                    exercise.repCeiling = min(dose.maximumRepCeiling, exercise.repCeiling + parameters.repCeilingExtension)
                                    resetStarterComparisons(&exercise)
                                    let plan = try starterPlan(classified, exercise: exercise, goal: state.config.goal,
                                        effort: log.finalEffort, shortfall: 0)
                                    exercise.exactRepState!.normalTargets = plan.targets
                                    action = .extendRepCeiling; key = "rep_ceiling_extended"; rule = "P01"; append = false
                                } else { key = "equipment_limit_hold"; notice = "equipment_limit" }
                            }
                        } else {
                            window.ceilingStreak = 0
                            let plan = try starterPlan(classified, exercise: exercise, goal: state.config.goal,
                                effort: log.finalEffort, shortfall: window.shortfallStreak)
                            exercise.exactRepState!.normalTargets = plan.targets
                            window.shortfallStreak = plan.shortfallStreak
                            switch plan.kind {
                            case .increment: rule = "X04"; key = "exact_rep_increment"
                            case .adopt: rule = "X04"; key = "achieved_vector_adopted"
                            case .rebase: rule = "X07"; key = "effort_limited_rebase"
                            case .hold:
                                rule = classified.goalsMet ? "X04" : "X07"
                                key = plan.shortfallStreak == 1 ? "effort_limited_repeat" :
                                    state.config.goal == .maintenance && classified.goalsMet ? "maintenance_success" : "capacity_hold"
                            case .observationConflict: rule = "X02"; key = "ineligible_observation"; notice = "observation_conflict"
                            case .fitBaseline, .reduceTargets: throw EngineError(code: "invalid_exact_transition", field: "planner")
                            }
                        }
                    }
                }
            }
            if classified.complete { exercise.lastCompletedDate = input.event.date }
            if suitable { exercise.exactRepState!.lastSuitableNormalDate = input.event.date }
            if append {
                window.exposures = Array((window.exposures + [observation]).suffix(parameters.plateauExposures))
                saveStarterWindow(window, exercise: &exercise)
            }
            state.exercises[id] = exercise
            decisions.append(try exactDecision(id: id, action: action, rule: rule, key: key,
                before: before, after: exercise, rules: input.rules))
            if let notice { decisions.append(try exactDecision(id: id, action: .notice, rule: rule, key: notice,
                before: before, after: exercise, rules: input.rules)) }
            if [.size, .strength].contains(state.config.goal), append, action == .hold, notice == nil,
               starterPlateau(window.exposures, count: parameters.plateauExposures) {
                decisions.append(try exactDecision(id: id, action: .notice, rule: "X11", key: "plateau_check",
                    before: before, after: exercise, rules: input.rules))
            }
        }
        state.revision += 1
        state.lastSessionDate = input.event.date
        state.processedEvents[input.event.eventID] = eventHash
        state.activePrescription = try plannedStarterWorkout(state: state, rules: input.rules,
            slot: WorkoutSlot(date: input.nextWorkoutDate, slotID: input.nextSlotID))
        try validateStarterProgram(state: state, rules: input.rules)
        return .applied(nextState: state, nextWorkout: state.activePrescription, decisions: decisions)
    } catch let error as EngineError { return .rejected(nextState: input.state, errors: [error.code]) }
    catch { return .rejected(nextState: input.state, errors: ["invalid_numeric_value"]) }
}

private func validateStarterAdvance(_ input: AdvanceInput) throws -> WorkoutPrescription {
    let state = input.state
    let planned = state.activePrescription
    let event = input.event
    guard !event.eventID.isEmpty, event.date == planned.date,
          state.lastSessionDate == nil || event.date > state.lastSessionDate!, input.nextWorkoutDate > event.date else {
        throw EngineError(code: "invalid_date", field: "date")
    }
    try WorkoutScheduler.validate(slot: WorkoutSlot(date: input.nextWorkoutDate, slotID: input.nextSlotID), config: state.config)
    let displayed = try prepareStarterWorkout(state: state, rules: input.rules, easierToday: event.sessionMode == .easier)
    guard event.slotID == planned.slotID, event.plannedPrescriptionID == planned.id, event.prescriptionID == displayed.id else {
        throw EngineError(code: "stale_prescription", field: "prescriptionId")
    }
    let ids = event.exercises.map(\.movementID)
    guard ids.count == Set(ids).count, Set(ids) == Set(displayed.exercises.map(\.movementID)) else {
        throw EngineError(code: "invalid_rows", field: "exercises")
    }
    for log in event.exercises {
        let row = displayed.exercises.first { $0.movementID == log.movementID }!
        guard log.prescriptionID == displayed.id else { throw EngineError(code: "stale_prescription", field: "exercises.prescriptionId") }
        try validateIndexedExactLog(log, prescription: row)
        let movement = try resolveValidatedEffectiveMovement(config: state.config, variantID: log.movementID, rules: input.rules)
        if let load = log.actualLoad {
            guard movement.loadingMode == .externalLoad, movement.availableLoads.contains(load) else {
                throw EngineError(code: "unavailable_load", field: "actualLoad")
            }
        }
    }
    return displayed
}

private func starterPlan(_ classified: ExactExposureClassification, exercise: ExerciseState, goal: Goal,
                         effort: Effort, shortfall: Int) throws -> ExactRepPlanningResult {
    try ExactRepPlanner.plan(ExactRepPlanningInput(prescribed: classified.priorTargets,
        actual: classified.actual, ceiling: exercise.repCeiling, goal: goal,
        phase: exercise.mode == .baseline ? .baseline : .normal, effort: effort,
        missReasons: classified.missReasons, shortfallStreak: shortfall))
}

private func clearStarterLoadHandling(_ exercise: inout ExerciseState) {
    if case .lowRep = exercise.starterState!.strengthHandling { exercise.starterState!.strengthHandling = nil }
}
private func starterSeedBaseline(_ exercise: inout ExerciseState, loadChanged: Bool = false) {
    seedExactBaseline(&exercise)
    resetStarterComparisons(&exercise)
    if loadChanged { clearStarterLoadHandling(&exercise) }
}
private func removeStarterSlotWindow(_ exercise: inout ExerciseState, slot: String) {
    exercise.starterState!.windows = exercise.starterState!.windows.filter { $0.value.slotID != slot }
}
private func starterPlateau(_ exposures: [Exposure], count: Int) -> Bool {
    guard exposures.count == count, exposures.allSatisfy({ $0.phase == .normal && $0.sessionMode == .normal &&
        $0.effort == .onTarget && $0.problem == .none }), let first = exposures.first?.exactRepContext,
        exposures.allSatisfy({ $0.exactRepContext == first }) else { return false }
    let totals = exposures.map { $0.actualSets.reduce(0) { $0 + $1.reps } }
    let half = count / 2
    return totals.suffix(half).sorted()[half / 2] <= totals.prefix(half).sorted()[half / 2]
}

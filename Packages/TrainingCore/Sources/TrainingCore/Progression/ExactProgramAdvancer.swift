import Foundation

func advanceExactProgram(_ input: AdvanceInput) -> AdvanceResult {
    do {
        try validateExactRepContract(state: input.state, rules: input.rules)
        let eventHash = try exactCanonicalHash(input.event)
        if let previous = input.state.processedEvents[input.event.eventID] {
            return previous == eventHash ? .noOp(nextState: input.state, reason: .eventReplayed) :
                .rejected(nextState: input.state, errors: ["event_id_conflict"])
        }
        let displayed = try validateExactAdvance(input)
        let parameters = try input.rules.resolvedParameters
        var state = input.state
        var decisions: [Decision] = []
        for (position, prescription) in displayed.exercises.enumerated() {
            let id = prescription.movementID
            let base = prescription.baseMovementID!
            let movement = state.config.movements.first { $0.id == base }!
            let log = input.event.exercises.first { $0.movementID == id }!
            let before = state.exercises[id]!
            var exercise = before
            let context = try exactContext(state: state, id: id, prescription: prescription,
                                           position: position, actualLoad: log.actualLoad, rules: input.rules)
            let classified = try ExactExposureClassifier.classify(log: log, prescription: prescription,
                movement: movement, state: before, context: context)
            var action: DecisionAction = .hold
            var rule = "X02"
            var key = "ineligible_observation"
            var notice: String?
            var append = false
            var suitable = false

            if log.problem != .none {
                // A problem gates the shared base, including every saved sibling.
                state.baseSafety![base]!.paused = true
                if !state.baseSafety![base]!.sourceEventIDs.contains(input.event.eventID) {
                    state.baseSafety![base]!.sourceEventIDs.append(input.event.eventID)
                }
                for sibling in state.config.variants!.values where sibling.baseMovementID == base {
                    state.exercises[sibling.id]!.mode = .paused
                    resetExactComparisons(&state.exercises[sibling.id]!)
                }
                exercise.mode = .paused
                resetExactComparisons(&exercise)
                action = .pause; rule = "X01"; key = "movement_paused"
            } else if before.mode == .paused || state.baseSafety![base]!.paused {
                rule = "X01"; key = "paused_preserved"
            } else if before.exactRepState!.setupReviewRequired {
                rule = "X06"; key = "setup_review_required"
            } else if input.event.sessionMode == .easier {
                // Temporary easier work cannot acquire capacity, strain or clock credit.
                if log.status != .skipped && !log.actualSets.isEmpty && log.mixedLoads == false &&
                    classified.confirmedLoad && !classified.sameLoad {
                    exercise.load = log.actualLoad
                    seedExactBaseline(&exercise)
                }
                rule = "X09"; key = "easier_session_recorded"
            } else if !before.interruptedReturn && before.exactRepState!.lastSuitableNormalDate.map({
                $0.days(until: input.event.date) >= parameters.interruptionDays
            }) == true {
                // Unprepared overdue work cannot establish new load/capacity. Raw
                // actuals remain in the command; dose the retained normal setup.
                try beginExactInterruptedReturn(&exercise, movement: movement, rules: input.rules)
                action = .recover; rule = "X08"; key = "interruption_return"
            } else if log.status == .skipped {
                key = "skip_recorded"
            } else {
                if let previous = exercise.recentComparable.last?.exactRepContext,
                   !sameExactContext(previous, context) { resetExactComparisons(&exercise) }
                if log.mixedLoads == false && !log.actualSets.isEmpty && classified.confirmedLoad && !classified.sameLoad {
                    exercise.load = log.actualLoad
                    seedExactBaseline(&exercise)
                    if before.interruptedReturn && classified.cleanKnown && !classified.conflicting &&
                        !classified.aboveCeiling && log.finalEffort != .tooHard {
                        exercise.exactRepState!.lastSuitableNormalDate = nil
                    }
                    action = .baseline; key = "actual_load_changed"
                } else if !classified.cleanKnown || !classified.sameLoad {
                    resetExactComparisons(&exercise)
                    if classified.aboveCeiling { notice = "rep_ceiling_exceeded" }
                } else if before.interruptedReturn {
                    resetExactComparisons(&exercise)
                    rule = "X08"; key = "return_observation_held"
                    if !classified.conflicting && !classified.aboveCeiling && log.finalEffort != .tooHard {
                        seedExactBaseline(&exercise)
                        // Expired capacity stays in immutable history, not in the
                        // active clock. Return work never invents normal evidence.
                        exercise.exactRepState!.lastSuitableNormalDate = nil
                        action = .baseline; key = "return_baseline_restored"
                    }
                } else if classified.conflicting {
                    resetExactComparisons(&exercise)
                    notice = "observation_conflict"
                } else if classified.strain {
                    rule = "X06"
                    exercise.ceilingStreak = 0
                    exercise.exactRepState!.shortfallStreak = 0
                    if exercise.strainStreak + 1 >= parameters.setbackCount {
                        if let lower = lowerExactLoad(movement: movement, current: exercise.load) {
                            exercise.load = lower
                            seedExactBaseline(&exercise)
                            action = .reduceLoad; key = "strain_reduce_load"
                        } else {
                            exercise.strainStreak = 0
                            exercise.exactRepState!.setupReviewRequired = true
                            key = "setup_review_required"
                            append = true
                        }
                    } else {
                        exercise.strainStreak += 1
                        key = "first_set_floor_hold"
                        if log.finalEffort == .tooHard {
                            let plan = try exactPlan(classified, exercise: exercise, goal: state.config.goal, effort: log.finalEffort)
                            exercise.exactRepState!.normalTargets = plan.targets
                            key = "strain_reduce_targets"
                        }
                        append = true
                    }
                } else if classified.aboveCeiling {
                    resetExactComparisons(&exercise)
                    notice = "rep_ceiling_exceeded"
                } else {
                    exercise.strainStreak = 0
                    if before.mode == .baseline {
                        let plan = try exactPlan(classified, exercise: exercise, goal: state.config.goal, effort: log.finalEffort)
                        exercise.exactRepState!.normalTargets = plan.targets
                        exercise.exactRepState!.shortfallStreak = 0
                        exercise.ceilingStreak = 0
                        exercise.mode = .normal
                        action = .baseline; rule = "X03"; key = "baseline_fitted"
                        append = true; suitable = true
                    } else {
                        append = true; suitable = true
                        let ceiling = classified.goalsMet && !classified.overshoot &&
                            classified.actual.allSatisfy { $0 == exercise.repCeiling } &&
                            (state.config.goal != .maintenance || log.finalEffort == .tooEasy)
                        if ceiling {
                            exercise.exactRepState!.shortfallStreak = 0
                            rule = "X05"; key = "ceiling_confirmation"
                            if exercise.ceilingStreak + 1 < parameters.confirmationCount {
                                exercise.ceilingStreak += 1
                            } else if let higher = try permittedHigherExactLoad(movement: movement, current: exercise.load) {
                                exercise.load = higher
                                seedExactBaseline(&exercise)
                                action = .increaseLoad; key = "load_increased"; append = false
                            } else {
                                exercise.ceilingStreak = 0
                                let maximum = state.config.goal == .strength && movement.lowRepLoadingAllowed ?
                                    parameters.maximumStrengthRepCeiling : parameters.maximumRepCeiling
                                if movement.automaticRepRangeExtensionAllowed && exercise.repCeiling < maximum {
                                    exercise.repCeiling = min(maximum, exercise.repCeiling + parameters.repCeilingExtension)
                                    resetExactComparisons(&exercise)
                                    let plan = try exactPlan(classified, exercise: exercise, goal: state.config.goal, effort: log.finalEffort)
                                    exercise.exactRepState!.normalTargets = plan.targets
                                    action = .extendRepCeiling; key = "rep_ceiling_extended"; append = false
                                } else {
                                    key = "equipment_limit_hold"; notice = "equipment_limit"
                                }
                            }
                        } else {
                            exercise.ceilingStreak = 0
                            let plan = try exactPlan(classified, exercise: exercise, goal: state.config.goal, effort: log.finalEffort)
                            exercise.exactRepState!.normalTargets = plan.targets
                            exercise.exactRepState!.shortfallStreak = plan.shortfallStreak
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
                let observation = exactObservation(event: input.event, log: log, prescription: prescription,
                                                   movement: movement, context: context)
                exercise.recentComparable = Array((exercise.recentComparable + [observation]).suffix(parameters.plateauExposures))
            }
            state.exercises[id] = exercise
            decisions.append(try exactDecision(id: id, action: action, rule: rule, key: key,
                                               before: before, after: exercise, rules: input.rules))
            if let notice { decisions.append(try exactDecision(id: id, action: .notice, rule: rule, key: notice,
                before: before, after: exercise, rules: input.rules)) }
            if [.size, .strength].contains(state.config.goal), append, action == .hold, notice == nil,
               exactPlateau(exercise.recentComparable, count: parameters.plateauExposures) {
                decisions.append(try exactDecision(id: id, action: .notice, rule: "X11", key: "plateau_check",
                    before: before, after: exercise, rules: input.rules))
            }
        }
        state.revision += 1
        state.lastSessionDate = input.event.date
        state.processedEvents[input.event.eventID] = eventHash
        state.activePrescription = try plannedExactWorkout(state: state, rules: input.rules,
            slot: WorkoutSlot(date: input.nextWorkoutDate, slotID: input.nextSlotID))
        try validateExactRepContract(state: state, rules: input.rules)
        return .applied(nextState: state, nextWorkout: state.activePrescription, decisions: decisions)
    } catch let error as EngineError { return .rejected(nextState: input.state, errors: [error.code]) }
    catch { return .rejected(nextState: input.state, errors: ["invalid_numeric_value"]) }
}

private func validateExactAdvance(_ input: AdvanceInput) throws -> WorkoutPrescription {
    let planned = try prepareExactWorkout(state: input.state, rules: input.rules, easierToday: false)
    let event = input.event
    try validateCompletionDates(input)
    try WorkoutScheduler.validate(slot: WorkoutSlot(date: input.nextWorkoutDate, slotID: input.nextSlotID), config: input.state.config, schedulingPolicy: input.state.schedulingPolicy)
    let displayed = try prepareExactWorkout(state: input.state, rules: input.rules, easierToday: event.sessionMode == .easier)
    guard event.slotID == planned.slotID, event.plannedPrescriptionID == planned.id,
          event.prescriptionID == displayed.id else { throw EngineError(code: "stale_prescription", field: "prescriptionId") }
    let ids = event.exercises.map(\.movementID)
    guard ids.count == Set(ids).count, Set(ids) == Set(displayed.exercises.map(\.movementID)) else {
        throw EngineError(code: "invalid_rows", field: "exercises")
    }
    for log in event.exercises {
        let prescription = displayed.exercises.first { $0.movementID == log.movementID }!
        guard log.prescriptionID == displayed.id else { throw EngineError(code: "stale_prescription", field: "exercises.prescriptionId") }
        try validateIndexedExactLog(log, prescription: prescription)
        let movement = input.state.config.movements.first { $0.id == prescription.baseMovementID }!
        if let load = log.actualLoad {
            guard movement.loadingMode == .externalLoad, movement.availableLoads.contains(load) else {
                throw EngineError(code: "unavailable_load", field: "actualLoad")
            }
        }
    }
    return displayed
}

private func exactPlan(_ classified: ExactExposureClassification, exercise: ExerciseState, goal: Goal,
                       effort: Effort) throws -> ExactRepPlanningResult {
    try ExactRepPlanner.plan(ExactRepPlanningInput(prescribed: classified.priorTargets,
        actual: classified.actual, ceiling: exercise.repCeiling, goal: goal,
        phase: exercise.mode == .baseline ? .baseline : .normal, effort: effort,
        missReasons: classified.missReasons, shortfallStreak: exercise.exactRepState!.shortfallStreak))
}

func seedExactBaseline(_ exercise: inout ExerciseState, clearSetupReview: Bool = false) {
    exercise.mode = exercise.mode == .paused ? .paused : .baseline
    exercise.exactRepState!.normalTargets = Array(repeating: exercise.repFloor, count: exercise.normalSets)
    if clearSetupReview { exercise.exactRepState!.setupReviewRequired = false }
    resetExactComparisons(&exercise)
    exercise.nextSetOverride = nil
    exercise.interruptedReturn = false
}

func lowerExactLoad(movement: Movement, current: Load?) -> Load? {
    guard let current, let index = movement.availableLoads.firstIndex(of: current), index > 0 else { return nil }
    return movement.availableLoads[index - 1]
}

func permittedHigherExactLoad(movement: Movement, current: Load?) throws -> Load? {
    guard movement.automaticLoadProgressionAllowed, let current,
          let index = movement.availableLoads.firstIndex(of: current), index + 1 < movement.availableLoads.count else { return nil }
    let candidate = movement.availableLoads[index + 1]
    return try ExactLoad(canonicalAmount: current.amount).allowsIncrease(to: ExactLoad(canonicalAmount: candidate.amount)) ? candidate : nil
}

func beginExactInterruptedReturn(_ exercise: inout ExerciseState, movement: Movement, rules: Ruleset) throws {
    if let current = exercise.load {
        // Checked cross multiplication keeps decimal equality exact, with no Double.
        func scaled(_ amount: String, _ factor: Int) throws -> Decimal {
            _ = try ExactLoad(canonicalAmount: amount)
            var lhs = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))!
            var rhs = Decimal(factor); var result = Decimal()
            guard NSDecimalMultiply(&result, &lhs, &rhs, .plain) == .noError else {
                throw EngineError(code: "invalid_numeric_value", field: "returnLoad")
            }
            return result
        }
        let percent = try rules.resolvedParameters.exactRep!.returnMaximumLoadPercent
        let limit = try scaled(current.amount, percent)
        let eligible = try movement.availableLoads.filter { try scaled($0.amount, 100) <= limit }
        if let lower = eligible.last { exercise.load = lower }
    }
    resetExactComparisons(&exercise)
    exercise.nextSetOverride = max(1, exercise.normalSets - 1)
    exercise.interruptedReturn = true
}

func exactDecision(id: String, action: DecisionAction, rule: String, key: String,
                   before: ExerciseState, after: ExerciseState, rules: Ruleset) throws -> Decision {
    guard let archived = rules.rules?.first(where: { $0.id == rule }),
          case .object(let b) = try exactCanonical(before), case .object(let a) = try exactCanonical(after) else {
        throw EngineError(code: "invalid_exact_transition", field: "decisions")
    }
    return Decision(movementID: id, action: action, ruleIDs: [rule], sourceIDs: archived.sourceIDs.sorted(),
        evidenceClass: archived.evidenceClass, explanationKey: key, before: b, after: a)
}

private func exactPlateau(_ exposures: [Exposure], count: Int) -> Bool {
    guard exposures.count == count, exposures.allSatisfy({ $0.phase == .normal && $0.sessionMode == .normal &&
        $0.effort == .onTarget && $0.problem == .none }),
        let first = exposures.first?.exactRepContext,
        exposures.allSatisfy({ $0.exactRepContext.map { sameExactContext(first, $0) } == true }) else { return false }
    let totals = exposures.map { $0.actualSets.reduce(0) { $0 + $1.reps } }
    let half = count / 2
    return totals.suffix(half).sorted()[half / 2] <= totals.prefix(half).sorted()[half / 2]
}

func exactCanonical(_ value: some Encodable) throws -> CanonicalValue {
    try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
}
private func exactCanonicalHash(_ value: some Encodable) throws -> String { try CanonicalJSON.sha256(exactCanonical(value)) }

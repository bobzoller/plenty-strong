import Foundation

public func prepareWorkout(state: ProgramState, rules: Ruleset, easierToday: Bool = false) throws -> WorkoutPrescription {
    try rules.validateIntegrity()
    guard state.rulesetVersion == rules.version, state.rulesetHash == rules.hash else {
        throw EngineError(code: "ruleset_mismatch", field: "rules")
    }
    let app = rules.version == "general-fitness-swift1"
    guard state.schemaVersion == (app ? 2 : 1) else {
        throw EngineError(code: "invalid_schema", field: "schemaVersion")
    }
    try validate(config: state.config, rules: rules)
    let planned = state.activePrescription
    if app { try WorkoutScheduler.validate(slot: WorkoutSlot(date: planned.date, slotID: planned.slotID), config: state.config) }
    guard planned.id == (try CanonicalJSON.sha256(prescriptionContent(planned))),
          let slot = state.config.weeklySlots.first(where: { $0.id == planned.slotID }) else {
        throw EngineError(code: "stale_prescription", field: "activePrescription")
    }
    let expectedIDs = try slot.movementIDs.map { base -> String in
        if !app { return base }
        guard let id = state.config.activeVariantIDs?[base] else {
            throw EngineError(code: "invalid_variant", field: "activeVariantIds.\(base)")
        }
        return id
    }
    guard planned.exercises.map(\.movementID) == expectedIDs else {
        throw EngineError(code: "invalid_prescription", field: "activePrescription.exercises")
    }
    if app {
        guard let variants = state.config.variants, Set(state.exercises.keys) == Set(variants.keys),
              let safety = state.baseSafety, Set(safety.keys) == Set(state.config.movements.map(\.id)),
              state.exercises.values.allSatisfy({ ($0.setupRevision ?? 0) > 0 }) else {
            throw EngineError(code: "invalid_state", field: "variants")
        }
    }
    let preset = try rules.preset(goal: state.config.goal, daysPerWeek: state.config.daysPerWeek)
    let parameters = try rules.resolvedParameters
    var result = planned
    for index in planned.exercises.indices {
        let prescription = planned.exercises[index]
        let id = prescription.movementID
        let base = app ? state.config.variants?[id]?.baseMovementID : id
        guard let base, let movement = state.config.movements.first(where: { $0.id == base }),
              let exercise = state.exercises[id] else {
            throw EngineError(code: "invalid_state", field: "exercises.\(id)")
        }
        let shared = state.baseSafety?[base]
        if app {
            guard prescription.baseMovementID == base,
                  prescription.modificationsSnapshot == state.config.variants?[id]?.modifications,
                  let shared, shared.minimumRir >= movement.minimumRir else {
                throw EngineError(code: "invalid_snapshot", field: "activePrescription.exercises.\(id)")
            }
        }
        let paused = prescription.kind == .paused || exercise.mode == .paused || shared?.paused == true
        if paused {
            guard prescription.kind == .paused, prescription.sets.isEmpty else {
                throw EngineError(code: "invalid_prescription", field: "activePrescription.exercises.\(id).sets")
            }
            continue
        }
        guard !prescription.sets.isEmpty, prescription.sets.allSatisfy({ $0.repFloor >= 0 && $0.repCeiling >= $0.repFloor }) else {
            throw EngineError(code: "invalid_prescription", field: "activePrescription.exercises.\(id).sets")
        }
        if app {
            let normalMinimum = max(parameters.normalMinimumRir, max(movement.minimumRir, shared!.minimumRir))
            let instruction = effortInstruction(minimumRir: normalMinimum, parameters: parameters)
            guard prescription.sets.allSatisfy({ $0.effortInstruction == instruction }) else {
                throw EngineError(code: "invalid_snapshot", field: "activePrescription.exercises.\(id).effortInstruction")
            }
        }
        guard easierToday else { continue }
        let range = initialRepRange(movement: movement, goal: state.config.goal, preset: preset)
        let count = min(prescription.sets.count, max(1, (preset.normalSets + 1) / 2))
        let minimumRir = max(parameters.easierMinimumRir, max(movement.minimumRir, shared?.minimumRir ?? movement.minimumRir))
        result.exercises[index].phase = .easier
        result.exercises[index].sets = prescription.sets.prefix(count).map {
            SetPrescription(repFloor: 0, repCeiling: min($0.repCeiling, range.floor),
                effortInstruction: effortInstruction(minimumRir: minimumRir, parameters: parameters))
        }
    }
    if !easierToday { return planned }
    result.id = try CanonicalJSON.sha256(.object([
        "plannedPrescriptionId": .string(planned.id), "sessionMode": .string("easier"),
        "rulesetVersion": .string(rules.version), "rulesetHash": .string(rules.hash),
        "prescription": try prescriptionContent(result)
    ]))
    return result
}

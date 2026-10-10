import Foundation

/// Append-only boundary: old observations remain final-set observations. The
/// selected source dates carry only interruption-clock evidence, never capacity.
public func activateProgramPolicy(state: ProgramState, sourceRules: Ruleset, destinationRules: Ruleset,
                                  legacyHistory: [JournalEnvelope], nextWorkout: WorkoutSlot) throws -> ConfigurationResult {
    try validateConfigurationInput(state: state, rules: sourceRules, slot: nextWorkout)
    if try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: sourceRules) == .fixedExactV1,
       sourceRules == destinationRules { return unchangedConfiguration(state) }
    guard try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: sourceRules) == .fixedCeilingsV1,
          try ProgramPolicy.resolve(schemaVersion: 3, rules: destinationRules) == .fixedExactV1 else {
        throw EngineError(code: "unsupported_policy_activation", field: "rules")
    }
    let evidence = try activationEvidence(state: state, history: legacyHistory)
    var updated = state
    updated.schemaVersion = 3
    updated.rulesetVersion = destinationRules.version
    updated.rulesetHash = destinationRules.hash
    for id in updated.exercises.keys.sorted() {
        let before = updated.exercises[id]!
        updated.exercises[id]!.exactRepState = ExactRepState(
            normalTargets: Array(repeating: before.repFloor, count: before.normalSets), shortfallStreak: 0,
            lastSuitableNormalDate: evidence[id]?.date, setupReviewRequired: false)
        seedExactBaseline(&updated.exercises[id]!)
        // Archived activation keeps its pending-date preparation. Flexible
        // activation waits for the caller's explicit actual-date return command.
        if state.schedulingPolicy == nil {
            _ = try markInterruptedReturn(state: &updated, id: id, asOf: nextWorkout.date, rules: destinationRules)
        }
    }
    return try finishConfiguration(original: state, updated: updated, rules: destinationRules, slot: nextWorkout, decisions: [])
}

public func policyActivationEvidenceEventIDs(state: ProgramState, history: [JournalEnvelope]) throws -> [String] {
    Array(Set(try activationEvidence(state: state, history: history).values.map(\.id))).sorted()
}

/// Admission compares saved raw descriptions byte for byte; Swift String
/// equality alone can equate different Unicode encodings of an observation.
public func rawVariantSnapshotsMatch(state: ProgramState, event: CompletedWorkout) -> Bool {
    guard [2, 3, 4].contains(state.schemaVersion) else { return true }
    return event.exercises.allSatisfy { log in
        log.baseMovementID == state.config.variants?[log.movementID]?.baseMovementID &&
        log.modificationsSnapshot != nil && log.modificationsSnapshot!.utf8.elementsEqual(
            state.config.variants?[log.movementID]?.modifications.utf8 ?? "".utf8)
    }
}

private struct ActivationEvidence { var id: String; var date: LocalDate }
private func activationEvidence(state: ProgramState, history: [JournalEnvelope]) throws -> [String: ActivationEvidence] {
    let rules = try RulesetCatalog.resolve(version: state.rulesetVersion, hash: state.rulesetHash)
    guard try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules) == .fixedCeilingsV1 else {
        throw EngineError(code: "unsupported_policy_activation", field: "state")
    }
    try validateConfigurationState(state: state, rules: rules)
    if history.isEmpty {
        // Pure callers may supply the pristine initializer without an envelope.
        let root = try initializeProgram(config: state.config, rules: rules,
            firstWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID))
        guard try activationBytes(root.state) == activationBytes(state) else { throw activationInvalid("missing_history") }
        return [:]
    }
    let verified = try verifiedActivationPrefix(state: state, history: history, rules: rules)
    let heads = verified.values.filter { (try? activationBytes($0.returnedState) == activationBytes(state)) == true }
    guard heads.count == 1, let head = heads.first else { throw activationInvalid("source_head") }
    guard try activationAncestors(head.envelopeHash, verified: verified) == Set(verified.keys) else { throw activationInvalid("foreign_history") }
    var path: [JournalEnvelope] = [], cursor: JournalEnvelope? = head
    while let envelope = cursor {
        path.append(envelope)
        cursor = envelope.parentEnvelopeHash.flatMap { verified[$0] }
    }
    var evidence: [String: ActivationEvidence] = [:]
    for envelope in path.reversed() {
        guard case let .workout(event, _) = envelope.command, event.sessionMode == .normal,
              let parentHash = envelope.parentEnvelopeHash, let parent = verified[parentHash] else { continue }
        let displayed = try prepareWorkout(state: parent.returnedState, rules: rules)
        for log in event.exercises {
            guard let current = state.exercises[log.movementID],
                  let original = parent.returnedState.exercises[log.movementID],
                  let variant = state.config.variants?[log.movementID],
                  let movement = state.config.movements.first(where: { $0.id == variant.baseMovementID }),
                  parent.returnedState.config.variants?[log.movementID]?.baseMovementID == variant.baseMovementID,
                  parent.returnedState.config.variants?[log.movementID]?.modifications.utf8.elementsEqual(variant.modifications.utf8) == true,
                  current.setupRevision == original.setupRevision,
                  let row = displayed.exercises.first(where: { $0.movementID == log.movementID }),
                  (row.phase == .normal || row.phase == .baseline), row.kind != .paused,
                  row.kind != .setupReview, log.status == .completed, log.problem == .none,
                  log.finalEffort != .unknown, log.finalEffort != .tooHard,
                  log.actualSets.count == row.sets.count, !log.actualSets.isEmpty,
                  log.actualSets.allSatisfy({ actual in
                      actual.reps > 0 && (movement.repCounting != .perSide ||
                          (actual.leftReps == actual.reps && actual.rightReps == actual.reps)) &&
                      ((actual.leftReps == nil && actual.rightReps == nil) ||
                          (actual.leftReps == actual.reps && actual.rightReps == actual.reps))
                  }), log.mixedLoads != true,
                  log.actualLoad == current.load,
                  (movement.loadingMode == .externalLoad ?
                    (log.actualLoad != nil && movement.availableLoads.contains(log.actualLoad!)) : log.actualLoad == nil),
                  (row.phase == .baseline || row.load == log.actualLoad),
                  log.prescriptionID == displayed.id,
                  event.prescriptionID == displayed.id, event.plannedPrescriptionID == displayed.id,
                  envelope.returnedState.exercises[log.movementID]?.mode == .normal else { continue }
            evidence[log.movementID] = ActivationEvidence(id: event.eventID, date: event.date)
        }
    }
    return evidence
}

private func activationBytes(_ value: some Encodable) throws -> Data {
    try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)))
}
private func activationHash(_ value: some Encodable) throws -> String {
    try CanonicalJSON.sha256(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)))
}
private func activationInvalid(_ field: String) -> EngineError { EngineError(code: "invalid_activation_evidence", field: field) }

/// Recompute supplied ancestors. A checksum alone cannot grant an old completion
/// the right to seed the new interruption clock. Portable adapters additionally
/// verify the archived resources and conflict-resolution original wrappers.
private func verifiedActivationPrefix(state: ProgramState, history: [JournalEnvelope], rules: Ruleset) throws -> [String: JournalEnvelope] {
    guard Set(history.map(\.envelopeHash)).count == history.count else { throw activationInvalid("duplicate_history") }
    var verified: [String: JournalEnvelope] = [:]
    var remaining = history
    while !remaining.isEmpty {
        var progressed = false
        for envelope in remaining {
            guard envelope.parentEnvelopeHash == nil || verified[envelope.parentEnvelopeHash!] != nil else { continue }
            if case let .resolveConflict(_, heads, _, _) = envelope.command, !heads.allSatisfy({ verified[$0] != nil }) { continue }
            guard !envelope.datasetID.isEmpty, !envelope.eventID.isEmpty,
                  envelope.schemaVersion == 2, envelope.returnedState.schemaVersion == 2,
                  envelope.programID == state.config.programID,
                  envelope.rulesetHash == rules.hash, envelope.rulesetVersion == rules.version,
                  envelope.returnedState.config.programID == state.config.programID,
                  envelope.returnedState.rulesetHash == rules.hash,
                  envelope.profileID == envelope.returnedState.config.profileID,
                  envelope.profileHash == envelope.returnedState.config.profileHash,
                  envelope.sourceProfileID == envelope.returnedState.config.sourceProfileID,
                  envelope.sourceProfileHash == envelope.returnedState.config.sourceProfileHash else { throw activationInvalid("identity") }
            guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: activationBytes(envelope)) else { throw activationInvalid("envelope") }
            fields.removeValue(forKey: "envelopeHash")
            let eventHash: String
            if case let .workout(event, _) = envelope.command {
                guard event.eventID == envelope.eventID else { throw activationInvalid("event_identity") }
                eventHash = try activationHash(event)
            }
            else { eventHash = try activationHash(envelope.command) }
            guard try CanonicalJSON.sha256(.object(fields)) == envelope.envelopeHash,
                  eventHash == envelope.eventHash else { throw activationInvalid("hash") }
            let result: ConfigurationResult
            if case let .initialize(config, first) = envelope.command {
                guard envelope.parentEnvelopeHash == nil, envelope.inputStateHash == nil,
                      envelope.inputRevision == -1 else { throw activationInvalid("root") }
                let root = try initializeProgram(config: config, rules: rules, firstWorkout: first)
                result = ConfigurationResult(state: root.state, workout: root.workout, decisions: [])
            } else {
                guard let parent = envelope.parentEnvelopeHash.flatMap({ verified[$0] }),
                      parent.datasetID == envelope.datasetID,
                      envelope.inputRevision == parent.returnedState.revision,
                      try envelope.inputStateHash == activationHash(parent.returnedState) else { throw activationInvalid("parent") }
                if case let .resolveConflict(selection, _, _, _) = envelope.command {
                    guard selection.selectedHeadHash == parent.envelopeHash else { throw activationInvalid("resolution_parent") }
                }
                result = try activationLegacyTransition(state: parent.returnedState, command: envelope.command, rules: rules, verified: verified)
                guard result.state.revision == parent.returnedState.revision + 1 else { throw activationInvalid("revision") }
            }
            guard try activationBytes(result.state) == activationBytes(envelope.returnedState),
                  try activationBytes(result.workout) == activationBytes(envelope.returnedPrescription),
                  try activationBytes(result.decisions) == activationBytes(envelope.decisions) else { throw activationInvalid("replay") }
            verified[envelope.envelopeHash] = envelope
            progressed = true
        }
        remaining.removeAll { verified[$0.envelopeHash] != nil }
        guard progressed else { throw activationInvalid("missing_parent") }
    }
    return verified
}

private func activationAncestors(_ head: String, verified: [String: JournalEnvelope]) throws -> Set<String> {
    var found: Set<String> = [], pending = [head]
    while let hash = pending.popLast() {
        guard found.insert(hash).inserted else { continue }
        guard let envelope = verified[hash] else { throw activationInvalid("missing_parent") }
        if let parent = envelope.parentEnvelopeHash { pending.append(parent) }
        if case let .resolveConflict(_, heads, _, _) = envelope.command { pending += heads }
    }
    return found
}
private func activationLegacyTransition(state: ProgramState, command: JournalCommand, rules: Ruleset,
                                        verified: [String: JournalEnvelope]) throws -> ConfigurationResult {
    switch command {
    case let .workout(event, next):
        guard rawVariantSnapshotsMatch(state: state, event: event) else { throw activationInvalid("raw_snapshot") }
        switch advanceProgram(AdvanceInput(state: state, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)) {
        case let .applied(state, workout, decisions): return ConfigurationResult(state: state, workout: workout, decisions: decisions)
        default: throw activationInvalid("workout")
        }
    case let .reconfigure(change, next): return try reconfigureProgram(state: state, change: change, rules: rules, nextWorkout: next)
    case let .variantChange(change, next): return try changeMovementVariant(state: state, change: change, rules: rules, nextWorkout: next)
    case let .reschedule(slot): return try reschedulePendingWorkout(state: state, slot: slot, rules: rules)
    case let .interruption(date): return try prepareInterruptedReturn(state: state, asOf: date, rules: rules)
    case let .resolveConflict(selection, heads, _, next):
        let paths = try heads.map { try activationAncestors($0, verified: verified) }
        guard let first = paths.first else { throw activationInvalid("resolution") }
        let common = paths.dropFirst().reduce(first) { $0.intersection($1) }
        guard let ancestor = common.compactMap({ verified[$0] }).sorted(by: { ($0.returnedState.revision, $0.envelopeHash) > ($1.returnedState.revision, $1.envelopeHash) }).first else { throw activationInvalid("resolution") }
        let branches = zip(heads, paths).map { head, path in
            VerifiedBranch(headHash: head, state: verified[head]!.returnedState,
                commands: path.subtracting(common).compactMap { verified[$0] }.sorted {
                    ($0.returnedState.revision, $0.envelopeHash) < ($1.returnedState.revision, $1.envelopeHash)
                }.map(\.command))
        }
        let result = try resolveCloudBranches(BranchResolutionInput(commonAncestor: ancestor.returnedState,
            competingHeadHashes: heads, branches: branches, selection: selection, rules: rules, next: next))
        return ConfigurationResult(state: result.state, workout: result.workout, decisions: result.decisions)
    case .activateFlexibleScheduling: return try activateFlexibleScheduling(state: state, rules: rules)
    case .initialize, .activatePolicy, .changeStarterProgram: throw activationInvalid("command")
    }
}

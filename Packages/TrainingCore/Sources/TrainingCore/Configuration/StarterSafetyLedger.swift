import Foundation

/// Explicit safety aliases are conservative continuity rules, never load equivalence.
public func starterSafetyFamily(for base: String) -> String {
    switch base {
    case "incline_db_press_24", "incline_db_press_30": "incline_press"
    case "chest_supported_db_row_38_neutral", "chest_supported_db_row_30_neutral": "supported_row"
    case "suitcase_db_squat": "squat"
    case "db_romanian_deadlift": "rdl"
    case "bulgarian_split_squat", "supported_static_split_squat": "split_squat"
    case "lying_db_curls", "cross_body_hammer_curl", "standing_db_curl": "dumbbell_curl"
    case "banded_pullups", "banded_chinups": "pull_up"
    default: base
    }
}

func unionStarterSafety(_ first: MovementSafetyState?, _ second: MovementSafetyState) -> MovementSafetyState {
    guard let first else { return second }
    return MovementSafetyState(paused: first.paused || second.paused,
        minimumRir: max(first.minimumRir, second.minimumRir),
        sourceEventIDs: Array(Set(first.sourceEventIDs + second.sourceEventIDs)).sorted())
}

private func currentStarterSafety(_ state: ProgramState) -> [String: MovementSafetyState] {
    var ledger = state.retainedSafety ?? [:]
    for movement in state.config.movements {
        let family = starterSafetyFamily(for: movement.id)
        var restriction = state.baseSafety?[movement.id] ?? MovementSafetyState(paused: false,
            minimumRir: movement.minimumRir, sourceEventIDs: [])
        restriction.minimumRir = max(restriction.minimumRir, movement.minimumRir)
        if state.config.variants?.values.contains(where: {
            $0.baseMovementID == movement.id && state.exercises[$0.id]?.mode == .paused
        }) == true { restriction.paused = true }
        ledger[family] = unionStarterSafety(ledger[family], restriction)
    }
    return ledger
}

/// Ancestry is fully replayed against pinned archives by the adapter before entry.
/// This supplied-value guard also rejects foreign/omitted parents, changed terminal
/// states and invented safety source IDs. It performs no archive or catalog IO.
func starterVerifiedPath(state: ProgramState, history: [JournalEnvelope]) throws -> [JournalEnvelope] {
    func reject(_ field: String) throws -> Never { throw EngineError(code: "invalid_starter_history", field: field) }
    func value(_ value: some Encodable) throws -> CanonicalValue {
        try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
    }
    guard !history.isEmpty else {
        var defaults: [String: MovementSafetyState] = [:]
        for movement in state.config.movements {
            let restriction = MovementSafetyState(paused: false, minimumRir: movement.minimumRir, sourceEventIDs: [])
            defaults[starterSafetyFamily(for: movement.id)] = unionStarterSafety(defaults[starterSafetyFamily(for: movement.id)], restriction)
            guard state.baseSafety?[movement.id] == restriction else { try reject("missing_history") }
        }
        guard state.revision == 0, state.lastSessionDate == nil, state.processedEvents.isEmpty,
              state.retainedSafety == nil || state.retainedSafety == defaults else { try reject("missing_history") }
        return []
    }
    guard Set(history.map(\.envelopeHash)).count == history.count else { try reject("duplicates") }
    let indexed = Dictionary(uniqueKeysWithValues: history.map { ($0.envelopeHash, $0) })
    for envelope in history {
        guard envelope.programID == state.config.programID, envelope.returnedState.config.programID == state.config.programID,
              [2, 3, 4].contains(envelope.schemaVersion), envelope.returnedState.schemaVersion == envelope.schemaVersion,
              envelope.rulesetHash == envelope.returnedState.rulesetHash,
              envelope.rulesetVersion == envelope.returnedState.rulesetVersion,
              envelope.profileID == envelope.returnedState.config.profileID,
              envelope.profileHash == envelope.returnedState.config.profileHash,
              envelope.sourceProfileID == envelope.returnedState.config.sourceProfileID,
              envelope.sourceProfileHash == envelope.returnedState.config.sourceProfileHash else { try reject("identity") }
        guard case .object(var fields) = try value(envelope) else { try reject("envelope") }
        fields.removeValue(forKey: "envelopeHash")
        let eventValue: CanonicalValue
        if case let .workout(event, _) = envelope.command {
            guard event.eventID == envelope.eventID else { try reject("event_identity") }
            eventValue = try value(event)
        } else { eventValue = try value(envelope.command) }
        guard try CanonicalJSON.sha256(.object(fields)) == envelope.envelopeHash,
              try CanonicalJSON.sha256(eventValue) == envelope.eventHash else { try reject("hash") }
        if let parentHash = envelope.parentEnvelopeHash {
            guard let parent = indexed[parentHash], parent.datasetID == envelope.datasetID,
                  envelope.inputRevision == parent.returnedState.revision,
                  parent.returnedState.revision >= 0, parent.returnedState.revision < Int.max,
                  envelope.returnedState.revision == parent.returnedState.revision + 1,
                  try envelope.inputStateHash == CanonicalJSON.sha256(value(parent.returnedState)) else { try reject("parent") }
            if envelope.schemaVersion == 4 {
                let previous = currentStarterSafety(parent.returnedState)
                guard let next = envelope.returnedState.retainedSafety,
                      Set(next.keys).isSubset(of: Set(previous.keys).union(envelope.returnedState.config.movements.map { starterSafetyFamily(for: $0.id) })) else {
                    try reject("retained_families")
                }
                var clearedFamily: String?
                if case let .reconfigure(.safeResume(base, true), _) = envelope.command { clearedFamily = starterSafetyFamily(for: base) }
                for (family, restriction) in previous {
                    guard let retained = next[family], retained.minimumRir >= restriction.minimumRir,
                          !restriction.paused || retained.paused || clearedFamily == family,
                          Set(restriction.sourceEventIDs).isSubset(of: Set(retained.sourceEventIDs)) else {
                        try reject("retained_safety")
                    }
                }
            }
        } else {
            guard case .initialize = envelope.command, envelope.inputRevision == -1,
                  envelope.inputStateHash == nil, envelope.returnedState.revision == 0 else { try reject("root") }
            if envelope.schemaVersion == 4 {
                var defaults: [String: MovementSafetyState] = [:]
                for movement in envelope.returnedState.config.movements {
                    let restriction = MovementSafetyState(paused: false, minimumRir: movement.minimumRir, sourceEventIDs: [])
                    let family = starterSafetyFamily(for: movement.id)
                    defaults[family] = unionStarterSafety(defaults[family], restriction)
                }
                guard envelope.returnedState.retainedSafety == defaults else { try reject("root_safety") }
            }
        }
    }
    let stateBytes = try CanonicalJSON.encode(value(state))
    let heads = try history.filter { try CanonicalJSON.encode(value($0.returnedState)) == stateBytes }
    guard heads.count == 1, let head = heads.first else { try reject("terminal_state") }
    var seen = Set<String>(), pending = [head.envelopeHash]
    while let hash = pending.popLast() {
        guard seen.insert(hash).inserted else { continue }
        guard let envelope = indexed[hash] else { try reject("dependency") }
        if let parent = envelope.parentEnvelopeHash { pending.append(parent) }
        if case let .resolveConflict(_, heads, _, _) = envelope.command { pending += heads }
    }
    guard seen == Set(indexed.keys) else { try reject("foreign_history") }
    let events = Set(history.compactMap { envelope -> String? in
        if case let .workout(event, _) = envelope.command { return event.eventID }; return nil
    })
    guard (state.retainedSafety ?? [:]).values.allSatisfy({ Set($0.sourceEventIDs).isSubset(of: events) }),
          (state.baseSafety ?? [:]).values.allSatisfy({ Set($0.sourceEventIDs).isSubset(of: events) }) else { try reject("safety_sources") }
    var path: [JournalEnvelope] = [], cursor: JournalEnvelope? = head
    while let envelope = cursor {
        path.append(envelope)
        cursor = envelope.parentEnvelopeHash.flatMap { indexed[$0] }
    }
    return path.reversed()
}

public func retainedStarterSafety(state: ProgramState, verifiedHistory: [JournalEnvelope],
                                  destinationRules: Ruleset) throws -> [String: MovementSafetyState] {
    _ = try starterVerifiedPath(state: state, history: verifiedHistory)
    try destinationRules.validateIntegrity()
    guard try ProgramPolicy.resolve(schemaVersion: 4, rules: destinationRules).usesStarterDoses else {
        throw EngineError(code: "unsupported_version", field: "destinationRules")
    }
    // Current replayed restrictions already incorporate typed clearances. OR-ing
    // every historical pause would incorrectly undo an explicit safe resume.
    return currentStarterSafety(state)
}

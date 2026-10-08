import Foundation
import Testing
@testable import TrainingCore

@Suite struct ExactPolicyActivationTests {
    @Test func activationKeepsLegacyMeaning() throws {
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        let old = try initializeProgram(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: slot)
        let result = try activateProgramPolicy(state: old.state, sourceRules: RulesetCatalog.fixedV1(),
            destinationRules: RulesetCatalog.exactV1(), legacyHistory: [], nextWorkout: slot)
        #expect(result.state.schemaVersion == 3)
        #expect(result.state.config == old.state.config)
        #expect(result.state.processedEvents == old.state.processedEvents)
        #expect(result.state.lastSessionDate == old.state.lastSessionDate)
        #expect(result.workout.exercises.first?.sets.compactMap(\.targetReps) == [8,8,8])
        #expect(old.workout.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps == nil } })
        #expect(result.state.exercises.values.allSatisfy { $0.recentComparable.isEmpty && $0.mode == .baseline })
        let noOp = try activateProgramPolicy(state: result.state, sourceRules: RulesetCatalog.exactV1(),
            destinationRules: RulesetCatalog.exactV1(), legacyHistory: [], nextWorkout: slot)
        #expect(noOp.state == result.state)
    }
    @Test func activationRejectsUnverifiedHistoryAndWrongSource() throws {
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        let old = try initializeProgram(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: slot)
        var changed = old.state; changed.revision = 1
        #expect(throws: (any Error).self) {
            try policyActivationEvidenceEventIDs(state: changed, history: [])
        }
        #expect(throws: (any Error).self) {
            try activateProgramPolicy(state: old.state, sourceRules: RulesetCatalog.exactV1(),
                destinationRules: RulesetCatalog.exactV1(), legacyHistory: [], nextWorkout: slot)
        }
    }
}

extension ExactPolicyActivationTests {
    @Test func pureActivationRejectsByteDifferentLegacySnapshot() throws {
        let rules = try RulesetCatalog.fixedV1()
        var config = try selectFixedProgram(goal: .size, programID: UUID())
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        let base = try #require(config.weeklySlots.first { $0.id == slot.slotID }!.movementIDs.first { id in
            config.movements.first { $0.id == id }!.loadingMode != .externalLoad
        })
        let target = "unicode-custom"
        config.variants![target] = MovementVariant(id: target, baseMovementID: base, modifications: "caf\u{e9}")
        config.activeVariantIDs![base] = target
        let root = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
        let rootEnvelope = try activationTestEnvelope(command: .initialize(config: config, firstWorkout: slot),
            result: ConfigurationResult(state: root.state, workout: root.workout, decisions: []), rules: rules)
        let input = try appEvent(state: root.state, rules: rules, target: target)
        guard case let .applied(state, workout, decisions) = advanceProgram(input) else { throw EngineError(code: "fixture", field: "workout") }
        let next = WorkoutSlot(date: input.nextWorkoutDate, slotID: input.nextSlotID)
        let result = ConfigurationResult(state: state, workout: workout, decisions: decisions)
        let valid = try activationTestEnvelope(command: .workout(completedWorkout: input.event, next: next), result: result, rules: rules, parent: rootEnvelope)
        #expect(try policyActivationEvidenceEventIDs(state: state, history: [rootEnvelope, valid]) == [input.event.eventID])
        var event = input.event
        let row = event.exercises.firstIndex { $0.movementID == target }!
        event.exercises[row].modificationsSnapshot = "cafe\u{301}"
        #expect(event.exercises[row].modificationsSnapshot == input.event.exercises[row].modificationsSnapshot)
        #expect(!event.exercises[row].modificationsSnapshot!.utf8.elementsEqual(input.event.exercises[row].modificationsSnapshot!.utf8))
        var equivalentInput = input; equivalentInput.event = event
        guard case let .applied(equivalentState, equivalentWorkout, equivalentDecisions) = advanceProgram(equivalentInput) else { throw EngineError(code: "fixture", field: "equivalent_workout") }
        let forged = try activationTestEnvelope(command: .workout(completedWorkout: event, next: next),
            result: ConfigurationResult(state: equivalentState, workout: equivalentWorkout, decisions: equivalentDecisions), rules: rules, parent: rootEnvelope)
        #expect(throws: (any Error).self) { try policyActivationEvidenceEventIDs(state: equivalentState, history: [rootEnvelope, forged]) }
        #expect(throws: (any Error).self) { try activateProgramPolicy(state: equivalentState, sourceRules: rules,
            destinationRules: RulesetCatalog.exactV1(), legacyHistory: [rootEnvelope, forged], nextWorkout: next) }
    }
    @Test func activationPreservesConfirmedLoadAndSafetyAndRejectsOtherDestinations() throws {
        var config = try selectFixedProgram(goal: .strength, programID: UUID())
        for movement in config.movements { config.initialLoads[movement.id] = .some(movement.availableLoads.first) }
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        let legacy = try initializeProgram(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: slot)
        let result = try activateProgramPolicy(state: legacy.state, sourceRules: RulesetCatalog.fixedV1(),
            destinationRules: RulesetCatalog.exactV1(), legacyHistory: [], nextWorkout: slot)
        #expect(result.state.baseSafety == legacy.state.baseSafety)
        #expect(result.state.exercises.allSatisfy { id, value in
            value.load == legacy.state.exercises[id]?.load && value.setupRevision == legacy.state.exercises[id]?.setupRevision &&
            value.exactRepState?.normalTargets == Array(repeating: value.repFloor, count: value.normalSets) &&
            value.exactRepState?.lastSuitableNormalDate == nil
        })
        #expect(throws: (any Error).self) {
            try activateProgramPolicy(state: legacy.state, sourceRules: RulesetCatalog.fixedV1(),
                destinationRules: RulesetCatalog.fixedV1(), legacyHistory: [], nextWorkout: slot)
        }
    }
    @Test func activationCommandHasDistinctWireKeys() throws {
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        let command = JournalCommand.activatePolicy(sourceRulesetHash: RulesetCatalog.fixedRulesetHash,
            destinationRulesetHash: RulesetCatalog.exactRulesetHash, normalEvidenceEventIDs: ["a", "b"], next: slot)
        let encoded = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(JournalCommand.self, from: encoded) == command)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["kind"] as? String == "activatePolicy")
        #expect(Set(json.keys) == ["kind", "sourceRulesetHash", "destinationRulesetHash", "normalEvidenceEventIDs", "next"])
        #expect(json["sourceRulesetHash"] as? String == RulesetCatalog.fixedRulesetHash)
    }
}

private func activationTestEnvelope(command: JournalCommand, result: ConfigurationResult, rules: Ruleset,
                                    parent: JournalEnvelope? = nil) throws -> JournalEnvelope {
    func hash(_ value: some Encodable) throws -> String {
        try CanonicalJSON.sha256(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)))
    }
    let config = result.state.config
    let eventID: String, eventHash: String
    if case let .workout(event, _) = command { eventID = event.eventID; eventHash = try hash(event) }
    else { eventID = "activation-test-root"; eventHash = try hash(command) }
    var envelope = JournalEnvelope(schemaVersion: 2, datasetID: UUID().uuidString.lowercased(), programID: config.programID,
        eventID: eventID, eventHash: eventHash, parentEnvelopeHash: parent?.envelopeHash,
        inputRevision: parent?.returnedState.revision ?? -1, inputStateHash: try parent.map { try hash($0.returnedState) },
        rulesetVersion: rules.version, rulesetHash: rules.hash, profileID: config.profileID!, profileHash: config.profileHash!,
        sourceProfileID: config.sourceProfileID!, sourceProfileHash: config.sourceProfileHash!, command: command,
        returnedState: result.state, returnedPrescription: result.workout, decisions: result.decisions, envelopeHash: "")
    if let parent { envelope.datasetID = parent.datasetID }
    guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(envelope)) else { throw EngineError(code: "fixture", field: "envelope") }
    fields.removeValue(forKey: "envelopeHash"); envelope.envelopeHash = try CanonicalJSON.sha256(.object(fields))
    return envelope
}

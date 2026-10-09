import Foundation
import Testing
@testable import TrainingCore

@Suite struct StarterProgramSwitchTests {
    @Test func switchPreservesIdentityAndRestartsDestinationDose() throws {
        let state = try starterState(choice: .upperBody)
        let result = try changeStarterProgram(state: state, sourceRules: starterRules(state),
            destinationRules: RulesetCatalog.starter(.wholeBodyGlutes),
            destinationDefinition: StarterProgramCatalog.definition(.wholeBodyGlutes),
            choice: .wholeBodyGlutes, goal: .size, verifiedHistory: [],
            nextWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: "SUN"))
        #expect(result.state.config.programID == state.config.programID)
        #expect(result.state.revision == 1)
        #expect(result.state.processedEvents == state.processedEvents)
        #expect(result.state.exercises.values.allSatisfy { $0.normalSets == 2 && $0.starterState!.windows.isEmpty })
        #expect(result.state.exercises.values.allSatisfy { $0.mode == .baseline && $0.ceilingStreak == 0 && $0.recentComparable.isEmpty })
        #expect(throws: (any Error).self) {
            try changeStarterProgram(state: state, sourceRules: starterRules(state),
                destinationRules: RulesetCatalog.starter(.wholeBodyGlutes),
                destinationDefinition: StarterProgramCatalog.definition(.upperBody),
                choice: .wholeBodyGlutes, goal: .size, verifiedHistory: [],
                nextWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: "SUN"))
        }
    }
    @Test func unverifiedModifiedStateCannotSupplyRemovedSafetyOrLoad() throws {
        var state = try starterState(choice: .upperBody)
        state.retainedSafety!["invented"] = MovementSafetyState(paused: true, minimumRir: 4, sourceEventIDs: ["missing"])
        #expect(throws: (any Error).self) {
            try retainedStarterSafety(state: state, verifiedHistory: [], destinationRules: RulesetCatalog.starter(.wholeBodyGlutes))
        }
    }
    @Test func commandRoundTripUsesExplicitChoiceGoalAndSlot() throws {
        let command = JournalCommand.changeStarterProgram(choice: .wholeBodyGlutes, goal: .strength,
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        #expect(try JSONDecoder().decode(JournalCommand.self, from: JSONEncoder().encode(command)) == command)
    }
}

private func switchEnvelope(state: ProgramState, command: JournalCommand, parent: JournalEnvelope?) throws -> JournalEnvelope {
    func value(_ value: some Encodable) throws -> CanonicalValue { try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)) }
    let id: String
    let hash: String
    if case let .workout(event, _) = command { id = event.eventID; hash = try CanonicalJSON.sha256(value(event)) }
    else { id = "configuration-\(state.revision)"; hash = try CanonicalJSON.sha256(value(command)) }
    var envelope = JournalEnvelope(schemaVersion: state.schemaVersion, datasetID: "synthetic-switch-dataset", programID: state.config.programID,
        eventID: id, eventHash: hash, parentEnvelopeHash: parent?.envelopeHash,
        inputRevision: parent?.returnedState.revision ?? -1, inputStateHash: try parent.map { try CanonicalJSON.sha256(value($0.returnedState)) },
        rulesetVersion: state.rulesetVersion, rulesetHash: state.rulesetHash, profileID: state.config.profileID!, profileHash: state.config.profileHash!,
        sourceProfileID: state.config.sourceProfileID!, sourceProfileHash: state.config.sourceProfileHash!, command: command,
        returnedState: state, returnedPrescription: state.activePrescription, decisions: [], envelopeHash: "")
    guard case .object(var fields) = try value(envelope) else { throw EngineError(code: "fixture", field: "envelope") }
    fields.removeValue(forKey: "envelopeHash")
    envelope.envelopeHash = try CanonicalJSON.sha256(.object(fields))
    return envelope
}
private func verifiedSwitchFixture() throws -> (ProgramState, [JournalEnvelope]) {
    let root = try starterState()
    let rootEnvelope = try switchEnvelope(state: root, command: .initialize(config: root.config,
        firstWorkout: WorkoutSlot(date: root.activePrescription.date, slotID: "SUN")), parent: nil)
    var event = try starterCompletion(state: root, actualsByBase: Dictionary(uniqueKeysWithValues: root.activePrescription.exercises.map {
        ($0.baseMovementID!, $0.sets.map { $0.targetReps! })
    }))
    for index in event.exercises.indices {
        let movement = root.config.movements.first { $0.id == event.exercises[index].baseMovementID }!
        if movement.loadingMode == .externalLoad { event.exercises[index].actualLoad = movement.availableLoads.first }
    }
    let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE")
    let state = try starterApplied(AdvanceInput(state: root, event: event, rules: starterRules(root), nextSlotID: "TUE", nextWorkoutDate: next.date))
    return (state, [rootEnvelope, try switchEnvelope(state: state, command: .workout(completedWorkout: event, next: next), parent: rootEnvelope)])
}
extension StarterProgramSwitchTests {
    @Test func compatibleVerifiedLoadSurvivesWithoutComparisonTransfer() throws {
        let (state, history) = try verifiedSwitchFixture()
        let rules = try RulesetCatalog.starter(.upperBody)
        let result = try changeStarterProgram(state: state, sourceRules: starterRules(state), destinationRules: rules,
            destinationDefinition: StarterProgramCatalog.definition(.upperBody), choice: .upperBody, goal: .size,
            verifiedHistory: history, nextWorkout: WorkoutSlot(date: state.activePrescription.date, slotID: "TUE"))
        let id = state.config.activeVariantIDs!["db_romanian_deadlift"]!
        #expect(result.state.exercises[id]?.load == state.exercises[id]?.load)
        #expect(result.state.exercises[id]?.setupRevision == state.exercises[id]?.setupRevision)
        #expect(result.state.exercises[id]?.lastCompletedDate == state.exercises[id]?.lastCompletedDate)
        #expect(result.state.exercises[id]?.starterState?.windows.isEmpty == true)
        #expect(result.state.exercises[id]?.exactRepState?.lastSuitableNormalDate == nil)
        #expect(result.state.exercises.values.allSatisfy { $0.recentComparable.isEmpty && $0.ceilingStreak == 0 && $0.strainStreak == 0 })
        #expect(result.state.exercises[result.state.config.activeVariantIDs!["incline_db_press_24"]!]?.load == nil)
        #expect(result.state.processedEvents == state.processedEvents && result.state.lastSessionDate == state.lastSessionDate)
    }
    @Test func ancestryMustIncludeParentsAndExactHeadAndRealSafetySources() throws {
        let (state, history) = try verifiedSwitchFixture()
        let destination = try RulesetCatalog.starter(.upperBody)
        #expect(throws: (any Error).self) { try retainedStarterSafety(state: state, verifiedHistory: Array(history.dropFirst()), destinationRules: destination) }
        var modified = state
        modified.retainedSafety!["pull_up"] = MovementSafetyState(paused: true, minimumRir: 4, sourceEventIDs: ["foreign"])
        #expect(throws: (any Error).self) { try retainedStarterSafety(state: modified, verifiedHistory: history, destinationRules: destination) }
        var forged = history
        forged[1] = try switchEnvelope(state: modified, command: history[1].command, parent: history[0])
        #expect(throws: (any Error).self) { try retainedStarterSafety(state: modified, verifiedHistory: forged, destinationRules: destination) }
        #expect(throws: (any Error).self) {
            try changeStarterProgram(state: state, sourceRules: starterRules(state), destinationRules: destination,
                destinationDefinition: StarterProgramCatalog.definition(.upperBody), choice: .upperBody, goal: .size,
                verifiedHistory: history, nextWorkout: WorkoutSlot(date: state.lastSessionDate!, slotID: "SUN"))
        }
    }
    @Test func selfConsistentHashesCannotDropAnAbsentFamilyRestriction() throws {
        let root = try starterState(choice: .upperBody)
        let rootEnvelope = try switchEnvelope(state: root, command: .initialize(config: root.config,
            firstWorkout: WorkoutSlot(date: root.activePrescription.date, slotID: "SUN")), parent: nil)
        let slot = WorkoutSlot(date: root.activePrescription.date, slotID: "SUN")
        let reserved = try reconfigureProgram(state: root, change: .minimumRir(baseMovementID: "banded_pullups", value: 4),
            rules: starterRules(root), nextWorkout: slot).state
        let reserveEnvelope = try switchEnvelope(state: reserved,
            command: .reconfigure(change: .minimumRir(baseMovementID: "banded_pullups", value: 4), next: slot), parent: rootEnvelope)
        var switched = try changeStarterProgram(state: reserved, sourceRules: starterRules(reserved),
            destinationRules: RulesetCatalog.starter(.wholeBodyGlutes), destinationDefinition: StarterProgramCatalog.definition(.wholeBodyGlutes),
            choice: .wholeBodyGlutes, goal: .size, verifiedHistory: [rootEnvelope, reserveEnvelope], nextWorkout: slot).state
        switched.retainedSafety!.removeValue(forKey: "pull_up")
        let forged = try switchEnvelope(state: switched, command: .changeStarterProgram(choice: .wholeBodyGlutes, goal: .size, next: slot), parent: reserveEnvelope)
        #expect(throws: (any Error).self) {
            try retainedStarterSafety(state: switched, verifiedHistory: [rootEnvelope, reserveEnvelope, forged], destinationRules: RulesetCatalog.starter(.upperBody))
        }
    }
    @Test func malformedOverflowingParentRevisionRejectsWithoutArithmeticTrap() throws {
        let root = try starterState()
        var invalid = root; invalid.revision = Int.max
        let parent = try switchEnvelope(state: invalid, command: .initialize(config: root.config,
            firstWorkout: WorkoutSlot(date: root.activePrescription.date, slotID: "SUN")), parent: nil)
        let child = try switchEnvelope(state: root,
            command: .reschedule(slot: WorkoutSlot(date: root.activePrescription.date, slotID: "SUN")), parent: parent)
        #expect(throws: (any Error).self) {
            try retainedStarterSafety(state: root, verifiedHistory: [child, parent], destinationRules: starterRules(root))
        }
    }
    @Test func samePolicyBranchResolutionRetainsAbsentFamilies() throws {
        let state = try starterState()
        var first = state, second = state
        first.retainedSafety!["pull_up"] = MovementSafetyState(paused: true, minimumRir: 4, sourceEventIDs: ["synthetic-pain"])
        second.retainedSafety!["pull_up"] = MovementSafetyState(paused: false, minimumRir: 5, sourceEventIDs: [])
        let rules = try starterRules(state)
        let result = try resolveCloudBranches(BranchResolutionInput(commonAncestor: state, competingHeadHashes: ["first", "second"],
            branches: [VerifiedBranch(headHash: "first", state: first, commands: []), VerifiedBranch(headHash: "second", state: second, commands: [])],
            selection: BranchSelection(selectedHeadHash: "first"), rules: rules,
            next: WorkoutSlot(date: state.activePrescription.date, slotID: "SUN")))
        #expect(result.state.retainedSafety?["pull_up"] == MovementSafetyState(paused: true, minimumRir: 5, sourceEventIDs: ["synthetic-pain"]))
        #expect(result.state.exercises.values.allSatisfy { $0.normalSets == 2 && $0.starterState!.windows.isEmpty })
    }
}

extension StarterProgramSwitchTests {
    @Test func samePolicyResolutionHonorsClearedPainInsteadOfReplayingEveryPastPause() throws {
        let state = try starterState()
        let rules = try starterRules(state)
        let slot = WorkoutSlot(date: state.activePrescription.date, slotID: "SUN")
        var cleared = state
        let restriction = MovementSafetyState(paused: false, minimumRir: 2, sourceEventIDs: ["cleared-pain"])
        cleared.retainedSafety!["incline_press"] = restriction
        cleared.baseSafety!["incline_db_press_30"] = restriction
        var pain = try starterCompletion(state: state, actualsByBase: [:], problemsByBase: ["incline_db_press_30": .pain])
        pain.eventID = "cleared-pain"
        let resolution = try resolveCloudBranches(BranchResolutionInput(commonAncestor: state, competingHeadHashes: ["cleared", "other"],
            branches: [VerifiedBranch(headHash: "cleared", state: cleared, commands: [.workout(completedWorkout: pain, next: slot),
                .reconfigure(change: .safeResume(baseMovementID: "incline_db_press_30", externalClearanceConfirmed: true), next: slot)]),
                VerifiedBranch(headHash: "other", state: state, commands: [])],
            selection: BranchSelection(selectedHeadHash: "cleared"), rules: rules, next: slot))
        #expect(resolution.state.retainedSafety?["incline_press"]?.paused == false)
        #expect(resolution.state.retainedSafety?["incline_press"]?.sourceEventIDs == ["cleared-pain"])
    }
}

extension StarterProgramSwitchTests {
    @Test func canonicalEquivalentDescriptionsCannotImpersonateExactVerifiedHead() throws {
        let (state, history) = try verifiedSwitchFixture()
        let id = "synthetic-unicode-variant"
        let slot = WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID)
        let change = VariantChange.create(baseMovementID: "db_romanian_deadlift", variantID: id, modifications: "Cafe\u{301}")
        let changed = try changeMovementVariant(state: state, change: change, rules: starterRules(state), nextWorkout: slot).state
        let envelope = try switchEnvelope(state: changed, command: .variantChange(change: change, next: slot), parent: history.last)
        var altered = changed
        altered.config.variants![id]!.modifications = "Caf\u{e9}"
        #expect(throws: (any Error).self) {
            try retainedStarterSafety(state: altered, verifiedHistory: history + [envelope], destinationRules: RulesetCatalog.starter(.upperBody))
        }
    }
}

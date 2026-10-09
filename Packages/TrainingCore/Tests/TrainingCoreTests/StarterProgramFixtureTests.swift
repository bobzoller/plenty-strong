import Foundation
import Testing
@testable import TrainingCore

/// Full frozen results authored from the Trainer/design contract, never engine output.
struct StarterExpectedAdvance: Decodable {
    let nextState: ProgramState
    let nextWorkout: WorkoutPrescription
    let decisions: [Decision]
}

enum StarterProgramFixtureCompiler {
    private struct Document: Decodable { let cases: [String: Row]; let switchExample: SwitchExample }
    private struct Row: Decodable {
        let input: AdvanceInput
        let expected: StarterExpectedAdvance
    }
    struct SwitchExample: Decodable {
        let source: ProgramState
        let expected: StarterExpectedConfiguration
    }
    struct StarterExpectedConfiguration: Decodable {
        let state: ProgramState
        let workout: WorkoutPrescription
        let decisions: [Decision]
    }
    private static func document() throws -> Document {
        guard let url = Bundle.module.url(forResource: "starter-program-examples", withExtension: "json") else {
            throw EngineError(code: "missing_fixture_resource", field: "starter-program-examples.json")
        }
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }
    private static func row(_ id: String) throws -> Row {
        guard let row = try document().cases[id] else { throw EngineError(code: "missing_fixture", field: id) }
        return row
    }
    static func input(_ id: String) throws -> AdvanceInput { try row(id).input }
    static func expected(_ id: String) throws -> StarterExpectedAdvance { try row(id).expected }
    static func switchExample() throws -> SwitchExample { try document().switchExample }
}

@Suite struct StarterProgramFixtureTests {
    private func check(_ id: String) throws -> StarterExpectedAdvance {
        let input = try StarterProgramFixtureCompiler.input(id)
        let original = input
        let expected = try StarterProgramFixtureCompiler.expected(id)
        let result = advanceProgram(input)
        guard case let .applied(state, workout, decisions) = result else {
            Issue.record("Expected authored applied result for \(id): \(result)"); return expected
        }
        #expect(state == expected.nextState, "Full next state: \(id)")
        #expect(workout == expected.nextWorkout, "Full prescription: \(id)")
        #expect(decisions == expected.decisions, "Full decisions: \(id)")
        #expect(input == original)
        return expected
    }

    @Test func trainerEstablishedWeekMatchesSavedPrescriptions() throws {
        let sun = try check("trainer-sun")
        let tueInput = try StarterProgramFixtureCompiler.input("trainer-tue")
        #expect(sun.nextState == tueInput.state)
        let tue = try check("trainer-tue")
        let thuInput = try StarterProgramFixtureCompiler.input("trainer-thu")
        #expect(tue.nextState == thuInput.state)
        _ = try check("trainer-thu")
        // Exact consultation row order, paired/single/null loads and per-side meaning
        // are all frozen in the full input prescriptions and result JSON.
        let sunInput = try StarterProgramFixtureCompiler.input("trainer-sun")
        #expect(sunInput.state.activePrescription.exercises.map { $0.sets.compactMap(\.targetReps) } ==
            [[10,10,9], [10,10,9], [11,10,10], [12,11], [12,12], [8,8]])
        #expect(tueInput.state.activePrescription.exercises.map { $0.sets.compactMap(\.targetReps) } ==
            [[10,10], [12,12], [11,11,10], [10,10], [13,12], [10,10]])
        #expect(thuInput.state.activePrescription.exercises.map { $0.sets.compactMap(\.targetReps) } ==
            [[10,10,9], [10,10,10], [10,10,10], [11,11,11], [11,10], [9,8]])
    }

    @Test func rdlWorkedExampleSeparatesPreviousGoalActualAndNext() throws {
        let input = try StarterProgramFixtureCompiler.input("rdl-about-right")
        let expected = try check("rdl-about-right")
        let id = try #require(input.state.config.activeVariantIDs?["db_romanian_deadlift"])
        let prior = try #require(input.state.exercises[id]?.starterState?.windows.values.first?.exposures.last)
        #expect(prior.actualSets.map(\.reps) == [10,10,8])
        #expect(input.state.activePrescription.exercises[0].sets.compactMap(\.targetReps) == [10,10,9])
        #expect(input.event.exercises[0].actualSets.map(\.reps) == [10,10,9])
        #expect(expected.nextState.exercises[id]?.exactRepState?.normalTargets == [10,10,10])
        let missed = try check("rdl-first-miss")
        #expect(missed.nextState.exercises[id]?.exactRepState?.normalTargets == [10,10,10])
        let easy = try check("rdl-too-easy")
        #expect(easy.nextState.exercises[id]?.exactRepState?.normalTargets == [12,12,11])
    }

    @Test func introductoryPromotionPreservesActualsAndThirdSetBaseline() throws {
        for id in ["intro-midrange", "intro-ceiling"] { _ = try check(id) }
        let input = try StarterProgramFixtureCompiler.input("intro-midrange")
        let expected = try StarterProgramFixtureCompiler.expected("intro-midrange")
        let id = try #require(input.state.config.activeVariantIDs?["db_romanian_deadlift"])
        #expect(input.event.exercises[0].actualSets.map(\.reps) == [10,9])
        #expect(expected.nextState.exercises[id]?.exactRepState?.normalTargets == [10,9,8])
    }

    @Test func ceilingAndStrainEvidenceRemainLocalToFrozenContext() throws {
        for id in ["ceiling-other-slot", "ceiling-current-slot", "strain-other-slot", "strain-current-slot"] {
            _ = try check(id)
        }
    }

    @Test func bodyweightBridgeAndStrongerRetainedSafetyMatchFullResults() throws {
        _ = try check("bodyweight-bridge")
        _ = try check("retained-stronger-safety")
    }

    @Test func switchAndReplayPreserveExactAuthoredResults() throws {
        let fixture = try StarterProgramFixtureCompiler.switchExample()
        let destination = try RulesetCatalog.starter(.wholeBodyGlutes)
        let actual = try changeStarterProgram(state: fixture.source, sourceRules: RulesetCatalog.starter(.upperBody),
            destinationRules: destination, destinationDefinition: StarterProgramCatalog.definition(.wholeBodyGlutes),
            choice: .wholeBodyGlutes, goal: .size, verifiedHistory: [],
            nextWorkout: WorkoutSlot(date: fixture.expected.workout.date, slotID: fixture.expected.workout.slotID))
        #expect(actual.state == fixture.expected.state)
        #expect(actual.workout == fixture.expected.workout)
        #expect(actual.decisions == fixture.expected.decisions)
        let input = try StarterProgramFixtureCompiler.input("switch-advance")
        #expect(actual.state == input.state)
        let expected = try check("switch-advance")
        var replay = input
        replay.state = expected.nextState
        #expect(advanceProgram(replay) == .noOp(nextState: expected.nextState, reason: .eventReplayed))
        replay.event.exercises[0].finalEffort = .tooEasy
        #expect(advanceProgram(replay) == .rejected(nextState: expected.nextState, errors: ["event_id_conflict"]))
    }

    @Test func unavailableFuturePolicyRejectsWithoutMutation() throws {
        var input = try StarterProgramFixtureCompiler.input("rdl-about-right")
        input.state.schemaVersion = 5
        #expect(advanceProgram(input) == .rejected(nextState: input.state, errors: ["unsupported_policy"]))
        input = try StarterProgramFixtureCompiler.input("rdl-about-right")
        input.rules.version = "general-fitness-glute-exact-future"
        #expect(advanceProgram(input) == .rejected(nextState: input.state, errors: ["invalid_ruleset"]))
    }
}

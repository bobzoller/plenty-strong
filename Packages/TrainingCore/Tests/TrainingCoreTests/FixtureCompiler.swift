import Foundation
@testable import TrainingCore

/// Expands independent source cases without invoking the production engine.
enum FixtureCompiler {
    static let prepareCaseIDs = ["C17", "C41", "C46", "C47"]
    static let advanceCaseIDs = (1...47).map { String(format: "C%02d", $0) }.filter { !prepareCaseIDs.contains($0) }

    private struct Goldens: Decodable { var cases: [String: Golden] }
    private struct Golden: Decodable {
        var kind: String
        var action: DecisionAction?
        var explanationKey: String?
        var exercisePatch: CanonicalValue?
        var window: String?
        var ruleIds: [String]
        var errors: [String]?
        var notices: [Notice]?
    }
    private struct Notice: Decodable { var ruleIds: [String]; var explanationKey: String }

    /// Syntactic expansion only: every transition choice comes from the authored
    /// JSON record. No production classifier, recovery, or progression helper runs.
    static func expectedAdvanceResult(caseID: String) throws -> AdvanceResult {
        let input = try advanceInput(caseID: caseID)
        let url = Bundle.module.url(forResource: "complete-expected-results", withExtension: "json")!
        let golden = try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url)).cases[caseID]!
        if golden.kind == "rejected" { return .rejected(nextState: input.state, errors: golden.errors!) }
        if golden.kind == "no_op" { return .noOp(nextState: input.state, reason: .eventReplayed) }
        let id = "example_lift"
        let before = input.state.exercises[id]!
        var exercise = try decode(ExerciseState.self, merge(canonical(before), golden.exercisePatch!))
        if input.event.exercises[0].status == .completed { exercise.lastCompletedDate = input.event.date }
        switch golden.window! {
        case "clear": exercise.recentComparable = []
        case "append":
            let displayed = input.state.activePrescription.exercises[0]
            let log = input.event.exercises[0]
            exercise.recentComparable = Array((before.recentComparable + [Exposure(eventID: input.event.eventID,
                date: input.event.date, load: log.actualLoad, plannedSetCount: displayed.sets.count,
                repFloor: displayed.sets[0].repFloor, repCeiling: displayed.sets[0].repCeiling,
                actualSets: log.actualSets, effort: log.finalEffort, problem: log.problem,
                sessionMode: input.event.sessionMode, phase: displayed.phase)]).suffix(6))
        case "preserve": break
        default: throw EngineError(code: "invalid_golden", field: caseID)
        }
        var state = input.state
        state.exercises[id] = exercise
        state.revision += 1
        state.lastSessionDate = input.event.date
        state.processedEvents[input.event.eventID] = try CanonicalJSON.sha256(canonical(input.event))
        let workout = try expectedWorkout(state: state, date: input.nextWorkoutDate, slotID: input.nextSlotID)
        state.activePrescription = workout
        var decisions = [try expectedDecision(id: id, action: golden.action!, rules: golden.ruleIds,
            key: golden.explanationKey!, before: before, after: exercise)]
        for notice in golden.notices ?? [] {
            decisions.append(try expectedDecision(id: id, action: .notice, rules: notice.ruleIds,
                key: notice.explanationKey, before: before, after: exercise))
        }
        return .applied(nextState: state, nextWorkout: workout, decisions: decisions)
    }

    static func expectedDecision(id: String, action: DecisionAction, rules: [String], key: String,
                                 before: ExerciseState, after: ExerciseState) throws -> Decision {
        let evidence = ["R03": ["E12"], "R06": ["E01", "E07"], "R07": ["E07"],
            "R10": ["E01", "E05"], "R11": ["E03"], "R12": ["E10"], "R13": ["E02", "E03"], "R14": ["E05", "E11"]]
        guard case .object(let b) = try canonical(before), case .object(let a) = try canonical(after) else { fatalError() }
        return Decision(movementID: id, action: action, ruleIDs: rules,
            sourceIDs: Array(Set(rules.flatMap { evidence[$0] ?? [] })).sorted(),
            evidenceClass: .appAdaptation, explanationKey: key, before: b, after: a)
    }

    /// Builds the explicit target dose from already-authored expected state values.
    static func expectedWorkout(state: ProgramState, date: LocalDate, slotID: String) throws -> WorkoutPrescription {
        let app = state.schemaVersion == 2
        let strength = state.config.goal == .strength
        let instruction = app ? "Stop when you think you could do two more good reps. Stop earlier for pain or loss of control." :
            "Stop with roughly two good reps left; stop earlier for pain or loss of control."
        var workout = WorkoutPrescription(id: "", date: date, slotID: slotID, exercises: [])
        for base in state.config.weeklySlots.first(where: { $0.id == slotID })!.movementIDs {
            let id = app ? state.config.activeVariantIDs![base]! : base
            let exercise = state.exercises[id]!
            let movement = state.config.movements.first { $0.id == base }!
            let minimum = max(2, max(movement.minimumRir, state.baseSafety?[base]?.minimumRir ?? 0))
            let paused = exercise.mode == .paused || state.baseSafety?[base]?.paused == true
            workout.exercises.append(ExercisePrescription(movementID: id,
                kind: paused ? .paused : (exercise.load == nil && movement.loadingMode == .externalLoad ? .baselineSetup : .working),
                phase: exercise.interruptedReturn || exercise.nextSetOverride != nil ? .returning : (exercise.mode == .baseline ? .baseline : .normal),
                load: exercise.load, sets: paused ? [] : Array(repeating: SetPrescription(repFloor: exercise.repFloor,
                    repCeiling: exercise.repCeiling, effortInstruction: minimum == 2 ? instruction :
                        "Stop with at least \(minimum) good reps left; stop earlier for pain or loss of control."),
                    count: exercise.nextSetOverride ?? exercise.normalSets),
                restSeconds: strength ? 180 : 120, stopInstruction: "Stop for pain or loss of control.",
                baseMovementID: app ? base : nil, modificationsSnapshot: app ? state.config.variants![id]!.modifications : nil))
        }
        workout.id = try CanonicalJSON.sha256(prescriptionContent(workout))
        return workout
    }
    private struct Document: Decodable {
        var baseInput: CanonicalValue
        var cases: [Case]
    }

    private struct Case: Decodable {
        var id: String
        var operation: String
        var inputOverrides: CanonicalValue
        var expected: CanonicalValue
    }

    static func sourceProjection(caseID: String) throws -> CanonicalValue {
        try expanded(caseID: caseID).1.expected
    }

    static func prepareInput(caseID: String) throws -> (ProgramState, Ruleset, Bool) {
        let (fields, fixture) = try expanded(caseID: caseID)
        guard fixture.operation == "prepareWorkout" else {
            throw EngineError(code: "wrong_fixture_operation", field: caseID)
        }
        let input = try decode(AdvanceInput.self, .object(fields))
        return (input.state, input.rules, fields["easierToday"] == .bool(true))
    }

    static func advanceInput(caseID: String) throws -> AdvanceInput {
        let (fields, fixture) = try expanded(caseID: caseID)
        guard fixture.operation == "advanceProgram" else {
            throw EngineError(code: "wrong_fixture_operation", field: caseID)
        }
        return try decode(AdvanceInput.self, .object(fields))
    }

    /// Objects merge recursively; every other value, including arrays/null, replaces.
    static func merge(_ base: CanonicalValue, _ override: CanonicalValue) -> CanonicalValue {
        guard case .object(var fields) = base, case .object(let overrides) = override else { return override }
        for (key, value) in overrides {
            fields[key] = fields[key].map { merge($0, value) } ?? value
        }
        return .object(fields)
    }

    static func canonical(_ value: some Encodable) throws -> CanonicalValue {
        try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
    }

    static func prescriptionContent(_ prescription: WorkoutPrescription) throws -> CanonicalValue {
        guard case .object(var fields) = try canonical(prescription) else { fatalError("Encoded object expected") }
        fields.removeValue(forKey: "id")
        return .object(fields)
    }

    /// Fixture-side implementation of the documented payload, independent of preparer.
    static func expectedEasier(state: ProgramState, rules: Ruleset) throws -> WorkoutPrescription {
        var result = state.activePrescription
        let preset = try rules.preset(goal: state.config.goal, daysPerWeek: state.config.daysPerWeek)
        for index in result.exercises.indices where result.exercises[index].kind != .paused {
            let base = result.exercises[index].baseMovementID ?? result.exercises[index].movementID
            let movement = state.config.movements.first { $0.id == base }!
            let floor = state.config.goal == .strength && !movement.lowRepLoadingAllowed ? 8 : preset.repFloor
            let count = min(result.exercises[index].sets.count, max(1, (preset.normalSets + 1) / 2))
            let minimum = max(4, max(movement.minimumRir, state.baseSafety?[base]?.minimumRir ?? movement.minimumRir))
            result.exercises[index].sets = result.exercises[index].sets.prefix(count).map {
                SetPrescription(repFloor: 0, repCeiling: min($0.repCeiling, floor),
                    effortInstruction: "Stop with at least \(minimum) good reps left; stop earlier for pain or loss of control.")
            }
            result.exercises[index].phase = .easier
        }
        result.id = try CanonicalJSON.sha256(.object([
            "plannedPrescriptionId": .string(state.activePrescription.id),
            "sessionMode": .string("easier"), "rulesetVersion": .string(rules.version),
            "rulesetHash": .string(rules.hash), "prescription": try prescriptionContent(result)
        ]))
        return result
    }

    private static func expanded(caseID: String) throws -> ([String: CanonicalValue], Case) {
        guard let url = Bundle.module.url(forResource: "source-examples", withExtension: "json") else {
            throw EngineError(code: "missing_fixture", field: "source-examples")
        }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard let fixture = document.cases.first(where: { $0.id == caseID }),
              case .object(var fields) = merge(document.baseInput, fixture.inputOverrides) else {
            throw EngineError(code: "unknown_fixture", field: caseID)
        }
        var input = try decode(AdvanceInput.self, .object(fields))
        let originalID = input.state.activePrescription.id
        input.state.activePrescription.id = try CanonicalJSON.sha256(prescriptionContent(input.state.activePrescription))
        // The base event remains referentially valid even in replay cases where the
        // currently active prescription has advanced to a different date/slot.
        var base = try decode(AdvanceInput.self, document.baseInput)
        let baseOriginalID = base.state.activePrescription.id
        base.state.activePrescription.id = try CanonicalJSON.sha256(prescriptionContent(base.state.activePrescription))
        var replacements = [baseOriginalID: base.state.activePrescription.id]
        replacements[originalID] = input.state.activePrescription.id
        normalizeReferences(&input.event, replacements: replacements)
        normalizeReferences(&base.event, replacements: [baseOriginalID: base.state.activePrescription.id])
        if input.event.sessionMode == .easier {
            let displayed = try expectedEasier(state: input.state, rules: input.rules)
            // C44 deliberately has a bad workout reference and a mismatched row.
            if caseID != "C44" { input.event.prescriptionID = displayed.id }
            for index in input.event.exercises.indices { input.event.exercises[index].prescriptionID = displayed.id }
        }
        // Canonicalizing references changes event content too. Preserve the replay
        // relationship to the ORIGINAL event, never the conflicting C21 event.
        if input.state.processedEvents[base.event.eventID] != nil {
            input.state.processedEvents[base.event.eventID] = try CanonicalJSON.sha256(canonical(base.event))
        }
        fields["state"] = try canonical(input.state)
        fields["event"] = try canonical(input.event)
        return (fields, fixture)
    }

    private static func normalizeReferences(_ event: inout CompletedWorkout, replacements: [String: String]) {
        event.plannedPrescriptionID = replacements[event.plannedPrescriptionID] ?? event.plannedPrescriptionID
        event.prescriptionID = replacements[event.prescriptionID] ?? event.prescriptionID
        for index in event.exercises.indices {
            let original = event.exercises[index].prescriptionID
            event.exercises[index].prescriptionID = replacements[original] ?? original
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: CanonicalValue) throws -> T {
        try JSONDecoder().decode(type, from: CanonicalJSON.encode(value))
    }
}

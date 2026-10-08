import Foundation
@testable import TrainingCore

/// Typed operations reflect the actual public boundary in each consultation row.
/// Expected outputs are frozen JSON; this compiler never manufactures expectations.
enum ExactRepFixtureOperation: Equatable {
    case initialize(ProgramConfig, Ruleset, WorkoutSlot)
    case advances([AdvanceInput])
    case prepare(ProgramState, Ruleset, Bool)
    case returnSequence(ProgramState, LocalDate, AdvanceInput)
    case resize(ExerciseState, Int)
}

enum ExactRepFixtureCompiler {
    private struct Row: Decodable, Sendable { var input: Input; var expected: CanonicalValue }
    private struct Input: Decodable, Sendable {
        var kind: String
        var config: ProgramConfig?
        var firstWorkout: WorkoutSlot?
        var steps: [Step]?
        var state: ProgramState?
        var easierToday: Bool?
        var asOf: LocalDate?
        var completion: Step?
        var exercise: ExerciseState?
        var count: Int?
        var selectedMovementId: String?
    }
    private struct Step: Decodable, Sendable {
        var state: ProgramState
        var event: CompletedWorkout
        var nextWorkoutDate: LocalDate
        var nextSlotId: String
        func input() throws -> AdvanceInput {
            AdvanceInput(state: state, event: event, rules: try RulesetCatalog.exactV1(),
                         nextSlotID: nextSlotId, nextWorkoutDate: nextWorkoutDate)
        }
    }
    private static let frozenRows: Result<[String: Row], any Error> = Result {
        guard let url = Bundle.module.url(forResource: "exact-rep-examples", withExtension: "json") else {
            throw EngineError(code: "missing_fixture_resource", field: "exact-rep-examples.json")
        }
        return try JSONDecoder().decode([String: Row].self, from: Data(contentsOf: url))
    }
    private static func row(_ id: String) throws -> Row {
        let rows = try frozenRows.get()
        guard let row = rows[id] else { throw EngineError(code: "missing_fixture", field: id) }
        return row
    }
    static func input(_ id: String) throws -> ExactRepFixtureOperation {
        let fields = try row(id).input
        let rules = try RulesetCatalog.exactV1()
        switch fields.kind {
        case "initialize": return .initialize(fields.config!, rules, fields.firstWorkout!)
        case "advances": return .advances(try fields.steps!.map { try $0.input() })
        case "prepare": return .prepare(fields.state!, rules, fields.easierToday!)
        case "returnSequence": return .returnSequence(fields.state!, fields.asOf!, try fields.completion!.input())
        case "resize": return .resize(fields.exercise!, fields.count!)
        default: throw EngineError(code: "invalid_fixture", field: fields.kind)
        }
    }
    static func expected(_ id: String) throws -> CanonicalValue { try row(id).expected }
    static func selectedMovementID(_ id: String) throws -> String {
        let fields = try row(id).input
        if let first = fields.steps?.first {
            return first.event.exercises.first { $0.status != .skipped }!.movementID
        }
        if let id = fields.selectedMovementId { return id }
        let config = fields.config ?? fields.state!.config
        return config.activeVariantIDs!["incline_db_press_24"]!
    }
    static func canonical(_ value: some Encodable) throws -> CanonicalValue {
        try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
    }
    static func run(_ operation: ExactRepFixtureOperation) throws -> CanonicalValue {
        switch operation {
        case let .initialize(config, rules, slot):
            let result = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
            return .object(["state": try canonical(result.state), "workout": try canonical(result.workout)])
        case let .advances(inputs):
            var previous: ProgramState?
            var results: [CanonicalValue] = []
            for var input in inputs {
                if let previous {
                    // The next frozen input is independently declared and must agree
                    // with the actual preceding public transition in the sequence.
                    guard previous == input.state else { throw EngineError(code: "fixture_sequence_mismatch", field: "state") }
                    input.state = previous
                }
                let result = advanceProgram(input)
                results.append(try canonical(result))
                if case let .applied(state, _, _) = result { previous = state }
            }
            return .array(results)
        case let .prepare(state, rules, easier):
            return .object(["state": try canonical(state), "workout": try canonical(prepareWorkout(state: state, rules: rules, easierToday: easier))])
        case let .returnSequence(state, date, completion):
            let prepared = try prepareInterruptedReturn(state: state, asOf: date, rules: completion.rules)
            guard prepared.state == completion.state else { throw EngineError(code: "fixture_sequence_mismatch", field: "return") }
            var input = completion
            input.state = prepared.state
            return .array([.object(["state": try canonical(prepared.state), "workout": try canonical(prepared.workout), "decisions": try canonical(prepared.decisions)]), try canonical(advanceProgram(input))])
        case let .resize(exercise, count): return try canonical(resizeExactExerciseState(exercise, to: count))
        }
    }
}

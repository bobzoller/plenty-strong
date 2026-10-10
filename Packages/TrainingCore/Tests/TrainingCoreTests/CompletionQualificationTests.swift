import Foundation
import Testing
@testable import TrainingCore

struct CompletionQualificationTests {
    private func fixture() throws -> (ExerciseLog, ExercisePrescription, Movement) {
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let state = try initializeProgram(config: config, rules: RulesetCatalog.fixedV1(),
            firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-04"), slotID: config.weeklySlots[0].id)).state
        let row = state.activePrescription.exercises[0]
        let movement = try #require(config.movements.first { $0.id == row.baseMovementID })
        let log = ExerciseLog(movementID: row.movementID, prescriptionID: state.activePrescription.id,
            status: .partial, actualLoad: movement.availableLoads.first,
            actualSets: row.sets.indices.map { ActualSet(reps: 8, setIndex: $0) },
            finalEffort: .unknown, problem: .none, skippedSetIndices: [], mixedLoads: false)
        return (log, row, movement)
    }

    @Test func occupancyPositiveRepsAndSafetyQualifyWithoutChangingRawInputs() throws {
        let (log, row, movement) = try fixture()
        let bytes = try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(log)))
        #expect(qualifiesCompletedExercise(log, prescription: row, movement: movement, schemaVersion: 3))
        for schema in [3, 4] {
            for invalid in [
                { (l: inout ExerciseLog) in l.actualSets.removeLast() },
                { (l: inout ExerciseLog) in l.actualSets.append(l.actualSets[0]) },
                { (l: inout ExerciseLog) in l.actualSets[0].reps = 0 },
                { (l: inout ExerciseLog) in l.actualSets[0].reps = -1 },
                { (l: inout ExerciseLog) in l.actualSets[0].setIndex = nil },
                { (l: inout ExerciseLog) in l.actualSets[0].setIndex = row.sets.count },
                { (l: inout ExerciseLog) in l.actualSets[1].setIndex = 0 },
                { (l: inout ExerciseLog) in l.skippedSetIndices = [0] },
                { (l: inout ExerciseLog) in l.mixedLoads = true },
                { (l: inout ExerciseLog) in l.problem = .pain }
            ] {
                var bad = log; invalid(&bad)
                #expect(!qualifiesCompletedExercise(bad, prescription: row, movement: movement, schemaVersion: schema))
            }
        }
        var paused = row; paused.kind = .paused
        #expect(!qualifiesCompletedExercise(log, prescription: paused, movement: movement, schemaVersion: 3))
        var empty = row; empty.sets = []
        var noSets = log; noSets.actualSets = []
        #expect(!qualifiesCompletedExercise(noSets, prescription: empty, movement: movement, schemaVersion: 3))
        #expect(try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(log))) == bytes)
    }

    @Test func sidesAndLoadUseExistingQualificationForExactAndLegacy() throws {
        let (original, row, metadata) = try fixture()
        var movement = metadata; movement.repCounting = .perSide
        var log = original
        for index in log.actualSets.indices { log.actualSets[index].leftReps = 8; log.actualSets[index].rightReps = 8 }
        for schema in [2, 3, 4] {
            var valid = log
            if schema == 2 {
                for index in valid.actualSets.indices { valid.actualSets[index].setIndex = nil }
                valid.skippedSetIndices = nil; valid.mixedLoads = nil
            }
            #expect(qualifiesCompletedExercise(valid, prescription: row, movement: movement, schemaVersion: schema))
            for invalid in [
                { (l: inout ExerciseLog) in l.actualSets[0].leftReps = nil },
                { (l: inout ExerciseLog) in l.actualSets[0].rightReps = nil },
                { (l: inout ExerciseLog) in l.actualSets[0].rightReps = 7 },
                { (l: inout ExerciseLog) in l.actualSets[0].reps = 7 },
                { (l: inout ExerciseLog) in l.actualLoad = nil }
            ] {
                var bad = valid; invalid(&bad)
                #expect(!qualifiesCompletedExercise(bad, prescription: row, movement: movement, schemaVersion: schema))
            }
            var bodyweight = movement; bodyweight.loadingMode = .bodyweight
            valid.actualLoad = nil
            #expect(qualifiesCompletedExercise(valid, prescription: row, movement: bodyweight, schemaVersion: schema))
        }
        var legacy = original
        for index in legacy.actualSets.indices { legacy.actualSets[index].setIndex = nil }
        legacy.skippedSetIndices = nil; legacy.mixedLoads = nil
        #expect(qualifiesCompletedExercise(legacy, prescription: row, movement: metadata, schemaVersion: 2))
        legacy.actualSets.append(ActualSet(reps: 8))
        #expect(!qualifiesCompletedExercise(legacy, prescription: row, movement: metadata, schemaVersion: 2))
    }
}

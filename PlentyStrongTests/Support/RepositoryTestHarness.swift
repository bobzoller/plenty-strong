import Foundation
import TrainingCore
@testable import PlentyStrong
struct RepositoryScenario {
    let repository: TrainingRepository
    let storeURL: URL
    let programID: UUID
    let initialRevision: Int
    let firstEvent: CompletedWorkout
    let next: WorkoutSlot
}
enum RepositoryTestHarness {
    static func make(goal: Goal) async throws -> RepositoryScenario {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("training.store")
        let repository = try TrainingRepository.open(at: url)
        let id = UUID()
        var config = try selectFixedProgram(goal: goal, programID: id)
        for movement in config.movements { config.initialLoads[movement.id] = .some(movement.availableLoads.first) }
        let first = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: config.weeklySlots[0].id)
        let initial = try await repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        let p = initial.state.activePrescription
        let logs = p.exercises.map { row -> ExerciseLog in
            let movement = config.movements.first { $0.id == row.baseMovementID }!
            return ExerciseLog(movementID: row.movementID, prescriptionID: p.id, status: .completed,
                actualLoad: row.load, actualSets: row.sets.map { _ in ActualSet(reps: 10,
                leftReps: movement.repCounting == .perSide ? 10 : nil, rightReps: movement.repCounting == .perSide ? 10 : nil) },
                finalEffort: .onTarget, problem: .none, baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot)
        }
        return RepositoryScenario(repository: repository, storeURL: url, programID: id, initialRevision: initial.state.revision,
            firstEvent: CompletedWorkout(eventID: UUID().uuidString, date: p.date, slotID: p.slotID, prescriptionID: p.id,
                plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs),
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-06"), slotID: config.weeklySlots[1].id))
    }
}
extension RepositoryScenario {
    func draft(empty: Bool = false) async throws -> WorkoutDraft {
        let state = try await repository.snapshot(programID: programID).state
        var logs = firstEvent.exercises
        if empty { for i in logs.indices { logs[i].actualSets = []; logs[i].problem = .none; logs[i].finalEffort = .unknown } }
        return WorkoutDraft(id: UUID(uuidString: firstEvent.eventID)!, programID: state.config.programID,
            expectedRevision: state.revision, planned: state.activePrescription, displayed: state.activePrescription,
            date: firstEvent.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal, logs: logs, workingSetsStarted: !empty)
    }
    func reopened() async throws -> TrainingRepository { await repository.close(); return try TrainingRepository.open(at: storeURL) }
}
extension RepositoryTestHarness {
    static func event(state: ProgramState, reps: Int = 12) -> CompletedWorkout {
        let p = state.activePrescription
        let logs = p.exercises.map { row -> ExerciseLog in
            let movement = state.config.movements.first { $0.id == row.baseMovementID }!
            let load = movement.loadingMode == .externalLoad ? row.load ?? movement.availableLoads.first : nil
            return ExerciseLog(movementID: row.movementID, prescriptionID: p.id, status: row.kind == .paused ? .skipped : .completed,
                actualLoad: load, actualSets: row.sets.map { _ in ActualSet(reps: reps, leftReps: movement.repCounting == .perSide ? reps : nil,
                    rightReps: movement.repCounting == .perSide ? reps : nil) }, finalEffort: .onTarget, problem: .none,
                baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot)
        }
        return CompletedWorkout(eventID: UUID().uuidString, date: p.date, slotID: p.slotID, prescriptionID: p.id,
            plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs)
    }
}

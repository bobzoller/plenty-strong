import Foundation
import TrainingCore
@testable import PlentyStrong

/// Every scenario owns a fresh synthetic store and a frozen clock.
@MainActor struct GuidedWorkoutFixture {
    let model: WorkoutViewModel
    let repository: TrainingRepository
    let storeURL: URL

    static func make(schemaVersion: Int = 4, goal: Goal = .size) async throws -> GuidedWorkoutFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("training.store")
        let repository = try TrainingRepository.open(at: storeURL)
        do {
            let config: ProgramConfig
            let rules: Ruleset
            switch schemaVersion {
            case 3:
                config = try selectFixedProgram(goal: goal, programID: UUID())
                rules = try RulesetCatalog.exactV1()
            case 4:
                config = try selectStarterProgram(choice: .upperBody, goal: goal, programID: UUID())
                rules = try RulesetCatalog.starter(.upperBody)
            default:
                throw EngineError(code: "unsupported_version", field: "fixture.schemaVersion")
            }
            let clock = ISO8601DateFormatter().date(from: "2026-10-10T20:00:00Z")!
            let first = try WorkoutScheduler.nextSlot(onOrAfter: LocalDate(iso8601: "2026-10-10"), config: config)
            let snapshot = try await repository.initialize(config: config, rules: rules, firstWorkout: first)
            let model = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: { clock })
            try await model.start(easierToday: false)
            return GuidedWorkoutFixture(model: model, repository: repository, storeURL: storeURL)
        } catch {
            await repository.close()
            throw error
        }
    }
}

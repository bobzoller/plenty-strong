import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

struct StarterRepositoryScenario {
    let repository: TrainingRepository
    let storeURL: URL
    let programID: UUID
    let initial: StoreSnapshot
    let headHash: String
}
enum StarterRepositoryTestHarness {
    static func make(choice: StarterProgramChoice, goal: Goal) async throws -> StarterRepositoryScenario {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("training.store")
        let repository = try TrainingRepository.open(at: url)
        let id = UUID()
        let initial = try await repository.initialize(config: selectStarterProgram(choice: choice, goal: goal, programID: id),
            rules: RulesetCatalog.starter(choice), firstWorkout: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        return StarterRepositoryScenario(repository: repository, storeURL: url, programID: id, initial: initial,
            headHash: try await repository.exportBackup().heads[initial.state.config.programID]!)
    }
}
@Suite(.serialized) struct StarterProgramRepositoryTests {
    @Test func switchIsAtomicStaleSafeAndReplayable() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let before = try await s.repository.exportBackup()
        let counts = try await s.repository.counts()
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        for attempt in 0..<3 {
            if attempt == 2 { await s.repository.failNextSave() }
            await #expect(throws: (any Error).self) {
                try await s.repository.changeStarterProgram(programID: s.programID, expectedRevision: attempt == 0 ? 9 : 0,
                    expectedHeadHash: attempt == 1 ? "stale" : s.headHash, choice: .wholeBodyGlutes, goal: .size, next: next)
            }
            #expect(try await s.repository.exportBackup() == before)
            #expect(try await s.repository.counts() == counts)
        }
        let changed = try await s.repository.changeStarterProgram(programID: s.programID, expectedRevision: 0,
            expectedHeadHash: s.headHash, choice: .wholeBodyGlutes, goal: .size, next: next)
        #expect(changed.state.revision == 1 && changed.state.config.programID == s.initial.state.config.programID)
        #expect(changed.history.first == s.initial.history.first)
        #expect(try await s.repository.counts() == [2, 1, 0, 2, 0])
        await s.repository.close()
        let reopened = try TrainingRepository.open(at: s.storeURL)
        #expect(try await reopened.snapshot(programID: s.programID) == changed)
    }
}

extension StarterRepositoryScenario {
    func change(_ choice: StarterProgramChoice, goal: Goal = .size, next: WorkoutSlot? = nil) async throws -> StoreSnapshot {
        let current = try await repository.snapshot(programID: programID)
        let head = try await repository.exportBackup().heads[current.state.config.programID]!
        return try await repository.changeStarterProgram(programID: programID, expectedRevision: current.state.revision,
            expectedHeadHash: head, choice: choice, goal: goal,
            next: next ?? WorkoutSlot(date: current.state.activePrescription.date, slotID: current.state.activePrescription.slotID))
    }
}
func starterRepositoryEvent(_ state: ProgramState, painBase: String? = nil) -> CompletedWorkout {
    let p = state.activePrescription
    let logs = p.exercises.map { row -> ExerciseLog in
        let movement = state.config.movements.first { $0.id == row.baseMovementID }!
        let paused = row.kind == .paused || row.kind == .setupReview
        let pain = row.baseMovementID == painBase
        return ExerciseLog(movementID: row.movementID, prescriptionID: p.id,
            status: paused ? .skipped : pain ? .stopped : .completed,
            actualLoad: movement.loadingMode == .externalLoad ? row.load ?? movement.availableLoads.first : nil,
            actualSets: paused || pain ? [] : row.sets.enumerated().map { index, set in
                ActualSet(reps: set.targetReps!, leftReps: movement.repCounting == .perSide ? set.targetReps : nil,
                    rightReps: movement.repCounting == .perSide ? set.targetReps : nil, setIndex: index)
            }, finalEffort: paused || pain ? .unknown : .onTarget, problem: pain ? .pain : .none,
            baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot,
            effortScope: .allWorkingSets, skippedSetIndices: paused || pain ? Array(row.sets.indices) : [], mixedLoads: false)
    }
    return CompletedWorkout(eventID: UUID().uuidString.lowercased(), date: p.date, slotID: p.slotID,
        prescriptionID: p.id, plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs)
}
func starterRepositoryDraft(_ state: ProgramState, kind: Int) -> WorkoutDraft {
    var event = starterRepositoryEvent(state)
    for i in event.exercises.indices {
        event.exercises[i].actualSets = []
        event.exercises[i].status = kind == 0 ? .partial : .skipped
        event.exercises[i].actualLoad = kind == 0 ? nil : event.exercises[i].actualLoad
        event.exercises[i].finalEffort = .unknown
        event.exercises[i].skippedSetIndices = kind == 0 ? [] : Array(state.activePrescription.exercises[i].sets.indices)
    }
    if kind == 1 { event.exercises[0].status = .partial }
    if kind == 2 { event.exercises[0].status = .stopped; event.exercises[0].problem = .pain }
    return WorkoutDraft(id: UUID(uuidString: event.eventID)!, programID: state.config.programID,
        expectedRevision: state.revision, planned: state.activePrescription, displayed: state.activePrescription,
        date: state.activePrescription.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal,
        logs: event.exercises, workingSetsStarted: kind != 0, acknowledgedMovementIDs: kind == 0 ? [] : event.exercises.map(\.movementID))
}
extension StarterProgramRepositoryTests {
    @Test func allDraftsBlockSwitchByteEquivalently() async throws {
        for kind in 0..<3 {
            let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
            let draft = starterRepositoryDraft(s.initial.state, kind: kind)
            if kind == 0 { #expect(!draft.hasObservations && draft.acknowledgedMovementIDs == []) }
            try await s.repository.saveDraft(draft)
            let before = try BackupService.bytes(await s.repository.exportBackup())
            await #expect(throws: (any Error).self) { try await s.change(.wholeBodyGlutes) }
            #expect(try BackupService.bytes(await s.repository.exportBackup()) == before)
        }
    }
    @MainActor @Test func frozenFinishBlocksSwitchAndSuppliedTimezoneSelectsFutureSlot() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        try await s.repository.saveDraft(starterRepositoryDraft(s.initial.state, kind: 3))
        let current = try await s.repository.snapshot(programID: s.programID)
        let model = WorkoutViewModel(repository: s.repository, snapshot: current, timeZoneID: "Pacific/Honolulu",
            now: { Date(timeIntervalSince1970: 1_791_757_000) })
        await s.repository.failNextSave()
        await #expect(throws: (any Error).self) { try await model.finish() }
        #expect(model.hasAmbiguousFinish)
        let before = try await s.repository.exportBackup()
        await #expect(throws: (any Error).self) { try await model.changeStarterProgram(choice: .wholeBodyGlutes, goal: .size) }
        #expect(try await s.repository.exportBackup() == before)
        let clean = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let date = try CalendarContext(timeZoneID: "Pacific/Honolulu").localDate(at: Date(timeIntervalSince1970: 1_791_757_000))
        let fresh = WorkoutViewModel(repository: clean.repository, snapshot: clean.initial, timeZoneID: "Pacific/Honolulu",
            now: { Date(timeIntervalSince1970: 1_791_757_000) })
        try await fresh.changeStarterProgram(choice: .wholeBodyGlutes, goal: .size)
        #expect(fresh.snapshot.state.activePrescription.date >= date)
    }
    @Test func removedFamilySafetySurvivesRoundTripAndExplicitClearance() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let slot = WorkoutSlot(date: s.initial.state.activePrescription.date, slotID: "SUN")
        let reserved = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: 0,
            change: .minimumRir(baseMovementID: "banded_pullups", value: 4), next: slot)
        let event = starterRepositoryEvent(reserved.state, painBase: "banded_pullups")
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE")
        let paused = try await s.repository.finalize(programID: s.programID, expectedRevision: reserved.state.revision, event: event, next: next).snapshot
        let restriction = try #require(paused.state.retainedSafety?["pull_up"])
        #expect(restriction.paused && restriction.minimumRir == 4 && restriction.sourceEventIDs.contains(event.eventID))
        let glute = try await s.change(.wholeBodyGlutes)
        #expect(glute.state.retainedSafety?["pull_up"] == restriction && glute.state.baseSafety?["banded_pullups"] == nil)
        let upper = try await s.change(.upperBody)
        #expect(upper.state.retainedSafety?["pull_up"] == restriction && upper.state.baseSafety?["banded_chinups"] == restriction)
        let resumed = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: upper.state.revision,
            change: .safeResume(baseMovementID: "banded_pullups", externalClearanceConfirmed: true), next: next)
        #expect(resumed.state.retainedSafety?["pull_up"]?.paused == false)
        _ = try await s.change(.wholeBodyGlutes)
        let again = try await s.change(.upperBody)
        #expect(again.state.retainedSafety?["pull_up"]?.paused == false)
        #expect(again.state.retainedSafety?["pull_up"]?.minimumRir == 4)
        #expect(again.state.retainedSafety?["pull_up"]?.sourceEventIDs == restriction.sourceEventIDs)
    }
    @Test func switchPreservesVerifiedCompatibleLoadsAndFreshAngleSpecificVariants() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let event = starterRepositoryEvent(s.initial.state)
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE")
        let completed = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: event, next: next).snapshot
        let old = try await s.repository.exportBackup()
        let upper = try await s.change(.upperBody)
        let rdl = completed.state.config.activeVariantIDs!["db_romanian_deadlift"]!
        #expect(upper.state.exercises[rdl]?.load == completed.state.exercises[rdl]?.load)
        #expect(upper.state.exercises[rdl]?.setupRevision == completed.state.exercises[rdl]?.setupRevision)
        let press = upper.state.config.activeVariantIDs!["incline_db_press_24"]!
        #expect(upper.state.exercises[press]?.load == nil)
        let glute = try await s.change(.wholeBodyGlutes)
        let oldPress = completed.state.config.activeVariantIDs!["incline_db_press_30"]!
        #expect(glute.state.exercises[oldPress]?.load == completed.state.exercises[oldPress]?.load)
        #expect(glute.state.exercises.values.allSatisfy { $0.normalSets == 2 && $0.starterState!.windows.isEmpty && $0.recentComparable.isEmpty })
        #expect(glute.state.lastSessionDate == event.date && glute.state.processedEvents == completed.state.processedEvents)
        let after = try await s.repository.exportBackup()
        #expect(old.journal.allSatisfy { after.journal.contains($0) })
        #expect(old.rules.allSatisfy { after.rules.contains($0) } && old.profiles.allSatisfy { after.profiles.contains($0) })
        await #expect(throws: (any Error).self) { try await s.change(.upperBody, next: WorkoutSlot(date: event.date, slotID: "SUN")) }
        #expect(try await s.repository.exportBackup() == after)
    }
    @Test(arguments: [false, true]) func legacySchemasCanExplicitlySwitchWithoutRewritingOriginals(exact: Bool) async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        if exact { _ = try await activateSynthetic(s.repository, id: s.programID) }
        let before = try await s.repository.exportBackup()
        let current = try await s.repository.snapshot(programID: s.programID)
        let changed = try await s.repository.changeStarterProgram(programID: s.programID, expectedRevision: current.state.revision,
            expectedHeadHash: before.heads[current.state.config.programID]!, choice: .wholeBodyGlutes, goal: .size,
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        let after = try await s.repository.exportBackup()
        #expect(changed.state.schemaVersion == 4)
        #expect(before.journal.allSatisfy { after.journal.contains($0) })
        #expect(before.profiles.allSatisfy { after.profiles.contains($0) } && before.rules.allSatisfy { after.rules.contains($0) })
    }
}

extension StarterProgramRepositoryTests {
    @Test func revisitedExplicitBodyweightVariationUsesVerifiedPriorSelection() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let id = UUID().uuidString.lowercased()
        let slot = WorkoutSlot(date: s.initial.state.activePrescription.date, slotID: "SUN")
        let created = try await s.repository.applyVariantChange(programID: s.programID, expectedRevision: 0,
            change: .createLoadingMode(baseMovementID: "db_floor_glute_bridge", variantID: id,
                modifications: "Synthetic comfortable floor setup", mode: .bodyweight), next: slot)
        let variant = try #require(created.state.config.variants?[id])
        _ = try await s.change(.upperBody)
        let revisited = try await s.change(.wholeBodyGlutes)
        #expect(revisited.state.config.activeVariantIDs?["db_floor_glute_bridge"] == id)
        #expect(revisited.state.config.variants?[id] == variant)
        #expect(revisited.state.exercises[id]?.load == nil && revisited.state.exercises[id]?.setupRevision == created.state.exercises[id]?.setupRevision)
        #expect(revisited.state.exercises[id]?.starterState?.windows.isEmpty == true)
        let bridge = try #require(revisited.state.activePrescription.exercises.first { $0.movementID == id })
        #expect(bridge.load == nil && bridge.kind == .working)
        let restored = try BackupService.validate(await s.repository.exportBackup())
        #expect(restored.heads[revisited.state.config.programID]?.returnedState == revisited.state)
    }
}

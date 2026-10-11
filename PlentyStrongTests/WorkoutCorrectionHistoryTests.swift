import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

/// Real synthetic journals shared by the History, backup and fake-cloud assertions.
struct CorrectionHistoryFixture {
    let programID: UUID
    let movementID: String
    let event: CompletedWorkout
    let envelope: JournalEnvelope
    let plainEnvelope: JournalEnvelope
    let prefix: BackupDocument
    let document: BackupDocument

    static func make(inactive: Bool = false) async throws -> Self {
        let repository = try BackupTests().empty()
        let programID = UUID()
        var config = try selectFixedProgram(goal: .size, programID: programID)
        for movement in config.movements { config.initialLoads[movement.id] = .some(movement.availableLoads.first) }
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU")
        var snapshot = try await repository.initialize(config: config, rules: RulesetCatalog.exactV1(), firstWorkout: slot)
        let base = snapshot.state.activePrescription.exercises[0].baseMovementID!
        let defaultID = snapshot.state.config.activeVariantIDs![base]!
        snapshot = try await repository.applyVariantChange(programID: programID, expectedRevision: 0,
            change: .create(baseMovementID: base, variantID: "synthetic-corrected-setup", modifications: "Synthetic bench"), next: slot)
        let prefix = try await repository.exportBackup()
        let plainRepository = try BackupTests().empty()
        _ = try await plainRepository.importBackup(prefix)
        let p = snapshot.state.activePrescription
        let logs = p.exercises.map { row in
            let movement = MovementPrescriptionSummary.effectiveMovement(state: snapshot.state, variantID: row.movementID)!
            return ExerciseLog(movementID: row.movementID, prescriptionID: p.id, status: .completed, actualLoad: row.load,
                actualSets: row.sets.enumerated().map { index, set in
                    ActualSet(reps: set.targetReps!, leftReps: movement.repCounting == .perSide ? set.targetReps : nil,
                        rightReps: movement.repCounting == .perSide ? set.targetReps : nil, setIndex: index)
                }, finalEffort: .onTarget, problem: .none, baseMovementID: row.baseMovementID,
                modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
        }
        var event = CompletedWorkout(eventID: UUID().uuidString, date: p.date, slotID: p.slotID, prescriptionID: p.id,
            plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs)
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN")
        let plain = try await plainRepository.finalize(programID: programID, expectedRevision: snapshot.state.revision, event: event, next: next)
        let after = event.exercises[0].actualSets[0]
        var before = after; before.reps = 7; before.missedGoalReason = .effortLimit
        event.observationAudit = ObservationAudit(corrections: [SetCorrection(operationID: UUID(), movementID: logs[0].movementID,
            setIndex: 0, before: before, after: after, beforeStatus: .completed, afterStatus: .completed, outcomeAcknowledged: true)])
        let audited = try await repository.finalize(programID: programID, expectedRevision: snapshot.state.revision, event: event, next: next)
        if inactive {
            _ = try await repository.applyVariantChange(programID: programID, expectedRevision: audited.snapshot.state.revision,
                change: .select(baseMovementID: base, variantID: defaultID), next: next)
        }
        let document = try await repository.exportBackup()
        await repository.close(); await plainRepository.close()
        return Self(programID: programID, movementID: logs[0].movementID, event: event,
            envelope: audited.snapshot.history.last!, plainEnvelope: plain.snapshot.history.last!, prefix: prefix, document: document)
    }

    func formats() throws -> [BackupDocument] {
        var graph = document; graph.formatVersion = 2
        graph.recovery = BackupService.graphManifest(try RecoveryVerifier().verify(BackupService.recoveryRecords(document)),
            originals: [], quarantines: [], resolved: [])
        return [document, graph]
    }
}

@MainActor struct WorkoutCorrectionHistoryTests {
    @Test func historyShowsOriginalAndEffectiveWithoutRewritingGoals() async throws {
        let f = try await CorrectionHistoryFixture.make()
        let issued = try #require(MovementPrescriptionSummary.issuedWorkout(envelope: f.envelope,
            history: BackupService.validate(f.document).histories[f.programID.uuidString.lowercased()]!))
        #expect(issued.displayed.exercises.first { $0.movementID == f.movementID }!.sets[0].targetReps == 8)
        let edits = WorkoutDetailView.corrections(event: f.event, movementID: f.movementID, setIndex: 0)
        #expect(edits.map(\.before.reps) == [7] && edits.map(\.after.reps) == [8])
        #expect(f.event.exercises[0].actualSets[0].reps == 8)
        #expect(WorkoutDetailView.correctionDetail(edits[0]).contains("Original: 7"))
        #expect(WorkoutDetailView.correctionDetail(edits[0]).contains("Replacement: 8"))
        #expect(WorkoutDetailView.correctionDetail(edits[0]).contains(MissedGoalReason.effortLimit.title))
        #expect(WorkoutDetailView.corrections(event: f.event, movementID: "other-setup", setIndex: 0).isEmpty)
        #expect(WorkoutDetailView.corrections(event: f.event, movementID: f.movementID, setIndex: 1).isEmpty)
    }

    @Test func correctionOrderAndMissingSideRemainRaw() async throws {
        let f = try await CorrectionHistoryFixture.make()
        var event = f.event
        var original = ActualSet(reps: 7, leftReps: 7, rightReps: nil, setIndex: 2, missedGoalReason: .effortLimit)
        var replacement = original; replacement.reps = 8; replacement.leftReps = 8
        let first = SetCorrection(operationID: UUID(), movementID: f.movementID, setIndex: 2, before: original,
            after: replacement, beforeStatus: .partial, afterStatus: .partial, outcomeAcknowledged: true)
        original = replacement; replacement.reps = 9; replacement.leftReps = 9
        let second = SetCorrection(operationID: UUID(), movementID: f.movementID, setIndex: 2, before: original,
            after: replacement, beforeStatus: .partial, afterStatus: .partial, outcomeAcknowledged: true)
        event.observationAudit = ObservationAudit(corrections: [first, second])
        #expect(WorkoutDetailView.corrections(event: event, movementID: f.movementID, setIndex: 2) == [first, second])
        #expect(WorkoutDetailView.correctionDetail(first).contains("right unrecorded"))
        #expect(WorkoutDetailView.correctionDetail(second).contains("right unrecorded"))
        event.observationAudit = nil
        #expect(WorkoutDetailView.corrections(event: event, movementID: f.movementID, setIndex: 2).isEmpty)
    }
}

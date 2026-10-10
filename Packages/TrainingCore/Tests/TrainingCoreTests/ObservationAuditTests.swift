import Foundation
import Testing
@testable import TrainingCore

struct ObservationAuditTests {
    @Test func originalsReplayAndLegacyBytes() throws {
        let (state, event) = try fixture()
        let effective = event.exercises
        let after = effective[0].actualSets[0]
        var before = after; before.reps = 7; before.missedGoalReason = .effortLimit
        let audit = ObservationAudit(corrections: [correction(event, before: before, after: after)])
        let originals = try validate(event, audit: audit, state: state)
        #expect(originals[0].actualSets[0].reps == 7)
        #expect(effective[0].actualSets[0].reps == 8)
        #expect(state.activePrescription.exercises[0].sets[0].targetReps == 8)
        #expect(originals[0].actualLoad == effective[0].actualLoad)
        #expect(originals[0].effortScope == effective[0].effortScope)
        #expect(try JSONDecoder().decode(ObservationAudit.self, from: JSONEncoder().encode(audit)) == audit)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("docs/specs/2026-10-05-general-fitness-progression-examples.json"))
        let archive = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let base = archive["baseInput"] as! [String: Any]
        let originalLegacyBytes = try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self,
            from: JSONSerialization.data(withJSONObject: base["event"]!)))
        let legacyEvent = try JSONDecoder().decode(CompletedWorkout.self, from: originalLegacyBytes)
        let value = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(legacyEvent))
        #expect(try CanonicalJSON.encode(value) == originalLegacyBytes)
    }

    @Test func legacyArrayBindingRetainsNilIndexAndNoTarget() throws {
        let state = try initializeProgram(config: selectFixedProgram(goal: .size,
            programID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            rules: RulesetCatalog.fixedV1(), firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-04"), slotID: "SUN")).state
        let row = state.activePrescription.exercises[0]
        let log = ExerciseLog(movementID: row.movementID, prescriptionID: state.activePrescription.id,
            status: .partial, actualLoad: row.load, actualSets: [ActualSet(reps: 8)],
            finalEffort: .onTarget, problem: .none, baseMovementID: row.baseMovementID,
            modificationsSnapshot: row.modificationsSnapshot)
        let audit = ObservationAudit(corrections: [SetCorrection(operationID: UUID(), movementID: row.movementID,
            setIndex: 0, before: ActualSet(reps: 7), after: ActualSet(reps: 8), beforeStatus: .partial,
            afterStatus: .partial, outcomeAcknowledged: true)])
        let originals = try ObservationAuditValidator.originalLogs(effective: [log], audit: audit,
            prescription: state.activePrescription, config: state.config, schemaVersion: 2)
        #expect(originals[0].actualSets == [ActualSet(reps: 7)])
        #expect(originals[0].actualSets[0].setIndex == nil)
        #expect(originals[0].actualSets[0].missedGoalReason == nil)
        #expect(originals[0].effortScope == nil)
        #expect(row.sets.allSatisfy { $0.targetReps == nil })
        var indexed = audit; indexed.corrections[0].before.setIndex = 0
        #expect(throws: EngineError.self) { try ObservationAuditValidator.originalLogs(effective: [log], audit: indexed,
            prescription: state.activePrescription, config: state.config, schemaVersion: 2) }
    }

    @Test func rejectsForgedChainsAndOutcomePromotion() throws {
        let (state, event) = try fixture()
        let after = event.exercises[0].actualSets[0]
        var before = after; before.reps = 7; before.missedGoalReason = .effortLimit
        let good = ObservationAudit(corrections: [correction(event, before: before, after: after)])
        for mutate in [
            { (a: inout ObservationAudit) in a.corrections.append(a.corrections[0]) },
            { (a: inout ObservationAudit) in a.corrections[0].before.setIndex = 1 },
            { (a: inout ObservationAudit) in a.corrections[0].after.reps = 9 },
            { (a: inout ObservationAudit) in a.corrections[0].before.reps = -1 },
            { (a: inout ObservationAudit) in a.version = 2 },
            { (a: inout ObservationAudit) in a.corrections[0].beforeStatus = .stopped },
            { (a: inout ObservationAudit) in a.corrections[0].beforeStatus = .stopped; a.corrections[0].afterStatus = .stopped; a.corrections[0].outcomeAcknowledged = false },
            { (a: inout ObservationAudit) in a.corrections[0].beforeStatus = .partial; a.corrections[0].afterStatus = .partial },
            { (a: inout ObservationAudit) in a.corrections[0].movementID = "absent" },
            { (a: inout ObservationAudit) in a.corrections[0].setIndex = -1 },
            { (a: inout ObservationAudit) in a.corrections[0].before.leftReps = -1 }
        ] {
            var bad = good; mutate(&bad)
            #expect(throws: EngineError.self) { try validate(event, audit: bad, state: state) }
        }
        var disconnected = good
        var first = before; first.reps = 6
        disconnected.corrections.insert(correction(event, before: first, after: after), at: 0)
        #expect(throws: EngineError.self) { try validate(event, audit: disconnected, state: state) }
        var unsupported = state; unsupported.schemaVersion = 1
        #expect(throws: EngineError.self) { try validate(event, audit: good, state: unsupported) }
    }

    @Test func chainedCorrectionsAndFirstOutcomePreserveOriginals() throws {
        let (state, event) = try fixture()
        let after = event.exercises[0].actualSets[0]
        var middle = after; middle.reps = 7; middle.missedGoalReason = .effortLimit
        var before = middle; before.reps = 0
        var first = correction(event, before: before, after: middle)
        first.beforeStatus = .partial; first.afterStatus = .partial; first.outcomeAcknowledged = false
        var second = correction(event, before: middle, after: after)
        second.beforeStatus = .partial; second.afterStatus = .partial; second.outcomeAcknowledged = false
        let audit = ObservationAudit(corrections: [first, second])
        #expect(try validate(event, audit: audit, state: state)[0].actualSets[0] == before)
    }

    @Test func rawSidesAndDemotedAcknowledgedOutcomeCannotPromote() throws {
        let (state, originalEvent) = try fixture()
        var event = originalEvent; event.exercises[0].status = .partial
        let after = event.exercises[0].actualSets[0]
        var before = after; before.reps = 0; before.leftReps = 0; before.rightReps = 2; before.missedGoalReason = .effortLimit
        var record = correction(event, before: before, after: after)
        record.beforeStatus = .completed; record.afterStatus = .partial
        let audit = ObservationAudit(corrections: [record])
        let originals = try validate(event, audit: audit, state: state)
        #expect(originals[0].actualSets[0] == before)
        #expect(originals[0].status == .completed)
        event.exercises[0].status = .completed
        #expect(throws: EngineError.self) { try validate(event, audit: audit, state: state) }
        event.exercises[0].status = .partial; event.exercises[0].problem = .pain
        #expect(throws: EngineError.self) { try validate(event, audit: audit, state: state) }
    }

    @Test func laterSafetyStopDominatesEarlierCorrectionContext() throws {
        let (state, originalEvent) = try fixture()
        var event = originalEvent
        let after = event.exercises[0].actualSets[0]
        var before = after; before.reps = 7; before.missedGoalReason = .effortLimit
        for problem in [Problem.pain, .controlLost] {
            event.exercises[0].problem = problem; event.exercises[0].status = .stopped
            var record = correction(event, before: before, after: after)
            record.beforeStatus = .partial; record.afterStatus = .partial; record.outcomeAcknowledged = false
            let audit = ObservationAudit(corrections: [record])
            #expect(try validate(event, audit: audit, state: state)[0].actualSets[0] == before)
            record.outcomeAcknowledged = true
            #expect(try validate(event, audit: ObservationAudit(corrections: [record]), state: state)[0].status == .partial)
            event.exercises[0].status = .completed
            #expect(throws: EngineError.self) { try validate(event, audit: ObservationAudit(corrections: [record]), state: state) }
        }
    }

    @Test func explicitSchemaThreeBindingAndAcknowledgementCannotDisappear() throws {
        let (state, event) = try fixture()
        let after = event.exercises[0].actualSets[0]
        var middle = after; middle.reps = 7; middle.missedGoalReason = .effortLimit
        var before = middle; before.reps = 6
        let first = correction(event, before: before, after: middle)
        var second = correction(event, before: middle, after: after)
        let valid = ObservationAudit(corrections: [first, second])
        #expect(try ObservationAuditValidator.originalLogs(effective: event.exercises, audit: valid,
            prescription: state.activePrescription, config: state.config, schemaVersion: 3)[0].actualSets[0] == before)
        second.outcomeAcknowledged = false
        #expect(throws: EngineError.self) { try validate(event, audit: ObservationAudit(corrections: [first, second]), state: state) }
    }

    private func fixture() throws -> (ProgramState, CompletedWorkout) {
        var state = try starterState()
        try starterSet(&state, base: "db_romanian_deadlift", targets: [8, 8])
        return (state, try starterCompletion(state: state, actualsByBase: ["db_romanian_deadlift": [8, 8]]))
    }
    private func correction(_ event: CompletedWorkout, before: ActualSet, after: ActualSet) -> SetCorrection {
        SetCorrection(operationID: UUID(), movementID: event.exercises[0].movementID, setIndex: 0,
            before: before, after: after, beforeStatus: .completed, afterStatus: .completed, outcomeAcknowledged: true)
    }
    private func validate(_ event: CompletedWorkout, audit: ObservationAudit?, state: ProgramState) throws -> [ExerciseLog] {
        try ObservationAuditValidator.originalLogs(effective: event.exercises, audit: audit,
            prescription: state.activePrescription, config: state.config, schemaVersion: state.schemaVersion)
    }
}

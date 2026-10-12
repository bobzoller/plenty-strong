import Foundation
import Testing
@testable import TrainingCore

struct ProgramMigrationTests {
    func fixture(recoveryRequired: Bool = false) throws -> (ProgramMigrationDocument, MigrationSelection, MigrationAcceptance) {
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let rows = config.movements.map { movement in
            var row = MigrationBaseline(baseMovementID: movement.id, variantID: movement.id + "-imported",
                modifications: movement.loadingMode == .userManagedAssistance ? "Synthetic manual setting 137" : "Synthetic saved setup",
                load: movement.loadingMode == .externalLoad ? movement.availableLoads[3] : nil,
                targets: movement.loadingMode == .userManagedAssistance ? [7, 5, 4] : [11, 10, 9],
                sourceRepFloor: movement.loadingMode == .userManagedAssistance ? 5 : 8,
                sourceRepCeiling: 12, minimumRir: movement.id == "bent_knee_hanging_leg_raise_ab_straps" ? 3 : 2,
                paused: false, reviewRequired: false, recoveryStatus: "unknown",
                safetyText: "Synthetic retained safeguard", sourceKeys: ["state:" + movement.id])
            row.recoveryRequired = recoveryRequired
            return row
        }
        let workouts = [ExternalWorkoutObservation(date: try LocalDate(iso8601: "2025-04-06"), sourceKey: "day:1",
            rows: [ExternalExerciseObservation(sourceKey: "row:1", movementLabel: "Source label",
                raw: ["reps": .string("5.5/BW"), "notes": .string("Synthetic original note")])])]
        let sourceState: [String: CanonicalValue] = ["qualifying": .integer(2), "phase": .string("source deload")]
        struct Original: Encodable { var baselines: [MigrationBaseline]; var workouts: [ExternalWorkoutObservation]; var sourceState: [String: CanonicalValue] }
        let file = try ExternalSourceFile(name: "synthetic-original.json", mediaType: "application/json",
            bytes: JSONEncoder().encode(Original(baselines: rows, workouts: workouts, sourceState: sourceState)))
        var bindings: [MigrationSourceBinding] = []
        for (i, row) in rows.enumerated() {
            var keys = ["baseMovementID", "variantID", "modifications", "recoveryStatus", "sourceKeys", "targets", "sourceRepFloor", "sourceRepCeiling", "minimumRir", "safetyText", "reviewRequired", "paused", "recoveryRequired"]
            if row.load != nil { keys += ["load/amount", "load/unit", "load/basis"] }
            for key in keys { let pointer = "/baselines/\(i)/\(key)"; bindings.append(MigrationSourceBinding(targetPointer: pointer, fileName: file.name, sourcePointer: pointer)) }
        }
        for pointer in ["/baselines", "/workouts", "/sourceState", "/workouts/0/date", "/workouts/0/sourceKey", "/workouts/0/rows/0/sourceKey", "/workouts/0/rows/0/raw", "/workouts/0/rows/0/movementLabel"] {
            bindings.append(MigrationSourceBinding(targetPointer: pointer, fileName: file.name, sourcePointer: pointer))
        }
        let archive = try ExternalSourceArchive(files: [file], baselines: rows, workouts: workouts,
            sourceState: sourceState, sourceBindings: bindings)
        let checkpoint = try ProgramMigrationCheckpoint(externalArchiveHash: archive.contentHash, baselines: rows,
            externalLastSessionDate: LocalDate(iso8601: "2025-04-06"),
            nextWorkout: WorkoutSlot(date: LocalDate(iso8601: "2025-04-08"), slotID: "TUE"))
        return (ProgramMigrationDocument(source: archive, checkpoint: checkpoint),
            MigrationSelection(goal: .fatLoss, acceptedNativePolicy: true),
            MigrationAcceptance(acceptedAtMilliseconds: 1_744_048_800_000, timeZoneID: "Pacific/Honolulu"))
    }

    @Test func checkpointRetainsEstablishedTargetsAndHasNoNativePastCredit() throws {
        let (doc, selection, acceptance) = try fixture()
        let preview = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID())
        let state = preview.initialized.state
        #expect(state.schemaVersion == 5)
        #expect(state.config.goal == .fatLoss)
        #expect(state.schedulingPolicy == .flexibleV1)
        #expect(state.processedEvents.isEmpty && state.lastSessionDate == nil)
        #expect(doc.checkpoint.baselines.allSatisfy { state.exercises[$0.variantID]?.mode == .normal })
        #expect(state.exercises.values.allSatisfy { $0.normalSets == 3 && $0.ceilingStreak == 0 && $0.recentComparable.isEmpty && $0.exactRepState?.lastSuitableNormalDate == nil })
        for row in doc.checkpoint.baselines {
            #expect(state.exercises[row.variantID]?.exactRepState?.normalTargets == row.targets)
            #expect(state.exercises[row.variantID]?.load == row.load)
        }
        let prepared = try prepareInterruptedReturn(state: state, asOf: LocalDate(iso8601: "2025-04-07"), rules: RulesetCatalog.migratedExactV1())
        #expect(prepared.state == state)
        #expect(prepared.workout.exercises.allSatisfy { $0.sets.count == 3 })
        #expect(prepared.workout.exercises.first { $0.baseMovementID == "bent_knee_hanging_leg_raise_ab_straps" }?.sets.first?.effortInstruction.contains("3 good reps") == true)
        #expect(prepared.workout.exercises.allSatisfy { $0.restSeconds == 120 })
    }

    @Test func missingConsentAndTamperedExternalArchivesReject() throws {
        var (doc, selection, acceptance) = try fixture()
        selection.acceptedNativePolicy = false
        #expect(throws: (any Error).self) { try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID()) }
        selection.acceptedNativePolicy = true
        doc.source.files[0].bytes.append(0)
        #expect(throws: (any Error).self) { try validateMigrationDocument(doc) }
    }

    @Test func sourceStateMismatchAndImpossibleCurrentTargetsReject() throws {
        var (doc, selection, acceptance) = try fixture()
        doc.checkpoint.baselines[0].targets = [10, 10, 10]
        #expect(throws: (any Error).self) { try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID()) }
        (doc, selection, acceptance) = try fixture()
        doc.checkpoint.externalArchiveHash = "wrong"
        #expect(throws: (any Error).self) { try validateMigrationDocument(doc) }
    }

    @Test func externalObservationsRemainRawAndStable() throws {
        let (doc, _, _) = try fixture()
        let bytes = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(ProgramMigrationDocument.self, from: bytes)
        try validateMigrationDocument(decoded)
        #expect(decoded == doc)
        #expect(decoded.source.workouts[0].rows[0].raw["reps"] == .string("5.5/BW"))
        #expect(decoded.source.files[0].bytes == doc.source.files[0].bytes)
    }

    @Test func manualSettingsNeverBecomeExternalLoadsAndLowerTargetsHaveAdmittedFloor() throws {
        let (doc, selection, acceptance) = try fixture()
        let state = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID()).initialized.state
        let pull = state.config.activeVariantIDs!["banded_pullups"]!
        let chin = state.config.activeVariantIDs!["banded_chinups"]!
        #expect(pull != chin)
        #expect(state.exercises[pull]?.load == nil)
        #expect(state.exercises[pull]?.repFloor == 4)
        #expect(state.exercises[pull]?.exactRepState?.normalTargets == [7, 5, 4])
    }

    @Test func rehashedProjectionCannotContradictOriginalFile() throws {
        var (doc, _, _) = try fixture()
        doc.source.baselines[0].targets = [10, 10, 10]
        doc.source.contentHash = try migrationHash(doc.source, excluding: "contentHash")
        doc.checkpoint.baselines = doc.source.baselines
        doc.checkpoint.externalArchiveHash = doc.source.contentHash
        do { try validateMigrationDocument(doc); Issue.record("Contradictory source projection accepted") }
        catch let error as EngineError { #expect(error.field == "source_binding.mismatch") }
    }

    @Test func firstNativeSessionUsesActualEarlyDateAndRetainedTargetsWithoutPastCredit() throws {
        let (doc, selection, acceptance) = try fixture()
        let rules = try RulesetCatalog.migratedExactV1()
        let before = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID()).initialized.state
        let plan = before.activePrescription
        let logs = plan.exercises.map { row in
            let movement = before.config.movements.first { $0.id == row.baseMovementID }!
            return ExerciseLog(movementID: row.movementID, prescriptionID: plan.id, status: .completed, actualLoad: row.load,
                actualSets: row.sets.enumerated().map { index, set in ActualSet(reps: set.targetReps!,
                    leftReps: movement.repCounting == .perSide ? set.targetReps : nil,
                    rightReps: movement.repCounting == .perSide ? set.targetReps : nil, setIndex: index) },
                finalEffort: .onTarget, problem: .none, baseMovementID: row.baseMovementID,
                modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
        }
        var event = CompletedWorkout(eventID: "synthetic-native-first", date: try LocalDate(iso8601: "2025-04-07"),
            slotID: plan.slotID, prescriptionID: plan.id, plannedPrescriptionID: plan.id, sessionMode: .normal, exercises: logs)
        let start = try SessionTiming.milliseconds(at: ISO8601DateFormatter().date(from: "2025-04-07T20:00:00Z")!)
        event.timing = SessionTiming(plannedDate: plan.date, startedAtMilliseconds: start, finishedAtMilliseconds: start + 3_600_000, timeZoneID: "Pacific/Honolulu")
        let next = try WorkoutScheduler.nextRotation(after: plan.date, consumedSlotID: plan.slotID, config: before.config)
        guard case let .applied(after, pending, _) = advanceProgram(AdvanceInput(state: before, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)) else {
            Issue.record("Real first native session rejected"); return
        }
        #expect(after.revision == 1 && after.processedEvents.count == 1)
        #expect(after.lastSessionDate == event.date)
        #expect(pending.slotID == "THU")
        guard case .noOp = advanceProgram(AdvanceInput(state: after, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)) else { Issue.record("Duplicate applied again"); return }
        event.eventID = "synthetic-backdate"; event.date = try LocalDate(iso8601: "2025-04-06")
        guard case .rejected = advanceProgram(AdvanceInput(state: before, event: event, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date)) else { Issue.record("External actual boundary ignored"); return }
    }

    @Test func goalResetAndNewSetupRetainMigratedDoseAndExternalSafety() throws {
        let (doc, selection, acceptance) = try fixture()
        let rules = try RulesetCatalog.migratedExactV1()
        let state = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID()).initialized.state
        let slot = doc.checkpoint.nextWorkout
        let changed = try reconfigureProgram(state: state, change: .goal(.maintenance), rules: rules, nextWorkout: slot)
        #expect(changed.workout.exercises.allSatisfy { $0.sets.count == 3 })
        #expect(changed.state.baseSafety?["bent_knee_hanging_leg_raise_ab_straps"]?.minimumRir == 3)
        let created = try changeMovementVariant(state: changed.state,
            change: .create(baseMovementID: "suitcase_db_squat", variantID: "new-source-independent-setup", modifications: "New setup"),
            rules: rules, nextWorkout: slot)
        #expect(created.state.exercises["new-source-independent-setup"]?.normalSets == 3)
        #expect(created.state.migration?.clockAnchors["new-source-independent-setup"] == nil)
    }

    @Test func sourceRecoveryRequirementNeedsFreshNativeSessionAttestation() throws {
        let (doc, selection, acceptance) = try fixture(recoveryRequired: true)
        let rules = try RulesetCatalog.migratedExactV1()
        let state = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID()).initialized.state
        let plan = state.activePrescription
        let logs = plan.exercises.map { row in
            ExerciseLog(movementID: row.movementID, prescriptionID: plan.id, status: .partial,
                actualLoad: row.load, actualSets: [ActualSet(reps: 1, setIndex: 0, missedGoalReason: .otherUnknown)],
                finalEffort: .unknown, problem: .none, baseMovementID: row.baseMovementID,
                modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
        }
        var event = CompletedWorkout(eventID: "synthetic-recovery-required", date: try LocalDate(iso8601: "2025-04-07"),
            slotID: plan.slotID, prescriptionID: plan.id, plannedPrescriptionID: plan.id, sessionMode: .normal, exercises: logs)
        let start = try SessionTiming.milliseconds(at: ISO8601DateFormatter().date(from: "2025-04-07T20:00:00Z")!)
        event.timing = SessionTiming(plannedDate: plan.date, startedAtMilliseconds: start, finishedAtMilliseconds: start + 3_600_000, timeZoneID: "Pacific/Honolulu")
        let next = try WorkoutScheduler.nextRotation(after: plan.date, consumedSlotID: plan.slotID, config: state.config)
        func advance(_ value: CompletedWorkout) -> AdvanceResult {
            advanceProgram(AdvanceInput(state: state, event: value, rules: rules, nextSlotID: next.slotID, nextWorkoutDate: next.date))
        }
        guard case let .applied(raw, _, _) = advance(event) else { Issue.record("Unconfirmed partial observations must remain recordable"); return }
        #expect(raw.exercises.values.allSatisfy { $0.recentComparable.isEmpty })
        for index in event.exercises.indices { event.exercises[index].status = .completed }
        guard case let .rejected(_, errors) = advance(event) else { Issue.record("Completed work lacked source-required review"); return }
        #expect(errors == ["migration_recovery_required"])
        event.migrationRecoveryAttestations = logs.map { MigrationRecoveryAttestation(movementID: $0.movementID, checkedAtMilliseconds: start + 1000, externalArchiveHash: doc.source.contentHash) }
        guard case let .applied(after, _, _) = advance(event) else { Issue.record("Fresh source recovery review rejected"); return }
        #expect(after.migration?.baselines.allSatisfy(\.recoveryRequired) == true)
        #expect(after.migration?.baselines.allSatisfy { $0.recoveryStatus == "unknown" } == true)
        event.migrationRecoveryAttestations![0].checkedAtMilliseconds = start - 1
        guard case .rejected = advance(event) else { Issue.record("Stale attestation accepted"); return }
    }

    @Test(arguments: Goal.allCases) func currentTargetContinuationUsesActualTwoMinuteSetRest(goal: Goal) throws {
        let (doc, _, acceptance) = try fixture()
        let selection = MigrationSelection(goal: goal, acceptedNativePolicy: true)
        let result = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID())
        #expect(result.initialized.workout.exercises.allSatisfy { $0.restSeconds == 120 })
        #expect(result.initialized.workout.exercises.allSatisfy { $0.sets.count == 3 })
        for row in doc.checkpoint.baselines {
            #expect(result.initialized.state.exercises[row.variantID]?.exactRepState?.normalTargets == row.targets)
        }
    }

    @Test(arguments: ["baseMovementID", "variantID", "modifications", "recoveryStatus", "sourceKeys", "sourceState", "workoutSourceKey", "rowSourceKey"])
    func rehashedSourceLineageCannotChangeAgainstUnchangedOriginals(field: String) throws {
        var (doc, selection, acceptance) = try fixture()
        let originals = doc.source.files
        doc.source.sourceBindings.removeAll { binding in
            ["/baselines", "/workouts", "/sourceState"].contains(binding.targetPointer) ||
                binding.targetPointer.hasSuffix("/" + field) || binding.targetPointer.hasSuffix("/sourceKey")
        }
        switch field {
        case "baseMovementID":
            let original = doc.source.baselines[0].baseMovementID
            doc.source.baselines[0].baseMovementID = doc.source.baselines[2].baseMovementID
            doc.source.baselines[2].baseMovementID = original
        case "variantID": doc.source.baselines[0].variantID += "-forged"
        case "modifications": doc.source.baselines[0].modifications = "Invented source setup"
        case "recoveryStatus": doc.source.baselines[0].recoveryStatus = "cleared"
        case "sourceKeys": doc.source.baselines[0].sourceKeys = ["invented-source-location"]
        case "sourceState": doc.source.sourceState = [:]
        case "workoutSourceKey": doc.source.workouts[0].sourceKey = "invented-day-key"
        case "rowSourceKey": doc.source.workouts[0].rows[0].sourceKey = "invented-row-key"
        default: Issue.record("Unknown test mutation"); return
        }
        doc.source.contentHash = try migrationHash(doc.source, excluding: "contentHash")
        doc.checkpoint.externalArchiveHash = doc.source.contentHash
        doc.checkpoint.baselines = doc.source.baselines
        #expect(doc.source.files == originals)
        #expect(throws: (any Error).self) {
            _ = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID())
        }
    }

    @Test func deletingAllHistoryAndItsBindingsCannotEraseSourceObservations() throws {
        var (doc, selection, acceptance) = try fixture()
        let originals = doc.source.files
        doc.source.workouts = []
        doc.source.sourceBindings.removeAll { $0.targetPointer == "/workouts" || $0.targetPointer.hasPrefix("/workouts/") }
        doc.source.contentHash = try migrationHash(doc.source, excluding: "contentHash")
        doc.checkpoint.externalArchiveHash = doc.source.contentHash
        doc.checkpoint.externalLastSessionDate = nil
        #expect(doc.source.files == originals)
        #expect(throws: (any Error).self) {
            _ = try previewProgramMigration(document: doc, selection: selection, acceptance: acceptance, programID: UUID())
        }
    }

    @Test(arguments: ["/baselines", "/workouts", "/sourceState"])
    func aggregateExactProjectionBindingCannotBeOmitted(pointer: String) throws {
        var (doc, _, _) = try fixture()
        doc.source.sourceBindings.removeAll { $0.targetPointer == pointer }
        doc.source.contentHash = try migrationHash(doc.source, excluding: "contentHash")
        doc.checkpoint.externalArchiveHash = doc.source.contentHash
        #expect(throws: (any Error).self) { try validateMigrationDocument(doc) }
    }
}

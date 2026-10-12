import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@MainActor private final class MigrationDesignClock { var date: Date; init(_ date: Date) { self.date = date } }

@Suite(.serialized) struct ProgramMigrationRepositoryTests {
    private func store() throws -> (TrainingRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-design-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("training.store")
        return (try TrainingRepository.open(at: url), url)
    }
    @Test func atomicImportRepeatReopenAndLosslessBackupKeepEverySourceByte() async throws {
        let (repository, url) = try store()
        let document = try ProgramMigrationDesignFixture.make()
        let selection = ProgramMigrationDesignFixture.selection
        let preview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let empty = try await repository.exportBackup()
        await repository.failNextSave()
        await #expect(throws: (any Error).self) {
            try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: preview.storeFingerprint,
                acceptance: ProgramMigrationDesignFixture.acceptance)
        }
        #expect(try await repository.exportBackup() == empty)
        #expect(try await repository.counts() == [0, 0, 0, 0, 0])
        let receipt = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: preview.storeFingerprint,
            acceptance: ProgramMigrationDesignFixture.acceptance)
        #expect(receipt.accepted == 1 && receipt.identical == 0)
        #expect(receipt.snapshot.externalSource == document.source)
        #expect(receipt.snapshot.state.schemaVersion == 5 && receipt.snapshot.history.count == 1)
        #expect(receipt.snapshot.state.processedEvents.isEmpty && receipt.snapshot.state.lastSessionDate == nil)
        #expect(receipt.snapshot.state.activePrescription.exercises.allSatisfy { $0.sets.count == 3 })
        let before = try await repository.exportBackup()
        let secondPreview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        var later = ProgramMigrationDesignFixture.acceptance; later.acceptedAtMilliseconds += 60_000
        let repeated = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: secondPreview.storeFingerprint, acceptance: later)
        #expect(repeated.accepted == 0 && repeated.identical == 1 && repeated.snapshot == receipt.snapshot)
        #expect(try await repository.exportBackup() == before)
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        #expect(try await reopened.snapshot(programID: receipt.programID) == receipt.snapshot)
        #expect(try await reopened.externalSourceArchive(hash: document.source.contentHash) == document.source)
        let portable = try await reopened.exportBackup()
        _ = try BackupService.validate(portable)
        let recovered = try store().0
        #expect(try await recovered.importBackup(portable).accepted == 1)
        #expect(try await recovered.snapshot(programID: receipt.programID) == receipt.snapshot)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(portable).reversed())
        #expect(proof.waiting.isEmpty && proof.quarantined.isEmpty && proof.envelopes.count == 1)
    }
    @Test func sourceTamperingMissingDependencyAndForgedRootCannotWrite() async throws {
        let (repository, _) = try store()
        var document = try ProgramMigrationDesignFixture.make()
        let selection = ProgramMigrationDesignFixture.selection
        let initial = try await repository.exportBackup()
        document.source.files[0].bytes.append(0)
        await #expect(throws: (any Error).self) { try await repository.previewMigration(document: document, selection: selection) }
        #expect(try await repository.exportBackup() == initial)
        document = try ProgramMigrationDesignFixture.make()
        let p = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        _ = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: p.storeFingerprint,
            acceptance: ProgramMigrationDesignFixture.acceptance)
        let backup = try await repository.exportBackup()
        var missing = backup; missing.profiles.removeAll { $0.id == document.source.contentHash }
        #expect(throws: (any Error).self) { try BackupService.validate(missing) }
        let partial = try RecoveryVerifier().verify(BackupService.recoveryRecords(missing))
        #expect(partial.envelopes.isEmpty && !partial.waiting.isEmpty)
        var forged = backup
        var root = try JSONDecoder().decode(JournalEnvelope.self, from: forged.journal[0].bytes)
        root.returnedState.exercises[root.returnedState.config.activeVariantIDs!["suitcase_db_squat"]!]!.load = Load(amount: "80", unit: .lb, basis: .perImplement)
        root.envelopeHash = try BackupService.envelopeHash(root)
        forged.journal[0] = try BackupService.object(root, id: root.eventID)
        forged.heads[root.programID] = root.envelopeHash
        #expect(throws: (any Error).self) { try BackupService.validate(forged) }
        let (destination, _) = try store()
        await #expect(throws: (any Error).self) { try await destination.importBackup(forged) }
        #expect(try await destination.counts() == [0, 0, 0, 0, 0])
    }
    @Test func stalePreviewAndProtectedDraftBlockAndPriorProgramRemainsExportable() async throws {
        let previous = try await RepositoryTestHarness.make(goal: .size)
        let original = try await previous.repository.exportBackup()
        let document = try ProgramMigrationDesignFixture.make()
        let selection = ProgramMigrationDesignFixture.selection
        let preview = try await previous.repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let draft = try await previous.draft(empty: true)
        _ = try await previous.repository.saveDraft(draft)
        let protected = try await previous.repository.exportBackup()
        await #expect(throws: (any Error).self) { try await previous.repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: preview.storeFingerprint, acceptance: ProgramMigrationDesignFixture.acceptance) }
        await #expect(throws: (any Error).self) { try await previous.repository.previewMigration(document: document, selection: selection) }
        #expect(try await previous.repository.exportBackup() == protected)
        try await previous.repository.discardDraft(id: draft.id)
        _ = try await previous.repository.reschedule(programID: previous.programID, expectedRevision: 0,
            slot: WorkoutSlot(date: LocalDate(iso8601: "2026-10-08"), slotID: "THU"))
        let changed = try await previous.repository.exportBackup()
        await #expect(throws: (any Error).self) { try await previous.repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: preview.storeFingerprint, acceptance: ProgramMigrationDesignFixture.acceptance) }
        #expect(try await previous.repository.exportBackup() == changed)
        let fresh = try await previous.repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let receipt = try await previous.repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: fresh.storeFingerprint, acceptance: ProgramMigrationDesignFixture.acceptance)
        let merged = try await previous.repository.exportBackup()
        #expect(merged.heads.count == 2 && merged.formatVersion == 2)
        #expect(original.journal.allSatisfy { merged.journal.contains($0) })
        #expect(try await previous.repository.snapshot(programID: previous.programID).state.revision == 1)
        #expect(receipt.snapshot.externalSource == document.source)
        let (destination, _) = try store()
        _ = try await destination.importBackup(merged)
        #expect(try await destination.exportBackup().heads.count == 2)
        #expect(try await destination.snapshot(programID: receipt.programID) == receipt.snapshot)
    }
}

extension ProgramMigrationRepositoryTests {
    @Test func firstSyntheticNativeWorkoutAdvancesOnceAndSourceRemainsImmutable() async throws {
        let (repository, url) = try store()
        let document = try ProgramMigrationDesignFixture.make()
        let selection = ProgramMigrationDesignFixture.selection
        let preview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let imported = try await repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: preview.storeFingerprint, acceptance: ProgramMigrationDesignFixture.acceptance)
        var event = starterRepositoryEvent(imported.snapshot.state)
        event.timing = SessionTiming(plannedDate: event.date, startedAtMilliseconds: 1_791_316_800_000,
            finishedAtMilliseconds: 1_791_317_400_000, timeZoneID: "Pacific/Honolulu")
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU")
        let finished = try await repository.finalize(programID: imported.programID, expectedRevision: 0, event: event, next: next)
        #expect(finished.snapshot.state.revision == 1)
        let trainedID = imported.snapshot.state.config.activeVariantIDs!["suitcase_db_squat"]!
        #expect(finished.snapshot.state.exercises[trainedID]?.exactRepState?.normalTargets != imported.snapshot.state.exercises[trainedID]?.exactRepState?.normalTargets)
        #expect(finished.snapshot.state.exercises[trainedID]?.recentComparable.count == 1)
        #expect(finished.snapshot.history.count == 2)
        #expect(finished.snapshot.externalSource == document.source)
        #expect(finished.snapshot.state.activePrescription.slotID == "THU")
        let original = try await repository.exportBackup()
        var laterAcceptance = ProgramMigrationDesignFixture.acceptance
        laterAcceptance.acceptedAtMilliseconds += 7 * 24 * 60 * 60 * 1000
        let repeatPreview = try await repository.previewMigration(document: document, selection: selection, acceptance: laterAcceptance)
        #expect(repeatPreview.state == finished.snapshot.state && repeatPreview.proposedAcceptance == ProgramMigrationDesignFixture.acceptance)
        let repeatImport = try await repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: repeatPreview.storeFingerprint, acceptance: laterAcceptance)
        #expect(repeatImport.accepted == 0 && repeatImport.identical == 1 && repeatImport.snapshot == finished.snapshot)
        #expect(try await repository.exportBackup() == original)
        let repeated = try await repository.finalize(programID: imported.programID, expectedRevision: 0, event: event, next: next)
        #expect(repeated.snapshot == finished.snapshot)
        #expect(try await repository.exportBackup() == original)
        await repository.close()
        let reopened = try TrainingRepository.open(at: url)
        #expect(try await reopened.snapshot(programID: imported.programID) == finished.snapshot)
        _ = try BackupService.validate(await reopened.exportBackup())
        let (restored, _) = try store()
        _ = try await restored.importBackup(original)
        #expect(try await restored.snapshot(programID: imported.programID) == finished.snapshot)
    }
    @MainActor @Test func previewLoadConsentAdoptionAndPersistedSelectionUseSameNativePath() async throws {
        let previous = try await RepositoryTestHarness.make(goal: .size)
        let clock = MigrationDesignClock(Date(timeIntervalSince1970: Double(ProgramMigrationDesignFixture.acceptance.acceptedAtMilliseconds) / 1000))
        let model = WorkoutViewModel(repository: previous.repository, snapshot: try await previous.repository.snapshot(programID: previous.programID), timeZoneID: "Pacific/Honolulu", now: { clock.date })
        let prefs = previous.storeURL.deletingLastPathComponent().appendingPathComponent("product-preferences.json")
        let app = AppComposition(repository: previous.repository, workout: model, preferencesURL: prefs)
        app.timeZoneID = "Pacific/Honolulu"
        app.now = { clock.date }
        let document = try ProgramMigrationDesignFixture.make(unresolvedLoad: true)
        let noBasis = ProgramMigrationDesignFixture.selection
        await #expect(throws: (any Error).self) { try await app.previewMigration(document: document, selection: noBasis) }
        var wrong = noBasis
        wrong.confirmedLoads["db_triceps_extension"] = Load(amount: "25", unit: .lb, basis: .perImplement)
        await #expect(throws: (any Error).self) { try await app.previewMigration(document: document, selection: wrong) }
        let native = try selectFixedProgram(goal: noBasis.goal, programID: UUID()).movements.first { $0.id == "db_triceps_extension" }!
        var selection = noBasis
        selection.confirmedLoads["db_triceps_extension"] = native.availableLoads.first { $0.amount == "25" }!
        let preview = try await app.previewMigration(document: document, selection: selection)
        let receipt = try await app.importMigration(document: document, selection: selection, preview: preview)
        #expect(app.workout === model)
        #expect(try await previous.repository.exportBackup().heads.count == 2)
        try await app.adoptMigration(receipt)
        #expect(app.workout?.programID == receipt.programID)
        #expect(app.workout?.snapshot.externalSource == document.source)
        let restart = AppComposition(repository: previous.repository, preferencesURL: prefs)
        restart.now = app.now; restart.timeZoneID = app.timeZoneID
        try await restart.reloadLocalProductChoices()
        #expect(restart.workout?.programID == receipt.programID)
        let current = try #require(restart.workout)
        #expect(current.canOfferEasierWorkout)
        let before = current.snapshot.state.activePrescription
        try await current.prepareToday()
        #expect(current.snapshot.state.activePrescription == before)
        clock.date = Date(timeIntervalSince1970: 1_791_136_800)
        await #expect(throws: (any Error).self) { try await current.start(easierToday: false) }
        clock.date = Date(timeIntervalSince1970: Double(ProgramMigrationDesignFixture.acceptance.acceptedAtMilliseconds) / 1000)
        try await current.start(easierToday: false)
        #expect(current.snapshot.draft?.date.iso8601 == "2026-10-05")
        #expect(current.snapshot.draft?.logs.allSatisfy { $0.actualSets.isEmpty && $0.effortScope == .allWorkingSets } == true)
        await #expect(throws: (any Error).self) { try await app.adoptMigration(receipt) }
        await #expect(throws: (any Error).self) { try await current.changeStarterProgram(choice: .upperBody, goal: .size) }
    }
}

extension ProgramMigrationRepositoryTests {
    @Test func occupiedDeterministicProgramIdentityRejectsWithoutOverwriting() async throws {
        let (repository, _) = try store()
        let document = try ProgramMigrationDesignFixture.make()
        let selection = ProgramMigrationDesignFixture.selection
        let candidate = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let ordinary = try selectFixedProgram(goal: .size, programID: candidate.programID)
        _ = try await repository.initialize(config: ordinary, rules: RulesetCatalog.fixedV1(), firstWorkout: document.checkpoint.nextWorkout)
        let occupied = try await repository.exportBackup()
        await #expect(throws: (any Error).self) { try await repository.previewMigration(document: document, selection: selection) }
        await #expect(throws: (any Error).self) { try await repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: BackupService.migrationStoreFingerprint(occupied), acceptance: ProgramMigrationDesignFixture.acceptance) }
        #expect(try await repository.exportBackup() == occupied)
    }
}

extension ProgramMigrationRepositoryTests {
    @MainActor @Test func priorPauseReserveAndDormantFamilyCannotBeBypassedByAdoption() async throws {
        for restriction in 0..<3 {
            let repository: TrainingRepository
            let previousID: UUID
            if restriction == 2 {
                let previous = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
                repository = previous.repository; previousID = previous.programID
                _ = try await repository.applyConfiguration(programID: previousID, expectedRevision: 0,
                    change: .minimumRir(baseMovementID: "banded_pullups", value: 4),
                    next: WorkoutSlot(date: LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
                _ = try await previous.change(.wholeBodyGlutes)
                #expect(try await repository.snapshot(programID: previousID).state.retainedSafety?["pull_up"]?.minimumRir == 4)
            } else {
                let previous = try await RepositoryTestHarness.make(goal: .size)
                repository = previous.repository; previousID = previous.programID
                if restriction == 0 {
                    var event = previous.firstEvent
                    event.exercises[0].status = .stopped; event.exercises[0].problem = .pain; event.exercises[0].finalEffort = .unknown
                    _ = try await repository.finalize(programID: previousID, expectedRevision: 0, event: event, next: previous.next)
                } else {
                    _ = try await repository.applyConfiguration(programID: previousID, expectedRevision: 0,
                        change: .minimumRir(baseMovementID: "db_lateral_raise", value: 4), next: previous.next)
                }
            }
            let model = WorkoutViewModel(repository: repository, snapshot: try await repository.snapshot(programID: previousID), timeZoneID: "Pacific/Honolulu")
            let app = AppComposition(repository: repository, workout: model)
            app.timeZoneID = "Pacific/Honolulu"
            app.now = { Date(timeIntervalSince1970: Double(ProgramMigrationDesignFixture.acceptance.acceptedAtMilliseconds) / 1000) }
            let document = try ProgramMigrationDesignFixture.make(), selection = ProgramMigrationDesignFixture.selection
            let preview = try await app.previewMigration(document: document, selection: selection)
            let receipt = try await app.importMigration(document: document, selection: selection, preview: preview)
            let before = try await repository.exportBackup()
            await #expect(throws: (any Error).self) { try await app.adoptMigration(receipt) }
            await #expect(throws: (any Error).self) { try await app.selectRecoveryProgram(receipt.programID.uuidString.lowercased()) }
            #expect(app.workout === model)
            #expect(try await repository.exportBackup() == before)
            #expect(receipt.snapshot.externalSource == document.source)
        }
    }
}

extension ProgramMigrationRepositoryTests {
    @MainActor @Test func selectedFileWithUnrecognizedExtraDataRejectsBeforePreviewOrWrite() async throws {
        let (repository, _) = try store()
        let app = AppComposition(repository: repository)
        let document = try ProgramMigrationDesignFixture.make()
        let good = try BackupService.bytes(document)
        #expect(try await app.decodeMigrationData(good) == document)
        var fields = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        fields["unrecognizedHistory"] = ["raw": "Synthetic extra source payload must not vanish"]
        let extra = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let before = try await repository.exportBackup()
        await #expect(throws: (any Error).self) { try await app.decodeMigrationData(extra) }
        #expect(try await repository.exportBackup() == before)
    }
}

extension ProgramMigrationRepositoryTests {
    @MainActor @Test func requiredRecoveryIsFreshDurableAndFrozenIntoNativeFinish() async throws {
        let (repository, _) = try store()
        let document = try ProgramMigrationDesignFixture.make(recoveryRequired: true), selection = ProgramMigrationDesignFixture.selection
        let preview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let receipt = try await repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: preview.storeFingerprint, acceptance: ProgramMigrationDesignFixture.acceptance)
        let model = WorkoutViewModel(repository: repository, snapshot: receipt.snapshot, timeZoneID: "Pacific/Honolulu",
            now: { Date(timeIntervalSince1970: Double(ProgramMigrationDesignFixture.acceptance.acceptedAtMilliseconds) / 1000) })
        try await model.start(easierToday: false)
        let row = try #require(model.snapshot.draft?.displayed.exercises.first)
        let load = try #require(row.load)
        try await model.confirmLoad(movementID: row.movementID, load: load)
        #expect(model.requiresMigrationRecovery(row.movementID) && !model.migrationRecoveryConfirmed(row.movementID))
        await #expect(throws: (any Error).self) { try await model.beginMovement(movementID: row.movementID) }
        await #expect(throws: (any Error).self) { try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 11)) }
        try await model.confirmMigrationRecovery(movementID: row.movementID)
        let attestation = try #require(model.snapshot.draft?.migrationRecoveryAttestations?.first)
        #expect(attestation.externalArchiveHash == document.source.contentHash)
        try await model.beginMovement(movementID: row.movementID)
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 11))
        var revoked = try #require(model.snapshot.draft); revoked.migrationRecoveryAttestations = nil
        await #expect(throws: (any Error).self) { try await repository.saveDraft(revoked) }
        try await model.recordProblem(movementID: row.movementID, problem: .pain)
        for other in model.snapshot.draft!.displayed.exercises where !model.handled(other.movementID) { try await model.recordStatus(movementID: other.movementID, status: .skipped) }
        try await model.confirmHandledSummariesForTesting()
        var forged = try #require(model.snapshot.draft)
        var event = CompletedWorkout(eventID: forged.id.uuidString.lowercased(), date: forged.date, slotID: forged.displayed.slotID,
            prescriptionID: forged.displayed.id, plannedPrescriptionID: forged.planned.id, sessionMode: forged.sessionMode,
            exercises: forged.logs, observationAudit: forged.observationAudit)
        event.timing = SessionTiming(plannedDate: forged.planned.date, startedAtMilliseconds: forged.startedAtMilliseconds!,
            finishedAtMilliseconds: ProgramMigrationDesignFixture.acceptance.acceptedAtMilliseconds, timeZoneID: forged.timeZoneID)
        let next = try WorkoutScheduler.nextRotation(after: max(forged.date, forged.planned.date), consumedSlotID: forged.planned.slotID, config: model.snapshot.state.config)
        forged.pendingFinish = PendingWorkoutFinish(event: event, next: next, expectedRevision: forged.expectedRevision)
        #expect(throws: (any Error).self) { try WorkoutFlowResolver.validate(forged) }
        forged.pendingFinish!.event.migrationRecoveryAttestations = [attestation]
        try WorkoutFlowResolver.validate(forged)
        let finished = try await model.finish()
        #expect(finished.snapshot.history.last?.command == model.completedEnvelope?.command)
        if let envelope = finished.snapshot.history.last, case let .workout(event, _) = envelope.command {
            #expect(event.migrationRecoveryAttestations == [attestation])
        } else { Issue.record("Expected a native workout root descendant") }
        #expect(finished.snapshot.externalSource?.baselines.first { $0.baseMovementID == row.baseMovementID }?.recoveryStatus == "unknown")
        _ = try BackupService.validate(await repository.exportBackup())
    }
    @MainActor @Test func unconfirmedStoppedRawObservationIsRetainedWithoutRecoveryCredit() async throws {
        let (repository, _) = try store()
        let document = try ProgramMigrationDesignFixture.make(recoveryRequired: true), selection = ProgramMigrationDesignFixture.selection
        let preview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let receipt = try await repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: preview.storeFingerprint, acceptance: ProgramMigrationDesignFixture.acceptance)
        let model = WorkoutViewModel(repository: repository, snapshot: receipt.snapshot, timeZoneID: "Pacific/Honolulu",
            now: { Date(timeIntervalSince1970: Double(ProgramMigrationDesignFixture.acceptance.acceptedAtMilliseconds) / 1000) })
        try await model.start(easierToday: false)
        let row = try #require(model.snapshot.draft?.displayed.exercises.first)
        try await model.recordProblem(movementID: row.movementID, problem: .pain, pendingActual: ActualSet(reps: 4))
        #expect(model.snapshot.draft?.logs.first?.actualSets.first?.reps == 4)
        #expect(model.snapshot.draft?.migrationRecoveryAttestations == nil)
        for other in model.snapshot.draft!.displayed.exercises where !model.handled(other.movementID) { try await model.recordStatus(movementID: other.movementID, status: .skipped) }
        try await model.confirmHandledSummariesForTesting()
        let finished = try await model.finish()
        #expect(finished.snapshot.state.exercises[row.movementID]?.mode == .paused)
        #expect(finished.snapshot.state.exercises[row.movementID]?.recentComparable.isEmpty == true)
        if let envelope = finished.snapshot.history.last, case let .workout(event, _) = envelope.command {
            #expect(event.migrationRecoveryAttestations == nil)
            #expect(event.exercises.first?.actualSets.first?.reps == 4)
        } else { Issue.record("Expected retained stopped workout") }
        _ = try BackupService.validate(await repository.exportBackup())
    }
}

extension ProgramMigrationRepositoryTests {
    @MainActor @Test func largeImmutableSourceDoesNotReenterMovementPresentationLookup() async throws {
        let (repository, _) = try store()
        let document = try ProgramMigrationDesignFixture.make(paddingByteCount: 4_500_000)
        let start = ProcessInfo.processInfo.systemUptime
        let preview = try previewProgramMigration(document: document, selection: ProgramMigrationDesignFixture.selection,
            acceptance: ProgramMigrationDesignFixture.acceptance, programID: UUID())
        let admissionSeconds = ProcessInfo.processInfo.systemUptime - start
        let snapshot = StoreSnapshot(state: preview.initialized.state, draft: nil, history: [], decisions: [], health: .ready, externalSource: document.source)
        let model = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu")
        let row = try #require(snapshot.state.activePrescription.exercises.first)
        let lookupStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<10_000 { _ = model.movement(for: row) }
        #expect(model.movement(for: row).id == row.baseMovementID)
        #expect(model.movementPresentationResolutionCount == 1)
        print("SYNTHETIC LARGE SOURCE bytes=\(document.source.files[0].bytes.count) admissionSeconds=\(admissionSeconds) cachedLookup10000Seconds=\(ProcessInfo.processInfo.systemUptime - lookupStart)")
    }
}

extension ProgramMigrationRepositoryTests {
    @Test func directMigratedCompletionCannotBypassPriorReserveButRawPartialCanRemain() async throws {
        let previous = try await RepositoryTestHarness.make(goal: .size)
        _ = try await previous.repository.applyConfiguration(programID: previous.programID, expectedRevision: 0,
            change: .minimumRir(baseMovementID: "suitcase_db_squat", value: 4), next: previous.next)
        let document = try ProgramMigrationDesignFixture.make(), selection = ProgramMigrationDesignFixture.selection
        let preview = try await previous.repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let receipt = try await previous.repository.importMigration(document: document, selection: selection,
            expectedStoreFingerprint: preview.storeFingerprint, acceptance: ProgramMigrationDesignFixture.acceptance)
        var event = starterRepositoryEvent(receipt.snapshot.state)
        event.timing = SessionTiming(plannedDate: event.date, startedAtMilliseconds: 1_791_316_800_000,
            finishedAtMilliseconds: 1_791_317_400_000, timeZoneID: "Pacific/Honolulu")
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-08"), slotID: "THU")
        let before = try await previous.repository.exportBackup()
        let rejected = try await previous.repository.finalize(programID: receipt.programID, expectedRevision: 0, event: event, next: next)
        if case let .rejected(_, errors) = rejected.result { #expect(errors.contains("retained_safety_restriction")) }
        else { Issue.record("Direct completion must not bypass another root's stronger reserve") }
        #expect(try await previous.repository.exportBackup() == before)
        for i in event.exercises.indices {
            event.exercises[i].status = .skipped; event.exercises[i].actualSets = []; event.exercises[i].finalEffort = .unknown
            event.exercises[i].skippedSetIndices = Array(receipt.snapshot.state.activePrescription.exercises[i].sets.indices)
        }
        event.exercises[0].status = .partial
        event.exercises[0].actualSets = [ActualSet(reps: 4, setIndex: 0, missedGoalReason: .effortLimit)]
        event.exercises[0].skippedSetIndices = [1, 2]
        let retained = try await previous.repository.finalize(programID: receipt.programID, expectedRevision: 0, event: event, next: next)
        #expect(retained.snapshot.state.revision == 1)
        let id = receipt.snapshot.state.config.activeVariantIDs!["suitcase_db_squat"]!
        #expect(retained.snapshot.state.exercises[id]?.exactRepState?.normalTargets == receipt.snapshot.state.exercises[id]?.exactRepState?.normalTargets)
        #expect(retained.snapshot.externalSource == document.source)
    }
}

extension ProgramMigrationRepositoryTests {
    @Test func warmSourceRootCacheRejectsChangedBytesKindsDependenciesAndOutputs() async throws {
        let (repository, _) = try store()
        let document = try ProgramMigrationDesignFixture.make(), selection = ProgramMigrationDesignFixture.selection
        let preview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        _ = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: preview.storeFingerprint,
            acceptance: ProgramMigrationDesignFixture.acceptance)
        let original = try await repository.exportBackup()
        let admittedRoot = try JSONDecoder().decode(JournalEnvelope.self, from: original.journal[0].bytes)
        let cache = MigrationAdmissionCache()
        _ = try BackupService.validate(original, migrationCache: cache)
        _ = try BackupService.validate(original, migrationCache: cache)
        let index = try #require(original.profiles.firstIndex { $0.id == document.source.contentHash })
        var bytesChanged = original
        bytesChanged.profiles[index].bytes.append(0)
        bytesChanged.profiles[index].checksum = BackupService.hash(bytesChanged.profiles[index].bytes)
        #expect(throws: (any Error).self) { try BackupService.validate(bytesChanged, migrationCache: cache) }
        var missing = original; missing.profiles.remove(at: index)
        #expect(throws: (any Error).self) { try BackupService.validate(missing, migrationCache: cache) }
        var changedKind = original
        var source = document.source; source.archiveKind = "unknown-external-source-v2"
        source.contentHash = try migrationHash(source, excluding: "contentHash")
        changedKind.profiles[index] = try BackupService.object(source, id: source.contentHash)
        #expect(throws: (any Error).self) { try BackupService.validate(changedKind, migrationCache: cache) }
        var forged = original
        var root = try JSONDecoder().decode(JournalEnvelope.self, from: forged.journal[0].bytes)
        root.returnedState.exercises[root.returnedState.config.activeVariantIDs!["suitcase_db_squat"]!]!.normalSets = 2
        root.envelopeHash = try BackupService.envelopeHash(root)
        forged.journal[0] = try BackupService.object(root, id: root.eventID); forged.heads[root.programID] = root.envelopeHash
        #expect(throws: (any Error).self) { try BackupService.validate(forged, migrationCache: cache) }
        for category in ["rules", "profile", "sourceProfile"] {
            var bad = original
            if category == "rules" { bad.rules[0].bytes.append(0); bad.rules[0].checksum = BackupService.hash(bad.rules[0].bytes) }
            else {
                let hash = category == "profile" ? admittedRoot.profileHash : admittedRoot.sourceProfileHash
                let dependency = try #require(bad.profiles.firstIndex { $0.id == hash })
                bad.profiles[dependency].bytes.append(0); bad.profiles[dependency].checksum = BackupService.hash(bad.profiles[dependency].bytes)
            }
            #expect(throws: (any Error).self) { try BackupService.validate(bad, migrationCache: cache) }
        }
        #expect(try BackupService.validate(original, migrationCache: cache).heads.values.first?.returnedState == admittedRoot.returnedState)
        let incomplete = try RecoveryVerifier().verify(BackupService.recoveryRecords(missing), migrationCache: cache)
        #expect(incomplete.envelopes.isEmpty && !incomplete.waiting.isEmpty)
        #expect(try await repository.exportBackup() == original)
    }
    @Test func cloudWorkoutCoverageRequiresItsMigratedRootSourceArchive() async throws {
        let (repository, _) = try store()
        let document = try ProgramMigrationDesignFixture.make(), selection = ProgramMigrationDesignFixture.selection
        let preview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let imported = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: preview.storeFingerprint,
            acceptance: ProgramMigrationDesignFixture.acceptance)
        var event = starterRepositoryEvent(imported.snapshot.state)
        event.timing = SessionTiming(plannedDate: event.date, startedAtMilliseconds: 1_791_316_800_000,
            finishedAtMilliseconds: 1_791_317_400_000, timeZoneID: "Pacific/Honolulu")
        _ = try await repository.finalize(programID: imported.programID, expectedRevision: 0, event: event,
            next: WorkoutSlot(date: LocalDate(iso8601: "2026-10-08"), slotID: "THU"))
        let backup = try await repository.exportBackup()
        try await repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: recoveryScope)
        let pending = try await repository.pendingCloudRecords(scope: recoveryScope)
        let source = try #require(pending.first { $0.identity == document.source.contentHash })
        for record in pending where record.recordID != source.recordID {
            try await repository.acknowledge(records: [.init(recordID: record.recordID, verifiedHash: record.checksum, systemFields: Data())], scope: recoveryScope)
        }
        let incomplete = try await repository.cloudStatus(scope: recoveryScope)
        #expect(incomplete.acknowledgedCompletedWorkoutCount == 0 && incomplete.pendingCompletedWorkoutCount == 1)
        try await repository.acknowledge(records: [.init(recordID: source.recordID, verifiedHash: source.checksum, systemFields: Data())], scope: recoveryScope)
        let complete = try await repository.cloudStatus(scope: recoveryScope)
        #expect(complete.acknowledgedCompletedWorkoutCount == 1 && complete.pendingCompletedWorkoutCount == 0)
    }
}

extension ProgramMigrationRepositoryTests {
    @MainActor @Test func largeSourceWarmSnapshotAndSyntheticDraftWriteRemainBounded() async throws {
        let (repository, _) = try store()
        let document = try ProgramMigrationDesignFixture.make(paddingByteCount: 4_500_000), selection = ProgramMigrationDesignFixture.selection
        let preview = try await repository.previewMigration(document: document, selection: selection, acceptance: ProgramMigrationDesignFixture.acceptance)
        let receipt = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: preview.storeFingerprint,
            acceptance: ProgramMigrationDesignFixture.acceptance)
        let warmStart = ProcessInfo.processInfo.systemUptime
        #expect(try await repository.snapshot(programID: receipt.programID) == receipt.snapshot)
        let warmSeconds = ProcessInfo.processInfo.systemUptime - warmStart
        let proofStart = ProcessInfo.processInfo.systemUptime
        let proof = try await repository.verifiedRecoveryProof()
        #expect(proof.envelopes.count == 1 && proof.waiting.isEmpty && proof.quarantined.isEmpty)
        let proofSeconds = ProcessInfo.processInfo.systemUptime - proofStart
        let model = WorkoutViewModel(repository: repository, snapshot: receipt.snapshot, timeZoneID: "Pacific/Honolulu",
            now: { Date(timeIntervalSince1970: Double(ProgramMigrationDesignFixture.acceptance.acceptedAtMilliseconds) / 1000) })
        let startTime = ProcessInfo.processInfo.systemUptime
        try await model.start(easierToday: false)
        let startSeconds = ProcessInfo.processInfo.systemUptime - startTime
        let row = try #require(model.snapshot.draft?.displayed.exercises.first)
        try await model.confirmLoad(movementID: row.movementID, load: row.load!)
        let writeStart = ProcessInfo.processInfo.systemUptime
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 11))
        let writeSeconds = ProcessInfo.processInfo.systemUptime - writeStart
        #expect(model.snapshot.draft?.logs.first?.actualSets.first?.reps == 11)
        #expect(warmSeconds < 5 && proofSeconds < 5 && startSeconds < 5 && writeSeconds < 5)
        print("SYNTHETIC SOURCE REPOSITORY bytes=\(document.source.files[0].bytes.count) warmSnapshotSeconds=\(warmSeconds) recoveryProofSeconds=\(proofSeconds) startSeconds=\(startSeconds) draftSetWriteSeconds=\(writeSeconds)")
    }
}

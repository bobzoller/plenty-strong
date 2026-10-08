import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

let recoveryScope = CloudScope(containerIdentifier: "synthetic.container", environment: .development, accountIdentifier: "synthetic-A")

func recoveryRecords(_ repository: TrainingRepository) async throws -> [DownloadedCloudRecord] {
    let backup = try await repository.exportBackup()
    try await repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: recoveryScope)
    return try await repository.pendingCloudRecords(scope: recoveryScope).map {
        DownloadedCloudRecord(observation: CloudObservation(recordID: $0.recordID,
            zoneName: CloudRecordCodec.zoneID($0.datasetID).zoneName, recordType: $0.kind.recordType,
            claimedChecksum: $0.checksum, payload: $0.payload, systemFields: Data()))
    }
}
func recoveryEmpty() throws -> (TrainingRepository, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("training.store")
    return (try TrainingRepository.open(at: url), url)
}

struct CloudRecoveryTests {
    @Test func unparseableOriginalIsAttributedOnlyToExactVerifiedSourceIdentity() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let records = try await recoveryRecords(source.repository)
        let original = records.first { $0.observation.recordType == CloudRecordKind.journal.recordType }!.observation
        let bytes = Data(original.payload.dropLast(9))
        let bad = ArchivedRecord(observation: CloudObservation(recordID: original.recordID, zoneName: original.zoneName,
            recordType: original.recordType, claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
        let good = records.map { ArchivedRecord(observation: $0.observation) }
        let associated = try RecoveryVerifier().verify(good + [bad])
        #expect(associated.quarantined.first { $0.record == bad }!.programID == source.programID.uuidString.lowercased())
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: original.payload) else { throw BackupService.invalid("fixture_root") }
        fields["programId"] = .string(UUID().uuidString.lowercased())
        let falseClaimBytes = try CanonicalJSON.encode(.object(fields))
        let falseClaim = ArchivedRecord(observation: CloudObservation(recordID: original.recordID, zoneName: original.zoneName,
            recordType: original.recordType, claimedChecksum: BackupService.hash(falseClaimBytes), payload: falseClaimBytes, systemFields: Data()))
        #expect(try RecoveryVerifier().verify(good + [falseClaim]).quarantined.first { $0.record == falseClaim }!.programID == source.programID.uuidString.lowercased())
        let archive = records.first { $0.observation.recordType == CloudRecordKind.archive.recordType }!.observation
        guard case .object(var archiveFields) = try JSONDecoder().decode(CanonicalValue.self, from: archive.payload) else { throw BackupService.invalid("fixture_archive") }
        let fakeProgram = UUID().uuidString.lowercased()
        archiveFields["programId"] = .string(fakeProgram)
        let archiveBytes = try CanonicalJSON.encode(.object(archiveFields))
        let archiveClaim = ArchivedRecord(observation: CloudObservation(recordID: archive.recordID, zoneName: archive.zoneName,
            recordType: archive.recordType, claimedChecksum: BackupService.hash(archiveBytes), payload: archiveBytes, systemFields: Data()))
        #expect(try RecoveryVerifier().verify(good + [archiveClaim]).quarantined.first { $0.record == archiveClaim }!.programID == nil)
        _ = try await source.repository.ingestCloud(RecoveryVerifier().verify([archiveClaim]), scope: recoveryScope)
        #expect(try await source.repository.recoveryPrograms().allSatisfy { $0.programID != fakeProgram })
        let otherName = try CloudRecordCodec.recordName(kind: .journal,
            datasetID: UUID(uuidString: String(original.zoneName.dropFirst(CloudRecordCodec.zonePrefix.count)))!, identity: UUID().uuidString.lowercased())
        for dimension in ["zone", "type", "name"] {
            let unrelated = ArchivedRecord(observation: CloudObservation(
                recordID: dimension == "name" ? otherName : original.recordID,
                zoneName: dimension == "zone" ? CloudRecordCodec.zoneID(UUID()).zoneName : original.zoneName,
                recordType: dimension == "type" ? CloudRecordKind.archive.recordType : original.recordType,
                claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
            #expect(try RecoveryVerifier().verify(good + [unrelated]).quarantined.first { $0.record == unrelated }!.programID == nil)
        }
    }
    @Test func shuffledRecoveryWaitsForArchivesThenReplaysExactOriginalsWithoutUploadLoop() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        let records = try await recoveryRecords(source.repository)
        let (destination, url) = try recoveryEmpty()
        let ingestor = CloudIngestor(repository: destination)
        let events = records.filter { $0.observation.recordType == CloudRecordKind.journal.recordType }
        let waiting = try await ingestor.ingest(events.reversed(), scope: recoveryScope)
        #expect(waiting.accepted == 0)
        #expect(waiting.waitingForDependencies == 2)
        #expect(waiting.health == .incompleteRecovery)
        let complete = try await ingestor.ingest(records.reversed(), scope: recoveryScope)
        #expect(complete.waitingForDependencies == 0)
        #expect(complete.health == .ready)
        #expect(try await destination.snapshot(programID: source.programID) == source.repository.snapshot(programID: source.programID))
        #expect(try await destination.pendingCloudRecords(scope: recoveryScope).isEmpty)
        let repeated = try await ingestor.ingest(records, scope: recoveryScope)
        #expect(repeated.accepted == 0 && repeated.identical == records.count)
        let backup = try await destination.exportBackup()
        await destination.close()
        let reopened = try TrainingRepository.open(at: url)
        #expect(try await reopened.exportBackup() == backup)
    }
}

extension CloudRecoveryTests {
    @Test func malformedTamperedAndNewerRecordsPreserveAcceptedStateAndAllOriginals() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let records = try await recoveryRecords(source.repository)
        let root = records.first { $0.observation.recordType == CloudRecordKind.journal.recordType }!.observation
        let original = try await source.repository.snapshot(programID: source.programID).state
        var variants: [DownloadedCloudRecord] = []
        for mode in 0..<3 {
            var bytes = root.payload
            if mode == 0 { bytes.removeLast(9) }
            if mode == 1 { bytes.append(0) }
            if mode == 2 {
                var fields = try JSONDecoder().decode(CanonicalValue.self, from: bytes)
                if case .object(var object) = fields { object["schemaVersion"] = .integer(99); fields = .object(object) }
                bytes = try CanonicalJSON.encode(fields)
            }
            variants.append(DownloadedCloudRecord(observation: CloudObservation(recordID: root.recordID, zoneName: root.zoneName,
                recordType: root.recordType, claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data())))
        }
        let result = try await CloudIngestor(repository: source.repository).ingest(variants, scope: recoveryScope)
        #expect(result.quarantined == 4)
        let snapshot = try await source.repository.snapshot(programID: source.programID)
        #expect(snapshot.state == original)
        #expect(snapshot.health == .unsupportedVersion)
        let backup = try await source.repository.exportBackup()
        #expect(variants.allSatisfy { variant in backup.recovery!.originals.contains { $0.bytes == variant.observation.payload } })
        #expect(backup.recovery!.quarantines.count == 4)
    }
    @Test func missingCreationDependencyAndModifiedDescriptionsRestoreExactly() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let base = "banded_pullups"
        let initial = try await source.repository.snapshot(programID: source.programID)
        let slot = WorkoutSlot(date: initial.state.activePrescription.date, slotID: initial.state.activePrescription.slotID)
        _ = try await source.repository.applyVariantChange(programID: source.programID, expectedRevision: 0,
            change: .create(baseMovementID: base, variantID: "same-label-A", modifications: "+25 lb"), next: slot)
        let modified = try await source.repository.snapshot(programID: source.programID)
        let completedEvent = RepositoryTestHarness.event(state: modified.state)
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 1, event: completedEvent, next: source.next)
        _ = try await source.repository.applyVariantChange(programID: source.programID, expectedRevision: 2,
            change: .create(baseMovementID: base, variantID: "same-label-B", modifications: "+25 lb"), next: source.next)
        _ = try await source.repository.applyVariantChange(programID: source.programID, expectedRevision: 3,
            change: .correctDescription(variantID: "same-label-A", modifications: "Corrected words"), next: source.next)
        let expected = try await source.repository.snapshot(programID: source.programID)
        let records = try await recoveryRecords(source.repository)
        let missing = records.first { record in
            guard let envelope = try? JSONDecoder().decode(JournalEnvelope.self, from: record.observation.payload) else { return false }
            return envelope.returnedState.revision == 1
        }!
        let (fresh, _) = try recoveryEmpty()
        let partial = try await CloudIngestor(repository: fresh).ingest(records.filter { $0.recordID != missing.recordID }.reversed(), scope: recoveryScope)
        #expect(partial.health == .incompleteRecovery)
        let completed = try await CloudIngestor(repository: fresh).ingest([missing], scope: recoveryScope)
        #expect(completed.health == .ready)
        #expect(try await fresh.snapshot(programID: source.programID) == expected)
        #expect(expected.state.exercises["same-label-A"]!.load == nil && expected.state.exercises["same-label-B"]!.load == nil)
        #expect(expected.state.config.activeVariantIDs![base] == "same-label-B")
        #expect(expected.state.exercises["same-label-A"]!.mode == .normal)
        #expect(expected.state.exercises["same-label-B"]!.mode == .baseline)
        #expect(completedEvent.exercises.first { $0.movementID == "same-label-A" }!.modificationsSnapshot == "+25 lb")
        if case let .workout(event, _) = expected.history[2].command {
            #expect(event == completedEvent)
        } else { Issue.record("Original variant observation missing") }
        #expect(expected.history[1].returnedState.config.variants!["same-label-A"]!.modifications == "+25 lb")
        #expect(expected.state.config.variants!["same-label-A"]!.modifications == "Corrected words")
    }
    @Test func failedSingleWriterCommitRollsBackAndAnotherAccountCannotAdoptDataset() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let records = try await recoveryRecords(source.repository)
        let (fresh, _) = try recoveryEmpty()
        let proof = try RecoveryVerifier().verify(records.map { ArchivedRecord(observation: $0.observation) })
        await fresh.failNextSave()
        await #expect(throws: (any Error).self) { try await fresh.ingestCloud(proof, scope: recoveryScope) }
        #expect(try await fresh.counts() == [0, 0, 0, 0, 0])
        _ = try await fresh.ingestCloud(proof, scope: recoveryScope)
        let before = try await fresh.exportBackup()
        let other = CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B")
        await #expect(throws: (any Error).self) { try await fresh.ingestCloud(proof, scope: other) }
        #expect(try await fresh.exportBackup() == before)
        #expect(try await fresh.pendingCloudRecords(scope: other).isEmpty)
        let changed = records.first { $0.observation.recordType == CloudRecordKind.journal.recordType }!.observation
        try await fresh.retainCloudObservations([CloudObservation(recordID: changed.recordID, zoneName: changed.zoneName,
            recordType: changed.recordType, claimedChecksum: changed.claimedChecksum, payload: changed.payload + Data([0]), systemFields: Data([1]))], scope: recoveryScope)
        #expect(try await fresh.cloudMetadata(scope: recoveryScope).conflictingRecordIDs.contains(changed.recordID))
    }
}

extension CloudRecoveryTests {
    @Test func independentDatasetsCoexistAndInvalidOtherProgramDoesNotFreezeTraining() async throws {
        let a = try await RepositoryTestHarness.make(goal: .size), b = try await RepositoryTestHarness.make(goal: .strength)
        let aRecords = try await recoveryRecords(a.repository), bRecords = try await recoveryRecords(b.repository)
        let (fresh, _) = try recoveryEmpty()
        _ = try await CloudIngestor(repository: fresh).ingest((aRecords + bRecords).shuffled(), scope: recoveryScope)
        #expect(try await fresh.snapshot(programID: a.programID) == a.repository.snapshot(programID: a.programID))
        #expect(try await fresh.snapshot(programID: b.programID) == b.repository.snapshot(programID: b.programID))
        let backup = try await fresh.exportBackup()
        #expect(backup.formatVersion == 2 && backup.recovery!.rootDatasets.count == 2)
        #expect(Set(backup.recovery!.rootDatasets.values).count == 2)
        #expect(try await fresh.pendingCloudRecords(scope: recoveryScope).isEmpty)
        let original = aRecords.first { $0.observation.recordType == CloudRecordKind.journal.recordType }!.observation
        let invalid = DownloadedCloudRecord(observation: CloudObservation(recordID: original.recordID, zoneName: original.zoneName,
            recordType: original.recordType, claimedChecksum: original.claimedChecksum, payload: original.payload + Data([0]), systemFields: Data()))
        _ = try await CloudIngestor(repository: fresh).ingest([invalid], scope: recoveryScope)
        #expect(try await fresh.snapshot(programID: a.programID).health == .integrityConflict)
        #expect(try await fresh.snapshot(programID: b.programID).health == .ready)
        let receipt = try await fresh.finalize(programID: b.programID, expectedRevision: 0, event: b.firstEvent, next: b.next)
        guard case .applied = receipt.result else { Issue.record("Independent healthy program was frozen"); return }
    }
    @Test func frozenPreVariantRulesAndSerializationReplayWithoutUpgrading() async throws {
        let rules = try RulesetCatalog.numericV02()
        let id = UUID(), dataset = UUID()
        let load = Load(amount: "40.1", unit: .kg, basis: .total)
        let movement = Movement(id: "synthetic-lift", primaryMuscles: ["back"], secondaryMuscles: [], minimumRir: 2, availableLoads: [load])
        var profile: [String: CanonicalValue] = ["schemaVersion": .integer(1), "profileId": .string("synthetic-prevariant"), "purpose": .string("Synthetic archived numeric setup")]
        let profileHash = try CanonicalJSON.sha256(.object(profile)); profile["contentHash"] = .string(profileHash)
        let profileData = try CanonicalJSON.encode(.object(profile))
        let config = ProgramConfig(programID: id.uuidString.lowercased(), goal: .size, daysPerWeek: 2, movements: [movement],
            weeklySlots: [WeeklySlot(id: "A", movementIDs: [movement.id]), WeeklySlot(id: "B", movementIDs: [movement.id])], requiredMuscleGroups: ["back"], initialLoads: [movement.id: load],
            profileID: "synthetic-prevariant", profileHash: profileHash, sourceProfileID: "synthetic-prevariant", sourceProfileHash: profileHash)
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: "A")
        let initialized = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
        let command = JournalCommand.initialize(config: config, firstWorkout: slot)
        var envelope = JournalEnvelope(schemaVersion: 1, datasetID: dataset.uuidString.lowercased(), programID: config.programID, eventID: UUID().uuidString.lowercased(),
            eventHash: try BackupService.eventHash(command), parentEnvelopeHash: nil, inputRevision: -1, inputStateHash: nil,
            rulesetVersion: rules.version, rulesetHash: rules.hash, profileID: "synthetic-prevariant", profileHash: profileHash, sourceProfileID: "synthetic-prevariant", sourceProfileHash: profileHash,
            command: command, returnedState: initialized.state, returnedPrescription: initialized.workout, decisions: [], envelopeHash: "")
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        let raw = try BackupService.bytes(envelope)
        func record(kind: CloudRecordKind, identity: String, bytes: Data) throws -> DownloadedCloudRecord {
            DownloadedCloudRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: kind, datasetID: dataset, identity: identity),
                zoneName: CloudRecordCodec.zoneID(dataset).zoneName, recordType: kind.recordType, claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
        }
        let records = try [record(kind: .journal, identity: envelope.eventID, bytes: raw), record(kind: .archive, identity: rules.hash, bytes: BackupService.bytes(rules)), record(kind: .archive, identity: profileHash, bytes: profileData)]
        let (fresh, _) = try recoveryEmpty()
        #expect(try await CloudIngestor(repository: fresh).ingest(records.reversed(), scope: recoveryScope).health == .ready)
        let restored = try await fresh.snapshot(programID: id)
        #expect(restored.state == initialized.state)
        #expect(restored.state.config.variants == nil && restored.state.baseSafety == nil)
        #expect(restored.state.rulesetHash == "cba4084ab7e12b7074a3b87aba813f72fbff2d0560992edd0b566661bfc60beb")
        #expect(restored.state.exercises[movement.id]!.load?.amount == "40.1")
        #expect(try await fresh.exportBackup().journal[0].bytes == raw)
    }
    @Test func legacyNilProfileReferencesContinueConfigureAndResolve() async throws {
        let rules = try RulesetCatalog.numericV02()
        let id = UUID(), dataset = UUID()
        let load = Load(amount: "40.1", unit: .kg, basis: .total)
        let movement = Movement(id: "synthetic-lift", primaryMuscles: ["back"], secondaryMuscles: [], minimumRir: 2, availableLoads: [load])
        var profile: [String: CanonicalValue] = ["schemaVersion": .integer(1), "profileId": .string("synthetic-prevariant"), "purpose": .string("Synthetic archived numeric setup")]
        let profileHash = try CanonicalJSON.sha256(.object(profile)); profile["contentHash"] = .string(profileHash)
        let profileData = try CanonicalJSON.encode(.object(profile))
        let config = ProgramConfig(programID: id.uuidString.lowercased(), goal: .size, daysPerWeek: 2, movements: [movement],
            weeklySlots: [WeeklySlot(id: "A", movementIDs: [movement.id]), WeeklySlot(id: "B", movementIDs: [movement.id])], requiredMuscleGroups: ["back"], initialLoads: [movement.id: load])
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: "A")
        let initialized = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
        let command = JournalCommand.initialize(config: config, firstWorkout: slot)
        var envelope = JournalEnvelope(schemaVersion: 1, datasetID: dataset.uuidString.lowercased(), programID: config.programID, eventID: UUID().uuidString.lowercased(),
            eventHash: try BackupService.eventHash(command), parentEnvelopeHash: nil, inputRevision: -1, inputStateHash: nil,
            rulesetVersion: rules.version, rulesetHash: rules.hash, profileID: "synthetic-prevariant", profileHash: profileHash, sourceProfileID: "synthetic-prevariant", sourceProfileHash: profileHash,
            command: command, returnedState: initialized.state, returnedPrescription: initialized.workout, decisions: [], envelopeHash: "")
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        let raw = try BackupService.bytes(envelope)
        func record(kind: CloudRecordKind, identity: String, bytes: Data) throws -> DownloadedCloudRecord {
            DownloadedCloudRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: kind, datasetID: dataset, identity: identity),
                zoneName: CloudRecordCodec.zoneID(dataset).zoneName, recordType: kind.recordType, claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
        }
        let records = try [record(kind: .journal, identity: envelope.eventID, bytes: raw), record(kind: .archive, identity: rules.hash, bytes: BackupService.bytes(rules)), record(kind: .archive, identity: profileHash, bytes: profileData)]
        let (fresh, _) = try recoveryEmpty()
        #expect(try await CloudIngestor(repository: fresh).ingest(records.reversed(), scope: recoveryScope).health == .ready)
        let restored = try await fresh.snapshot(programID: id)
        #expect(restored.state == initialized.state)
        #expect(restored.state.config.variants == nil && restored.state.baseSafety == nil)
        #expect(restored.state.rulesetHash == "cba4084ab7e12b7074a3b87aba813f72fbff2d0560992edd0b566661bfc60beb")
        #expect(restored.state.exercises[movement.id]!.load?.amount == "40.1")
        #expect(try await fresh.exportBackup().journal[0].bytes == raw)
        #expect(restored.state.config.profileID == nil && restored.state.config.profileHash == nil)
        #expect(restored.state.config.sourceProfileID == nil && restored.state.config.sourceProfileHash == nil)
        // Accepted numeric archives must never enter the fixed native trainer.
        let app = await AppComposition(repository: fresh)
        try await app.selectRecoveryProgram(id.uuidString.lowercased())
        #expect(await app.workout == nil)
        let reopen = await AppComposition(repository: fresh)
        try await reopen.reloadLocalProductChoices()
        #expect(await reopen.workout == nil)
        #expect(await app.readOnlyProgram?.state == initialized.state)
        #expect(await reopen.readOnlyProgram?.state == initialized.state)
        let beforeApp = try await fresh.exportBackup()
        let exportedURL = try await app.exportBackupFile()
        #expect(try JSONDecoder().decode(BackupDocument.self, from: Data(contentsOf: exportedURL)) == beforeApp)
        let (emptyUIStore, _) = try recoveryEmpty()
        let restoreApp = await AppComposition(repository: emptyUIStore)
        _ = try await restoreApp.restoreBackupData(BackupService.bytes(beforeApp))
        #expect(await restoreApp.workout == nil)
        #expect(await restoreApp.readOnlyProgram?.state == initialized.state)
        #expect(try await emptyUIStore.exportBackup().journal[0].bytes == raw)
        // Format 2 is itself required for this accepted schema-1 graph, even
        // without extra source wrappers. Persistence must retain that admission.
        var minimalGraph = beforeApp; minimalGraph.recovery?.originals = []
        #expect(try BackupService.validate(minimalGraph).heads[config.programID] != nil)
        let (minimalStore, minimalURL) = try recoveryEmpty()
        let minimalApp = await AppComposition(repository: minimalStore)
        _ = try await minimalApp.restoreBackupData(BackupService.bytes(minimalGraph))
        #expect(await minimalApp.workout == nil)
        #expect(await minimalApp.readOnlyProgram?.state == initialized.state)
        #expect(try await minimalStore.exportBackup().formatVersion == 2)
        #expect(try await minimalStore.exportBackup().journal[0].bytes == raw)
        let minimalExport = try await minimalStore.exportBackup()
        #expect(minimalExport.rules == minimalGraph.rules && minimalExport.profiles == minimalGraph.profiles)
        await minimalStore.close()
        let reopenedMinimal = try TrainingRepository.open(at: minimalURL)
        let reopenedMinimalApp = await AppComposition(repository: reopenedMinimal)
        try await reopenedMinimalApp.reloadLocalProductChoices()
        #expect(await reopenedMinimalApp.workout == nil)
        #expect(await reopenedMinimalApp.readOnlyProgram?.state == initialized.state)
        #expect(try await reopenedMinimal.exportBackup() == minimalExport)
        #expect(try await reopenedMinimal.exportBackup().journal[0].bytes == raw)
        // A supported format-1 backup still retains its format and ordinary trainer.
        let supported = try await RepositoryTestHarness.make(goal: .size)
        let supportedOriginal = try await supported.repository.exportBackup()
        #expect(supportedOriginal.formatVersion == 1)
        let (supportedStore, supportedURL) = try recoveryEmpty()
        let supportedApp = await AppComposition(repository: supportedStore)
        _ = try await supportedApp.restoreBackupData(BackupService.bytes(supportedOriginal))
        #expect(await supportedApp.workout != nil)
        #expect(await supportedApp.readOnlyProgram == nil)
        #expect(try await supportedStore.exportBackup() == supportedOriginal)
        await supportedStore.close()
        let reopenedSupported = try TrainingRepository.open(at: supportedURL)
        let reopenedSupportedApp = await AppComposition(repository: reopenedSupported)
        try await reopenedSupportedApp.reloadLocalProductChoices()
        #expect(await reopenedSupportedApp.workout != nil)
        #expect(await reopenedSupportedApp.readOnlyProgram == nil)
        #expect(try await reopenedSupported.exportBackup() == supportedOriginal)
        #expect(try await fresh.exportBackup() == beforeApp)
        #expect(try await fresh.exportBackup().journal[0].bytes == raw)

        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-06"), slotID: "B")
        let p = restored.state.activePrescription
        let logs = p.exercises.map { row in ExerciseLog(movementID: row.movementID, prescriptionID: p.id, status: .completed,
            actualLoad: row.load, actualSets: row.sets.map { _ in ActualSet(reps: 10) }, finalEffort: .onTarget, problem: .none) }
        let event = CompletedWorkout(eventID: UUID().uuidString, date: p.date, slotID: p.slotID, prescriptionID: p.id,
            plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs)
        let finished = try await fresh.finalize(programID: id, expectedRevision: 0, event: event, next: next)
        guard case .applied = finished.result else { Issue.record("Numeric continuation rejected"); return }
        let beforeFailure = try await fresh.exportBackup()
        let beforeSnapshot = try await fresh.snapshot(programID: id)
        await fresh.failNextSave()
        await #expect(throws: (any Error).self) {
            try await fresh.applyConfiguration(programID: id, expectedRevision: 1, change: .goal(.strength), next: next)
        }
        #expect(try await fresh.exportBackup() == beforeFailure)
        #expect(try await fresh.snapshot(programID: id) == beforeSnapshot)
        let configured = try await fresh.applyConfiguration(programID: id, expectedRevision: 1, change: .goal(.strength), next: next)
        #expect(configured.state.config.profileHash == nil && configured.state.config.sourceProfileHash == nil)
        let (other, _) = try recoveryEmpty()
        _ = try await CloudIngestor(repository: other).ingest(records, scope: recoveryScope)
        _ = try await other.applyConfiguration(programID: id, expectedRevision: 0, change: .goal(.maintenance), next: next)
        _ = try await CloudIngestor(repository: fresh).ingest(recoveryRecords(other), scope: recoveryScope)
        let conflict = try await fresh.exportBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(conflict))
        let heads = proof.heads[config.programID]!
        let selected = configured.history.last!.envelopeHash
        let choice = BranchSelection(selectedHeadHash: selected, configurationHeadHash: selected)
        let resolved = try await fresh.resolveConflict(programID: id, expectedHeadHashes: heads, selection: choice, next: next)
        #expect(resolved.health == .ready && resolved.state.config.profileHash == nil)
        #expect(resolved.history.allSatisfy { $0.profileHash == profileHash && $0.sourceProfileHash == profileHash })
        let exported = try await fresh.exportBackup()
        #expect(exported.journal.contains { $0.bytes == raw })
        let (clone, _) = try recoveryEmpty()
        _ = try await clone.importBackup(exported)
        #expect(try await clone.snapshot(programID: id) == resolved)
    }
}

extension CloudRecoveryTests {
    @Test func exactUnknownAndMalformedCloudRecordsAreQuarantined() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await activateSynthetic(s.repository, id: s.programID)
        let original = try await s.repository.exportBackup()
        let records = try await recoveryRecords(s.repository)
        let activation = records.first { (try? JSONDecoder().decode(JournalEnvelope.self, from: $0.observation.payload).schemaVersion) == 3 }!.observation
        var envelope = try JSONDecoder().decode(JournalEnvelope.self, from: activation.payload)
        envelope.schemaVersion = 4; envelope.returnedState.schemaVersion = 4
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        let future = try BackupService.bytes(envelope)
        envelope = try JSONDecoder().decode(JournalEnvelope.self, from: activation.payload)
        envelope.returnedState.exercises[envelope.returnedState.exercises.keys.sorted()[0]]!.exactRepState!.normalTargets = []
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        let malformed = try BackupService.bytes(envelope)
        func record(_ bytes: Data) -> DownloadedCloudRecord {
            DownloadedCloudRecord(observation: CloudObservation(recordID: activation.recordID, zoneName: activation.zoneName,
                recordType: activation.recordType, claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
        }
        _ = try await CloudIngestor(repository: s.repository).ingest([record(future), record(malformed)], scope: recoveryScope)
        let retained = try await s.repository.exportBackup()
        #expect(retained.journal == original.journal && retained.heads == original.heads)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(retained))
        #expect(proof.quarantined.contains { $0.record.bytes == future && $0.reason == "unsupported_version" })
        #expect(proof.quarantined.contains { $0.record.bytes == malformed && $0.reason == "replay_failed" })
        #expect(proof.envelopes.count == original.journal.count)
        #expect(try await s.repository.snapshot(programID: s.programID).health == .unsupportedVersion)
    }
}

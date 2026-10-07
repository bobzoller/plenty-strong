import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

struct CloudConflictTests {
    @Test func graphAncestorImportPreservesUniqueDescendantAndProtectedDraft() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        _ = try await CloudIngestor(repository: source.repository).ingest(recoveryRecords(source.repository), scope: recoveryScope)
        let ancestor = try await source.repository.exportBackup()
        #expect(ancestor.formatVersion == 2)
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        let before = try await source.repository.snapshot(programID: source.programID)
        let backup = try await source.repository.exportBackup()
        _ = try await source.repository.importBackup(ancestor)
        #expect(try await source.repository.snapshot(programID: source.programID) == before)
        #expect(try await source.repository.exportBackup() == backup)
        _ = try await source.repository.importBackup(backup)
        #expect(try await source.repository.snapshot(programID: source.programID) == before)
        let event = RepositoryTestHarness.event(state: before.state)
        let draft = WorkoutDraft(id: UUID(uuidString: event.eventID)!, programID: before.state.config.programID,
            expectedRevision: before.state.revision, planned: before.state.activePrescription, displayed: before.state.activePrescription,
            date: event.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal, logs: event.exercises, workingSetsStarted: true)
        try await source.repository.saveDraft(draft)
        let protected = try await source.repository.snapshot(programID: source.programID)
        let protectedBackup = try await source.repository.exportBackup()
        _ = try await source.repository.importBackup(ancestor)
        #expect(try await source.repository.snapshot(programID: source.programID) == protected)
        #expect(try await source.repository.exportBackup() == protectedBackup)
    }

    @Test func divergentGraphDraftImportRejectsBeforeCommit() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let (other, _) = try recoveryEmpty()
        _ = try await other.importBackup(source.repository.exportBackup())
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        _ = try await other.applyConfiguration(programID: source.programID, expectedRevision: 0, change: .goal(.strength), next: source.next)
        _ = try await CloudIngestor(repository: other).ingest(recoveryRecords(other), scope: recoveryScope)
        let remote = try await other.snapshot(programID: source.programID)
        let event = RepositoryTestHarness.event(state: remote.state)
        let draft = WorkoutDraft(id: UUID(uuidString: event.eventID)!, programID: remote.state.config.programID,
            expectedRevision: remote.state.revision, planned: remote.state.activePrescription, displayed: remote.state.activePrescription,
            date: event.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal, logs: event.exercises, workingSetsStarted: true)
        try await other.saveDraft(draft)
        let incoming = try await other.exportBackup(), inputBytes = try BackupService.bytes(incoming)
        let before = try await source.repository.snapshot(programID: source.programID)
        let backup = try await source.repository.exportBackup()
        #expect(throws: (any Error).self) { try BackupService.validateDraft(draft, state: before.state, rules: RulesetCatalog.fixedV1()) }
        await #expect(throws: (any Error).self) { try await source.repository.importBackup(incoming) }
        #expect(try await source.repository.snapshot(programID: source.programID) == before)
        #expect(try await source.repository.exportBackup() == backup)
        #expect(try BackupService.bytes(incoming) == inputBytes)
    }

    @Test func supportedStructuralCorruptionCanBeReviewedWithoutWaivingUnknownCommand() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        var pain = source.firstEvent; pain.exercises[0].problem = .pain
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: pain, next: source.next)
        let records = try await recoveryRecords(source.repository)
        let original = records.first { (try? JSONDecoder().decode(JournalEnvelope.self, from: $0.observation.payload).eventID) == pain.eventID }!.observation
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: original.payload) else { throw BackupService.invalid("fixture") }
        fields.removeValue(forKey: "returnedPrescription")
        let bytes = try CanonicalJSON.encode(.object(fields))
        fields["returnedPrescription"] = .integer(7)
        let typeInvalidBytes = try CanonicalJSON.encode(.object(fields))
        func corrupt(_ bytes: Data) -> DownloadedCloudRecord {
            DownloadedCloudRecord(observation: CloudObservation(recordID: original.recordID, zoneName: original.zoneName, recordType: original.recordType,
                claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
        }
        _ = try await CloudIngestor(repository: source.repository).ingest([corrupt(bytes), corrupt(typeInvalidBytes)], scope: recoveryScope)
        #expect(try await source.repository.snapshot(programID: source.programID).health == .integrityConflict)
        let backup = try await source.repository.exportBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(backup))
        #expect(proof.quarantined.first { $0.record.bytes == bytes }?.reason == "invalid_record")
        #expect(proof.quarantined.first { $0.record.bytes == typeInvalidBytes }?.reason == "invalid_record")
        let heads = proof.heads[source.programID.uuidString.lowercased()]!
        let choice = BranchSelection(selectedHeadHash: heads[0], reviewedQuarantineChecksums: Array(Set(proof.quarantined.filter { $0.programID == source.programID.uuidString.lowercased() }.map { BackupService.hash($0.record.bytes) })))
        let resolved = try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads, selection: choice,
            next: source.next)
        #expect(resolved.health == .ready)
        #expect(resolved.state.exercises.values.contains { $0.mode == .paused })
        #expect(try await source.repository.exportBackup().recovery!.originals.contains { $0.bytes == bytes })
        let reviewedBackup = try await source.repository.exportBackup()
        #expect(reviewedBackup.recovery!.originals.contains { $0.bytes == typeInvalidBytes })
        let (clone, _) = try recoveryEmpty()
        _ = try await clone.importBackup(reviewedBackup)
        #expect(try await clone.snapshot(programID: source.programID) == resolved)
        fields["command"] = .object(["kind": .string("future-command")])
        let unknownBytes = try CanonicalJSON.encode(.object(fields))
        _ = try await CloudIngestor(repository: source.repository).ingest([corrupt(unknownBytes)], scope: recoveryScope)
        #expect(try await source.repository.snapshot(programID: source.programID).health == .unsupportedVersion)
        let unsupported = try await source.repository.exportBackup()
        let unknownProof = try RecoveryVerifier().verify(BackupService.recoveryRecords(unsupported))
        let unknownHeads = unknownProof.heads[source.programID.uuidString.lowercased()]!
        let unknownChoice = BranchSelection(selectedHeadHash: unknownHeads[0], reviewedQuarantineChecksums: Array(Set(unknownProof.quarantined
            .filter { $0.programID == source.programID.uuidString.lowercased() && !unsupported.recovery!.resolvedQuarantineKeys.contains(BackupService.hash($0.record.bytes)) }
            .map { BackupService.hash($0.record.bytes) })))
        let unwaived = try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: unknownHeads,
            selection: unknownChoice, next: source.next)
        #expect(unwaived.health == .unsupportedVersion)
    }
    @Test func opaqueInvalidOriginalMarkerCanResolveWithoutNestedExpansion() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let records = try await recoveryRecords(source.repository)
        let root = records.first { $0.observation.recordType == CloudRecordKind.journal.recordType }!.observation
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: root.payload) else {
            throw BackupService.invalid("fixture_root")
        }
        fields["archiveKind"] = .string("causal-original-v1")
        fields["datasetId"] = .string("00000000-0000-0000-0000-000000000999")
        let bytes = try CanonicalJSON.encode(.object(fields))
        let bad = DownloadedCloudRecord(observation: CloudObservation(recordID: root.recordID, zoneName: root.zoneName,
            recordType: root.recordType, claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
        _ = try await CloudIngestor(repository: source.repository).ingest([bad], scope: recoveryScope)
        let before = try await source.repository.exportBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(before))
        let heads = proof.heads[source.programID.uuidString.lowercased()]!
        let choice = BranchSelection(selectedHeadHash: heads[0], reviewedQuarantineChecksums: proof.quarantined.map { BackupService.hash($0.record.bytes) })
        let resolved = try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads, selection: choice, next: source.next)
        #expect(resolved.health == .ready && resolved.history.count == 2)
        let backup = try await source.repository.exportBackup()
        let retained = try RecoveryVerifier().verify(BackupService.recoveryRecords(backup))
        #expect(retained.originals.contains { $0.bytes == bytes })
        #expect(retained.quarantined.contains { $0.record.bytes == bytes })
        let (fresh, _) = try recoveryEmpty()
        _ = try await fresh.importBackup(backup)
        #expect(try await fresh.snapshot(programID: source.programID) == resolved)
        let inner = try CausalOriginalArchive.make(ArchivedRecord(observation: root))
        let dataset = UUID(uuidString: String(root.zoneName.dropFirst(CloudRecordCodec.zonePrefix.count)))!
        let innerRecord = ArchivedRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .archive, datasetID: dataset, identity: inner.id),
            zoneName: root.zoneName, recordType: CloudRecordKind.archive.recordType, claimedChecksum: inner.checksum, payload: inner.bytes, systemFields: Data()))
        let outer = try CausalOriginalArchive.make(innerRecord)
        let nested = ArchivedRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .archive, datasetID: dataset, identity: outer.id),
            zoneName: root.zoneName, recordType: CloudRecordKind.archive.recordType, claimedChecksum: outer.checksum, payload: outer.bytes, systemFields: Data()))
        let rejected = try RecoveryVerifier().verify([nested])
        #expect(rejected.originals == [nested] && rejected.envelopes.isEmpty)
        #expect(rejected.quarantined.count == 1)
    }
    @Test func unrepresentableReviewedOriginalRejectsResolutionAtomically() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let records = try await recoveryRecords(source.repository)
        let root = records.first { $0.observation.recordType == CloudRecordKind.journal.recordType }!.observation
        // The retained descriptor actually comes from a different dataset;
        // untrusted text inside a malformed payload is not this boundary.
        let foreignDataset = UUID()
        let identity = try JSONDecoder().decode(JournalEnvelope.self, from: root.payload).eventID
        let bad = DownloadedCloudRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .journal, datasetID: foreignDataset, identity: identity),
            zoneName: CloudRecordCodec.zoneID(foreignDataset).zoneName, recordType: root.recordType,
            claimedChecksum: root.claimedChecksum, payload: root.payload, systemFields: Data()))
        _ = try await CloudIngestor(repository: source.repository).ingest([bad], scope: recoveryScope)
        let before = try await source.repository.exportBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(before))
        let heads = proof.heads[source.programID.uuidString.lowercased()]!
        let choice = BranchSelection(selectedHeadHash: heads[0], reviewedQuarantineChecksums: proof.quarantined.map { BackupService.hash($0.record.bytes) })
        await #expect(throws: (any Error).self) {
            try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads, selection: choice, next: source.next)
        }
        #expect(try await source.repository.exportBackup() == before)
    }
    @Test func arrivingSiblingFreezesAuthoritativeCommandsAndPreservesDraft() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let root = try await source.repository.exportBackup()
        let (other, _) = try recoveryEmpty()
        _ = try await other.importBackup(root)
        var pain = source.firstEvent; pain.eventID = UUID().uuidString
        pain.exercises[0].problem = .pain
        _ = try await other.finalize(programID: source.programID, expectedRevision: 0, event: pain, next: source.next)
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        let current = try await source.repository.snapshot(programID: source.programID)
        let event = RepositoryTestHarness.event(state: current.state)
        var draft = WorkoutDraft(id: UUID(uuidString: event.eventID)!, programID: current.state.config.programID,
            expectedRevision: current.state.revision, planned: current.state.activePrescription, displayed: current.state.activePrescription,
            date: event.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal, logs: event.exercises, workingSetsStarted: true)
        try await source.repository.saveDraft(draft)
        let report = try await CloudIngestor(repository: source.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        #expect(report.health == .integrityConflict)
        let conflicted = try await source.repository.snapshot(programID: source.programID)
        #expect(conflicted.history.count == 3)
        #expect(conflicted.draft == draft)
        await #expect(throws: (any Error).self) {
            try await source.repository.applyConfiguration(programID: source.programID, expectedRevision: 1, change: .goal(.strength), next: source.next)
        }
        draft.logs[0].actualSets.append(ActualSet(reps: 1))
        try await source.repository.saveDraft(draft)
        #expect(try await source.repository.snapshot(programID: source.programID).draft == draft)
    }
}

extension CloudConflictTests {
    @Test func explicitResolutionRetainsPainAndBothBranchesAcrossPortableRestore() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let root = try await source.repository.exportBackup()
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(root)
        var pain = source.firstEvent; pain.eventID = UUID().uuidString; pain.exercises[0].problem = .pain
        _ = try await other.finalize(programID: source.programID, expectedRevision: 0, event: pain, next: source.next)
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        _ = try await CloudIngestor(repository: source.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        let before = try await source.repository.exportBackup()
        let heads = before.recovery!.heads[source.programID.uuidString.lowercased()]!
        let clean = try await source.repository.snapshot(programID: source.programID).history.first { $0.eventID == source.firstEvent.eventID }!
        await #expect(throws: (any Error).self) {
            try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: [clean.envelopeHash],
                selection: BranchSelection(selectedHeadHash: clean.envelopeHash), next: source.next)
        }
        let resolved = try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads,
            selection: BranchSelection(selectedHeadHash: clean.envelopeHash), next: source.next)
        #expect(resolved.health == .ready)
        let base = pain.exercises[0].baseMovementID!
        #expect(resolved.state.baseSafety![base]!.paused)
        #expect(resolved.history.count == 4)
        let portable = try await source.repository.exportBackup()
        let (restored, _) = try recoveryEmpty(); _ = try await restored.importBackup(portable)
        #expect(try await restored.snapshot(programID: source.programID) == resolved)
        #expect(try await restored.exportBackup() == portable)
    }
    @Test func sameIdentityValidAlternativesUseOriginalArchivesForFreshRecovery() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let root = try await source.repository.exportBackup()
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(root)
        var pain = source.firstEvent; pain.exercises[0].problem = .pain
        _ = try await other.finalize(programID: source.programID, expectedRevision: 0, event: pain, next: source.next)
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        _ = try await CloudIngestor(repository: source.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        let doc = try await source.repository.exportBackup()
        let heads = doc.recovery!.heads[source.programID.uuidString.lowercased()]!
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(doc))
        let checksums = proof.quarantined.map { BackupService.hash($0.record.bytes) }
        let selected = try await source.repository.snapshot(programID: source.programID).history.first { $0.eventID == source.firstEvent.eventID && $0.returnedState.baseSafety![pain.exercises[0].baseMovementID!]!.paused == false }!
        let resolved = try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads,
            selection: BranchSelection(selectedHeadHash: selected.envelopeHash, reviewedQuarantineChecksums: checksums), next: source.next)
        let pending = try await source.repository.pendingCloudRecords(scope: recoveryScope)
        let sourceArchives = pending.filter { ((try? JSONSerialization.jsonObject(with: $0.payload)) as? [String: Any])?["archiveKind"] as? String == "causal-original-v1" }
        #expect(!sourceArchives.isEmpty)
        let records = pending.map { DownloadedCloudRecord(observation: CloudObservation(recordID: $0.recordID,
            zoneName: CloudRecordCodec.zoneID($0.datasetID).zoneName, recordType: $0.kind.recordType,
            claimedChecksum: $0.checksum, payload: $0.payload, systemFields: Data())) }
        let raw = records.map { ArchivedRecord(observation: $0.observation) }
        let missing = try RecoveryVerifier().verify(raw.filter { $0.recordID != sourceArchives[0].recordID })
        #expect(!missing.waiting.isEmpty)
        var forgedRecords = raw
        let resolutionIndex = forgedRecords.firstIndex { record in
            guard let envelope = try? JSONDecoder().decode(JournalEnvelope.self, from: record.bytes) else { return false }
            if case .resolveConflict = envelope.command { return true }; return false
        }!
        var forged = try JSONDecoder().decode(JournalEnvelope.self, from: forgedRecords[resolutionIndex].bytes)
        if case let .resolveConflict(choice, preserved, archives, next) = forged.command {
            forged.command = .resolveConflict(selection: choice, preservedHeadHashes: preserved, originalArchiveHashes: Array(archives.dropFirst()), next: next)
        }
        forged.eventHash = try BackupService.eventHash(forged.command)
        forged.envelopeHash = try BackupService.envelopeHash(forged)
        let originalRecord = forgedRecords[resolutionIndex]
        forgedRecords[resolutionIndex] = ArchivedRecord(observation: CloudObservation(recordID: originalRecord.recordID, zoneName: originalRecord.zoneName,
            recordType: originalRecord.recordType, claimedChecksum: try BackupService.hash(forged), payload: try BackupService.bytes(forged), systemFields: Data()))
        #expect(try RecoveryVerifier().verify(forgedRecords).envelopes[forged.envelopeHash] == nil)
        let (fresh, _) = try recoveryEmpty()
        let report = try await CloudIngestor(repository: fresh).ingest(records.reversed(), scope: recoveryScope)
        #expect(report.health == .ready)
        #expect(try await fresh.snapshot(programID: source.programID) == resolved)
        #expect(try await fresh.pendingCloudRecords(scope: recoveryScope).isEmpty)
        #expect(try await fresh.cloudStatus(scope: recoveryScope).acknowledgedCompletedWorkoutCount == 2)
        let alternatives = resolved.history.filter { $0.eventID == source.firstEvent.eventID }
        #expect(alternatives.count == 2)
        // Retry the other retained payload, independent of the deterministic history order.
        guard case let .workout(retried, _) = alternatives[1].command else { throw BackupService.invalid("fixture_command") }
        let retry = try await fresh.finalize(programID: source.programID, expectedRevision: resolved.state.revision,
            event: retried, next: source.next)
        #expect(retry.result == .noOp(nextState: resolved.state, reason: .eventReplayed))
        #expect(retry.snapshot == resolved)
        let (portableOnly, _) = try recoveryEmpty()
        _ = try await portableOnly.importBackup(source.repository.exportBackup())
        let b = CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B")
        #expect(try await portableOnly.cloudStatus(scope: b).acknowledgedCompletedWorkoutCount == 0)
        #expect(try await portableOnly.cloudMetadata(scope: b).acknowledgements.isEmpty)
        #expect(try await portableOnly.cloudMetadata(scope: recoveryScope).observations.isEmpty)
        let exported = try await portableOnly.exportBackup()
        let encoded = String(data: try BackupService.bytes(exported), encoding: .utf8)!
        #expect(!encoded.contains("synthetic-A") && !encoded.contains("systemFields") && !encoded.contains("acknowledgements"))
        let unrelated = try await RepositoryTestHarness.make(goal: .strength)
        _ = try await CloudIngestor(repository: fresh).ingest(recoveryRecords(unrelated.repository), scope: recoveryScope)
        let multiDataset = try await fresh.exportBackup()
        #expect(multiDataset.recovery!.rootDatasets.count == 2)
        let portableRecords = try BackupService.recoveryRecords(multiDataset)
        let wrappers = portableRecords.compactMap { record -> (ArchivedRecord, CausalOriginalArchive)? in
            guard let wrapper = try? JSONDecoder().decode(CausalOriginalArchive.self, from: record.bytes) else { return nil }
            return (record, wrapper)
        }
        #expect(wrappers.allSatisfy { $0.0.zoneName == $0.1.record.zoneName })
        let (multiRestored, _) = try recoveryEmpty()
        _ = try await multiRestored.importBackup(multiDataset)
        #expect(try await multiRestored.snapshot(programID: source.programID) == resolved)
        #expect(try await multiRestored.snapshot(programID: unrelated.programID).health == .ready)
        let selectedBytes = try BackupService.bytes(selected)
        let laterBytes = Data(selectedBytes.dropLast(9))
        let later = DownloadedCloudRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .journal,
            datasetID: UUID(uuidString: selected.datasetID)!, identity: selected.eventID), zoneName: CloudRecordCodec.zoneID(UUID(uuidString: selected.datasetID)!).zoneName,
            recordType: CloudRecordKind.journal.recordType, claimedChecksum: BackupService.hash(laterBytes), payload: laterBytes, systemFields: Data()))
        guard case .object(var claims) = try JSONDecoder().decode(CanonicalValue.self, from: selectedBytes) else { throw BackupService.invalid("fixture_branch") }
        claims["programId"] = .string(unrelated.programID.uuidString.lowercased())
        let claimedBytes = try CanonicalJSON.encode(.object(claims))
        let falseClaim = DownloadedCloudRecord(observation: CloudObservation(recordID: later.recordID, zoneName: later.observation.zoneName,
            recordType: later.observation.recordType, claimedChecksum: BackupService.hash(claimedBytes), payload: claimedBytes, systemFields: Data()))
        let reopened = try await CloudIngestor(repository: fresh).ingest([later, falseClaim], scope: recoveryScope)
        #expect(reopened.health == .integrityConflict)
        #expect(try await fresh.snapshot(programID: source.programID).health == .integrityConflict)
        #expect(try await fresh.snapshot(programID: unrelated.programID).health == .ready)
        let candidates = try await fresh.recoveryPrograms()
        let independent = candidates.first { $0.programID == unrelated.programID.uuidString.lowercased() }!
        let independentDataset = try await unrelated.repository.exportBackup().datasetID
        #expect(independent.datasetIDs == [independentDataset])
        let conflictedBackup = try await fresh.exportBackup()
        let currentHeads = conflictedBackup.recovery!.heads[source.programID.uuidString.lowercased()]!
        await #expect(throws: (any Error).self) {
            try await fresh.resolveConflict(programID: source.programID, expectedHeadHashes: currentHeads,
                selection: BranchSelection(selectedHeadHash: currentHeads[0], reviewedQuarantineChecksums: checksums), next: source.next)
        }
        let repeated = try await CloudIngestor(repository: fresh).ingest([later, falseClaim], scope: recoveryScope)
        #expect(repeated.accepted == 0 && repeated.identical == 2)
        #expect(try await fresh.exportBackup() == conflictedBackup)
        let updated = try await fresh.resolveConflict(programID: source.programID, expectedHeadHashes: currentHeads,
            selection: BranchSelection(selectedHeadHash: currentHeads[0], reviewedQuarantineChecksums: [BackupService.hash(laterBytes), BackupService.hash(claimedBytes)]), next: source.next)
        #expect(updated.health == .ready && updated.state.baseSafety![pain.exercises[0].baseMovementID!]!.paused)
        #expect(updated.history.count == resolved.history.count + 1)
    }
}

extension CloudConflictTests {
    @Test func localFinalizeRacingRemoteIngestRetainsEveryCommittedObservationOrDraft() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let root = try await source.repository.exportBackup()
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(root)
        var remote = source.firstEvent; remote.eventID = UUID().uuidString; remote.exercises[0].problem = .controlLost
        _ = try await other.finalize(programID: source.programID, expectedRevision: 0, event: remote, next: source.next)
        let records = try await recoveryRecords(other)
        let draft = try await source.draft(); try await source.repository.saveDraft(draft)
        async let ingested = CloudIngestor(repository: source.repository).ingest(records, scope: recoveryScope)
        async let finalized = source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        _ = try await ingested
        let receipt = try await finalized
        let current = try await source.repository.snapshot(programID: source.programID)
        #expect(current.history.contains { $0.eventID == remote.eventID })
        if case .applied = receipt.result {
            #expect(current.history.contains { $0.eventID == source.firstEvent.eventID })
            #expect(current.health == .integrityConflict)
        } else {
            #expect(current.draft == draft)
            #expect(current.health == .incompleteRecovery)
        }
        #expect(current.health != .ready)
    }
    @Test func laterDistinctChildReopensResolutionButIdenticalFetchDoesNot() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let root = try await source.repository.exportBackup()
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(root)
        let (late, _) = try recoveryEmpty(); _ = try await late.importBackup(root)
        var remote = source.firstEvent; remote.eventID = UUID().uuidString
        var later = source.firstEvent; later.eventID = UUID().uuidString; later.exercises[0].problem = .pain
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        _ = try await other.finalize(programID: source.programID, expectedRevision: 0, event: remote, next: source.next)
        _ = try await late.finalize(programID: source.programID, expectedRevision: 0, event: later, next: source.next)
        let records = try await recoveryRecords(other)
        _ = try await CloudIngestor(repository: source.repository).ingest(records.shuffled(), scope: recoveryScope)
        let backup = try await source.repository.exportBackup()
        let heads = backup.recovery!.heads[source.programID.uuidString.lowercased()]!
        let selected = try await source.repository.snapshot(programID: source.programID).history.first { $0.eventID == source.firstEvent.eventID }!
        let resolved = try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads,
            selection: BranchSelection(selectedHeadHash: selected.envelopeHash), next: source.next)
        #expect(try await CloudIngestor(repository: source.repository).ingest(records, scope: recoveryScope).health == .ready)
        _ = try await CloudIngestor(repository: source.repository).ingest(recoveryRecords(late), scope: recoveryScope)
        #expect(try await source.repository.snapshot(programID: source.programID).health == .integrityConflict)
        #expect(try await source.repository.snapshot(programID: source.programID).state == resolved.state)
        await #expect(throws: (any Error).self) {
            try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads,
                selection: BranchSelection(selectedHeadHash: selected.envelopeHash), next: source.next)
        }
    }
}

extension CloudConflictTests {
    @Test func exactResolutionSourceCoverageRequiresBothWrapperAndResolutionAcknowledgement() async throws {
        let source = try await RepositoryTestHarness.make(goal: .size)
        let root = try await source.repository.exportBackup()
        _ = try await recoveryRecords(source.repository)
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(root)
        var pain = source.firstEvent; pain.exercises[0].problem = .pain
        _ = try await other.finalize(programID: source.programID, expectedRevision: 0, event: pain, next: source.next)
        _ = try await source.repository.finalize(programID: source.programID, expectedRevision: 0, event: source.firstEvent, next: source.next)
        _ = try await CloudIngestor(repository: source.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        let doc = try await source.repository.exportBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(doc))
        let selected = proof.envelopes.values.first { $0.eventID == source.firstEvent.eventID && !$0.returnedState.baseSafety![pain.exercises[0].baseMovementID!]!.paused }!
        let heads = proof.heads[source.programID.uuidString.lowercased()]!
        _ = try await source.repository.resolveConflict(programID: source.programID, expectedHeadHashes: heads,
            selection: BranchSelection(selectedHeadHash: selected.envelopeHash, reviewedQuarantineChecksums: proof.quarantined.map { BackupService.hash($0.record.bytes) }), next: source.next)
        let pending = try await source.repository.pendingCloudRecords(scope: recoveryScope)
        let occupied = pending.first { $0.identity == source.firstEvent.eventID }!
        let resolution = pending.first { record in
            guard let envelope = try? JSONDecoder().decode(JournalEnvelope.self, from: record.payload) else { return false }
            if case .resolveConflict = envelope.command { return true }; return false
        }!
        let wrappers = pending.filter { ((try? JSONSerialization.jsonObject(with: $0.payload)) as? [String: Any])?["archiveKind"] != nil }
        try await source.repository.acknowledge(records: wrappers.map { CloudAcknowledgement(recordID: $0.recordID, verifiedHash: $0.checksum, systemFields: Data()) }, scope: recoveryScope)
        #expect(try await source.repository.pendingCloudRecords(scope: recoveryScope).contains { $0.recordID == occupied.recordID })
        #expect(try await source.repository.cloudStatus(scope: recoveryScope).acknowledgedCompletedWorkoutCount == 0)
        let remaining = pending.filter { $0.recordID != occupied.recordID && $0.recordID != resolution.recordID && !wrappers.contains($0) }
        try await source.repository.acknowledge(records: remaining.map { CloudAcknowledgement(recordID: $0.recordID, verifiedHash: $0.checksum, systemFields: Data()) }, scope: recoveryScope)
        #expect(try await source.repository.cloudStatus(scope: recoveryScope).acknowledgedCompletedWorkoutCount == 0)
        try await source.repository.acknowledge(records: [.init(recordID: resolution.recordID, verifiedHash: resolution.checksum, systemFields: Data())], scope: recoveryScope)
        #expect(try await source.repository.pendingCloudRecords(scope: recoveryScope).isEmpty)
        #expect(try await source.repository.cloudStatus(scope: recoveryScope).acknowledgedCompletedWorkoutCount == 2)
        #expect(try await source.repository.cloudStatus(scope: recoveryScope).phase == .conflict)
        #expect(try await source.repository.cloudMetadata(scope: recoveryScope).acknowledgements[occupied.recordID] == nil)
        let otherScope = CloudScope(containerIdentifier: recoveryScope.containerIdentifier, environment: .development, accountIdentifier: "synthetic-B")
        #expect(try await source.repository.cloudStatus(scope: otherScope).acknowledgedCompletedWorkoutCount == 0)
        await #expect(throws: (any Error).self) {
            try await source.repository.acknowledge(records: [.init(recordID: resolution.recordID, verifiedHash: resolution.checksum, systemFields: Data())], scope: otherScope)
        }
    }
}

extension CloudConflictTests {
    @Test func shuffledDuplicatedTwoDeviceBranchesConvergeOnlyAfterExplicitResolution() async throws {
        let a = try await RepositoryTestHarness.make(goal: .size)
        let root = try await a.repository.exportBackup()
        let (b, _) = try recoveryEmpty(); _ = try await b.importBackup(root)
        var bEvent = a.firstEvent; bEvent.eventID = UUID().uuidString; bEvent.exercises[0].problem = .pain
        _ = try await a.repository.finalize(programID: a.programID, expectedRevision: 0, event: a.firstEvent, next: a.next)
        _ = try await b.finalize(programID: a.programID, expectedRevision: 0, event: bEvent, next: a.next)
        let aRecords = try await recoveryRecords(a.repository), bRecords = try await recoveryRecords(b)
        _ = try await CloudIngestor(repository: a.repository).ingest((bRecords + bRecords).shuffled(), scope: recoveryScope)
        _ = try await CloudIngestor(repository: b).ingest((aRecords + aRecords).shuffled(), scope: recoveryScope)
        #expect(try await a.repository.snapshot(programID: a.programID).health == .integrityConflict)
        #expect(try await b.snapshot(programID: a.programID).health == .integrityConflict)
        let backup = try await a.repository.exportBackup()
        let selected = try await a.repository.snapshot(programID: a.programID).history.first { $0.eventID == a.firstEvent.eventID }!
        let resolved = try await a.repository.resolveConflict(programID: a.programID, expectedHeadHashes: backup.recovery!.heads[a.programID.uuidString.lowercased()]!,
            selection: BranchSelection(selectedHeadHash: selected.envelopeHash), next: a.next)
        let resolutionRecords = try await recoveryRecords(a.repository)
        _ = try await CloudIngestor(repository: b).ingest((resolutionRecords + resolutionRecords).shuffled(), scope: recoveryScope)
        #expect(try await b.snapshot(programID: a.programID) == resolved)
        #expect(resolved.state.baseSafety![bEvent.exercises[0].baseMovementID!]!.paused)
        let (restored, _) = try recoveryEmpty(); _ = try await restored.importBackup(a.repository.exportBackup())
        #expect(try await restored.snapshot(programID: a.programID) == resolved)
    }
}

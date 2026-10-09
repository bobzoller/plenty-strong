import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong
@Suite(.serialized) struct StarterProgramRecoveryTests {
    @Test(arguments: StarterProgramChoice.allCases) func newPoliciesAreDiscoveredWithoutGuessing(choice: StarterProgramChoice) async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: choice, goal: .size)
        let document = try await s.repository.exportBackup()
        let originals = try BackupService.recoveryRecords(document)
        let proof = try RecoveryVerifier().verify(originals)
        #expect(proof.quarantined.isEmpty && proof.waiting.isEmpty && proof.envelopes.count == 1)
        #expect(CloudRecordCodec.recoveryCandidates(originals.filter { $0.recordType == CloudRecordKind.journal.recordType }.map {
            CloudObservation(recordID: $0.recordID, zoneName: $0.zoneName, recordType: $0.recordType,
                claimedChecksum: $0.claimedChecksum, payload: $0.bytes, systemFields: Data())
        }).allSatisfy { $0.status != .unsupported })
    }
}

extension StarterProgramRecoveryTests {
    @Test func registeredSchemaThreeIsDiscovered() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        _ = try await activateSynthetic(s.repository, id: s.programID)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(await s.repository.exportBackup()))
        #expect(proof.quarantined.isEmpty && proof.waiting.isEmpty && proof.envelopes.count == 2)
        let observations = try BackupService.recoveryRecords(await s.repository.exportBackup()).map { original in
            CloudObservation(recordID: original.recordID, zoneName: original.zoneName, recordType: original.recordType,
                claimedChecksum: original.claimedChecksum, payload: original.bytes, systemFields: Data())
        }
        #expect(CloudRecordCodec.recoveryCandidates(observations).allSatisfy { $0.status != .unsupported })
    }
    @Test func ordinaryAndGraphSwitchBackupsReplayFromPinnedArchives() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let switched = try await s.change(.wholeBodyGlutes)
        let ordinary = try await s.repository.exportBackup()
        let (clone, _) = try recoveryEmpty()
        _ = try await clone.importBackup(ordinary)
        #expect(try await clone.snapshot(programID: s.programID) == switched)
        _ = try await CloudIngestor(repository: s.repository).ingest(recoveryRecords(s.repository), scope: recoveryScope)
        let graph = try await s.repository.exportBackup()
        #expect(graph.formatVersion == 2)
        let (restored, _) = try recoveryEmpty()
        _ = try await restored.importBackup(graph)
        let readback = try await restored.snapshot(programID: s.programID)
        #expect(readback.state == switched.state && readback.health == .ready)
        #expect(ordinary.journal.allSatisfy { graph.journal.contains($0) })
        #expect(try await restored.exportBackup().recovery?.originals == graph.recovery?.originals)
    }
    @Test func graphRestoredProgramsCanSwitchWithoutReplacingOriginalArchives() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        _ = try await s.change(.wholeBodyGlutes)
        _ = try await CloudIngestor(repository: s.repository).ingest(recoveryRecords(s.repository), scope: recoveryScope)
        let graph = try await s.repository.exportBackup()
        let (restored, _) = try recoveryEmpty()
        _ = try await restored.importBackup(graph)
        let before = try await restored.exportBackup()
        let current = try await restored.snapshot(programID: s.programID)
        let switched = try await restored.changeStarterProgram(programID: s.programID,
            expectedRevision: current.state.revision, expectedHeadHash: current.history.last!.envelopeHash,
            choice: .upperBody, goal: .size, next: WorkoutSlot(date: current.state.activePrescription.date, slotID: current.state.activePrescription.slotID))
        #expect(switched.state.config.profileHash == StarterProgramCatalog.upperProfileHash)
        let after = try await restored.exportBackup()
        #expect(before.rules.allSatisfy { after.rules.contains($0) })
        #expect(before.profiles.allSatisfy { after.profiles.contains($0) })
        #expect(before.recovery!.originals.allSatisfy { after.recovery!.originals.contains($0) })
    }
    @Test func freshRecoverySwitchReusesCanonicalArchivesWithoutReplacingOriginals() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        _ = try await s.change(.wholeBodyGlutes)
        let records = try await recoveryRecords(s.repository)
        let (fresh, _) = try recoveryEmpty()
        _ = try await CloudIngestor(repository: fresh).ingest(records.reversed(), scope: recoveryScope)
        let before = try await fresh.exportBackup()
        #expect(before.rules.allSatisfy { (try? CloudRecordCodec.canonicalBytes($0.bytes)) == $0.bytes })
        let current = try await fresh.snapshot(programID: s.programID)
        let switched = try await fresh.changeStarterProgram(programID: s.programID,
            expectedRevision: current.state.revision, expectedHeadHash: current.history.last!.envelopeHash,
            choice: .upperBody, goal: .size,
            next: WorkoutSlot(date: current.state.activePrescription.date, slotID: current.state.activePrescription.slotID))
        #expect(switched.state.config.profileHash == StarterProgramCatalog.upperProfileHash)
        let after = try await fresh.exportBackup()
        #expect(before.rules.allSatisfy { after.rules.contains($0) })
        #expect(before.profiles.allSatisfy { after.profiles.contains($0) })
        #expect(before.recovery!.originals.allSatisfy { after.recovery!.originals.contains($0) })
    }
    @Test func mixedProfileForksKeepEveryOriginalAndBlockTraining() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let prefix = try await s.repository.exportBackup()
        let (other, _) = try recoveryEmpty()
        _ = try await other.importBackup(prefix)
        _ = try await s.change(.wholeBodyGlutes)
        _ = try await other.applyConfiguration(programID: s.programID, expectedRevision: 0, change: .goal(.maintenance),
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        let incoming = try await recoveryRecords(other)
        _ = try await CloudIngestor(repository: s.repository).ingest(incoming, scope: recoveryScope)
        #expect(try await s.repository.snapshot(programID: s.programID).health == .mixedPolicyConflict)
        let preserved = try await s.repository.exportBackup()
        #expect(incoming.allSatisfy { record in preserved.recovery!.originals.contains { $0.bytes == record.observation.payload } })
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(preserved))
        let heads = try #require(proof.heads[s.initial.state.config.programID])
        await #expect(throws: (any Error).self) {
            try await s.repository.resolveConflict(programID: s.programID, expectedHeadHashes: heads,
                selection: BranchSelection(selectedHeadHash: heads[0], configurationHeadHash: heads[0]),
                next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE"))
        }
        #expect(try await s.repository.exportBackup() == preserved)
        await #expect(throws: (any Error).self) { try await s.change(.upperBody) }
    }
    @Test func samePolicyResolutionUnionsRemovedAndActiveFamilySafety() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        _ = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: 0,
            change: .minimumRir(baseMovementID: "banded_pullups", value: 4),
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        let common = try await s.change(.wholeBodyGlutes)
        let prefix = try await s.repository.exportBackup()
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(prefix)
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE")
        let event = starterRepositoryEvent(common.state, painBase: "incline_db_press_30")
        _ = try await s.repository.finalize(programID: s.programID, expectedRevision: common.state.revision, event: event, next: next)
        let chosen = try await s.repository.exportBackup().heads[common.state.config.programID]!
        _ = try await other.applyConfiguration(programID: s.programID, expectedRevision: common.state.revision,
            change: .minimumRir(baseMovementID: "db_lateral_raise", value: 5), next: next)
        _ = try await CloudIngestor(repository: s.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(await s.repository.exportBackup()))
        let resolved = try await s.repository.resolveConflict(programID: s.programID,
            expectedHeadHashes: proof.heads[common.state.config.programID]!,
            selection: BranchSelection(selectedHeadHash: chosen, configurationHeadHash: chosen), next: next)
        #expect(resolved.state.retainedSafety?["pull_up"]?.minimumRir == 4)
        #expect(resolved.state.retainedSafety?["incline_press"]?.paused == true)
        #expect(resolved.state.retainedSafety?["incline_press"]?.sourceEventIDs.contains(event.eventID) == true)
        #expect(resolved.state.retainedSafety?["db_lateral_raise"]?.minimumRir == 5)
        #expect(resolved.state.exercises.values.allSatisfy { $0.starterState!.windows.isEmpty && $0.normalSets == 2 })
        let graph = try await s.repository.exportBackup()
        let (clone, _) = try recoveryEmpty(); _ = try await clone.importBackup(graph)
        #expect(try await clone.snapshot(programID: s.programID).state == resolved.state)
    }
    @Test func futureAndTamperedPolicyOriginalsRemainUnsupported() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let originals = try BackupService.recoveryRecords(await s.repository.exportBackup())
        let root = try #require(originals.first { $0.recordType == CloudRecordKind.journal.recordType })
        var lastForged: ArchivedRecord?
        for kind in 0..<5 {
            var envelope = s.initial.history[0]
            switch kind {
            case 0: envelope.schemaVersion = 5; envelope.returnedState.schemaVersion = 5
            case 1: envelope.rulesetHash = String(repeating: "f", count: 64); envelope.returnedState.rulesetHash = envelope.rulesetHash
            case 2: envelope.profileHash = String(repeating: "f", count: 64); envelope.returnedState.config.profileHash = envelope.profileHash
            case 3: envelope.sourceProfileHash = String(repeating: "f", count: 64); envelope.returnedState.config.sourceProfileHash = envelope.sourceProfileHash
            default: envelope.sourceProfileHash = String(repeating: "f", count: 64)
            }
            envelope.envelopeHash = try BackupService.envelopeHash(envelope)
            let bytes = try BackupService.bytes(envelope)
            let forged = ArchivedRecord(observation: CloudObservation(recordID: root.recordID, zoneName: root.zoneName,
                recordType: root.recordType, claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
            lastForged = forged
            let proof = try RecoveryVerifier().verify(originals + [forged])
            #expect(proof.originals.contains(forged))
            #expect(proof.quarantined.contains { $0.record == forged && $0.reason == "unsupported_version" })
            #expect(CloudRecordCodec.recoveryCandidates([CloudObservation(recordID: forged.recordID, zoneName: forged.zoneName,
                recordType: forged.recordType, claimedChecksum: forged.claimedChecksum, payload: forged.bytes, systemFields: Data())]).first?.status == .unsupported)
        }
        let unsupported = try #require(lastForged)
        _ = try await recoveryRecords(s.repository) // Explicit synthetic dataset association only.
        _ = try await CloudIngestor(repository: s.repository).ingest([DownloadedCloudRecord(observation:
            CloudObservation(recordID: unsupported.recordID, zoneName: unsupported.zoneName, recordType: unsupported.recordType,
                claimedChecksum: unsupported.claimedChecksum, payload: unsupported.bytes, systemFields: Data()))], scope: recoveryScope)
        #expect(try await s.repository.snapshot(programID: s.programID).health == .unsupportedVersion)
        let exported = try await s.repository.exportBackup()
        #expect(exported.recovery?.originals.contains { $0.bytes == unsupported.bytes } == true)
        let (clone, _) = try recoveryEmpty(); _ = try await clone.importBackup(exported)
        #expect(try await clone.snapshot(programID: s.programID).health == .unsupportedVersion)
        #expect(try await clone.exportBackup().recovery?.originals.contains { $0.bytes == unsupported.bytes } == true)
    }
    @Test func removedLedgerDropRejectsEvenWithRecomputedHashes() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        _ = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: 0,
            change: .minimumRir(baseMovementID: "banded_pullups", value: 4),
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        _ = try await s.change(.wholeBodyGlutes)
        let before = try await s.repository.exportBackup()
        var forged = before
        var envelope = try JSONDecoder().decode(JournalEnvelope.self, from: forged.journal.last!.bytes)
        envelope.returnedState.retainedSafety!.removeValue(forKey: "pull_up")
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        forged.journal[forged.journal.count - 1] = try BackupService.object(envelope, id: envelope.eventID)
        forged.heads[envelope.programID] = envelope.envelopeHash
        #expect(throws: (any Error).self) { try BackupService.validate(forged) }
        let records = try BackupService.recoveryRecords(forged)
        let proof = try RecoveryVerifier().verify(records)
        #expect(proof.quarantined.contains { $0.record.bytes == forged.journal.last!.bytes && $0.reason == "replay_failed" })
        #expect(records.allSatisfy { proof.originals.contains($0) })
        #expect(try await s.repository.exportBackup() == before)
    }
    @Test func rehashedStarterArchivePoliciesAreRetainedUnsupported() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let document = try await s.repository.exportBackup()
        let dataset = UUID(uuidString: document.datasetID)!
        for archive in [document.rules[0], document.profiles.first { $0.id == StarterProgramCatalog.gluteProfileHash }!] {
            guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: archive.bytes) else { throw BackupService.invalid("fixture") }
            let key = fields["hash"] != nil ? "hash" : "contentHash"
            fields.removeValue(forKey: key)
            fields["unregisteredPolicyChange"] = .string("synthetic-tamper")
            let hash = try CanonicalJSON.sha256(.object(fields))
            fields[key] = .string(hash)
            let bytes = try CanonicalJSON.encode(.object(fields))
            let record = ArchivedRecord(observation: CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .archive, datasetID: dataset, identity: hash),
                zoneName: CloudRecordCodec.zoneID(dataset).zoneName, recordType: CloudRecordKind.archive.recordType,
                claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data()))
            let proof = try RecoveryVerifier().verify([record])
            #expect(proof.originals == [record])
            #expect(proof.quarantined.contains { $0.record == record && $0.reason == "unsupported_version" })
        }
    }
    @MainActor @Test func separateProgramDifferentProfileKeepsAccountSafetyGates() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let app = AppComposition(repository: s.repository, workout: nil, cloudCoordinator: nil)
        let destination = try selectStarterProgram(choice: .wholeBodyGlutes, goal: .size, programID: UUID())
        try await app.requireSafeNewProgram(destination, repository: s.repository)
        let old = try await s.repository.exportBackup()
        let new = try await s.repository.initialize(config: destination, rules: RulesetCatalog.starter(.wholeBodyGlutes),
            firstWorkout: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"), datasetID: UUID())
        #expect(new.state.lastSessionDate == nil && new.state.processedEvents.isEmpty)
        #expect(new.history.count == 1 && new.state.exercises.values.allSatisfy { $0.load == nil })
        #expect(try await s.repository.snapshot(programID: s.programID) == s.initial)
        #expect(old.journal.allSatisfy { original in (try? BackupService.bytes(s.initial.history[0])) == original.bytes })
        let restricted = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let restrictedApp = AppComposition(repository: restricted.repository, workout: nil, cloudCoordinator: nil)
        _ = try await restricted.repository.applyConfiguration(programID: restricted.programID, expectedRevision: 0,
            change: .minimumRir(baseMovementID: "banded_pullups", value: 4),
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
        _ = try await restricted.change(.wholeBodyGlutes)
        await #expect(throws: (any Error).self) { try await restrictedApp.requireSafeNewProgram(destination, repository: restricted.repository) }
        let draft = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        try await draft.repository.saveDraft(starterRepositoryDraft(draft.initial.state, kind: 0))
        let draftApp = AppComposition(repository: draft.repository, workout: nil, cloudCoordinator: nil)
        await #expect(throws: (any Error).self) { try await draftApp.requireSafeNewProgram(destination, repository: draft.repository) }
        let paused = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        _ = try await paused.repository.finalize(programID: paused.programID, expectedRevision: 0,
            event: starterRepositoryEvent(paused.initial.state, painBase: "incline_db_press_30"),
            next: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE"))
        let pausedApp = AppComposition(repository: paused.repository, workout: nil, cloudCoordinator: nil)
        await #expect(throws: (any Error).self) { try await pausedApp.requireSafeNewProgram(destination, repository: paused.repository) }
        let unknown = try await StarterRepositoryTestHarness.make(choice: .upperBody, goal: .size)
        let originals = try await recoveryRecords(unknown.repository)
        let root = try #require(originals.first { $0.observation.recordType == CloudRecordKind.journal.recordType }).observation
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: root.payload) else { throw BackupService.invalid("fixture") }
        fields["command"] = .object(["kind": .string("unregistered-future-command")])
        let raw = try CanonicalJSON.encode(.object(fields))
        _ = try await CloudIngestor(repository: unknown.repository).ingest([DownloadedCloudRecord(observation:
            CloudObservation(recordID: root.recordID, zoneName: root.zoneName, recordType: root.recordType,
                claimedChecksum: BackupService.hash(raw), payload: raw, systemFields: Data()))], scope: recoveryScope)
        let unknownApp = AppComposition(repository: unknown.repository, workout: nil, cloudCoordinator: nil)
        await #expect(throws: (any Error).self) { try await unknownApp.requireSafeNewProgram(destination, repository: unknown.repository) }
    }
}

extension StarterProgramRecoveryTests {
    @Test func samePolicyResolvedClearanceRemainsEffectiveAcrossSwitch() async throws {
        let s = try await StarterRepositoryTestHarness.make(choice: .wholeBodyGlutes, goal: .size)
        let prefix = try await s.repository.exportBackup()
        let (other, _) = try recoveryEmpty(); _ = try await other.importBackup(prefix)
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-13"), slotID: "TUE")
        let pain = starterRepositoryEvent(s.initial.state, painBase: "incline_db_press_30")
        let paused = try await s.repository.finalize(programID: s.programID, expectedRevision: 0, event: pain, next: next).snapshot
        _ = try await s.repository.applyConfiguration(programID: s.programID, expectedRevision: paused.state.revision,
            change: .safeResume(baseMovementID: "incline_db_press_30", externalClearanceConfirmed: true), next: next)
        let selected = try await s.repository.exportBackup().heads[s.initial.state.config.programID]!
        _ = try await other.applyConfiguration(programID: s.programID, expectedRevision: 0,
            change: .minimumRir(baseMovementID: "db_lateral_raise", value: 4), next: next)
        _ = try await CloudIngestor(repository: s.repository).ingest(recoveryRecords(other), scope: recoveryScope)
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(await s.repository.exportBackup()))
        let resolved = try await s.repository.resolveConflict(programID: s.programID,
            expectedHeadHashes: proof.heads[s.initial.state.config.programID]!,
            selection: BranchSelection(selectedHeadHash: selected, configurationHeadHash: selected), next: next)
        #expect(resolved.state.retainedSafety?["incline_press"]?.paused == false)
        #expect(resolved.state.retainedSafety?["incline_press"]?.sourceEventIDs == [pain.eventID])
        #expect(resolved.state.retainedSafety?["db_lateral_raise"]?.minimumRir == 4)
        let upper = try await s.change(.upperBody)
        #expect(upper.state.baseSafety?["incline_db_press_24"]?.paused == false)
        #expect(upper.state.baseSafety?["incline_db_press_24"]?.sourceEventIDs == [pain.eventID])
    }
}

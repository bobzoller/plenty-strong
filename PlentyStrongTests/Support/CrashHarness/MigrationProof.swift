import Foundation
import TrainingCore

/// Root-only proof in a fresh directory. Selection is explicitly a dry-run
/// condition, never a claim about user approval or historical native workouts.
func migrationProof(directory: URL, source: URL, documentURL: URL, selectionURL: URL) async throws {
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw BackupService.invalid("migration_proof_requires_fresh_directory") }
    var timings: [String: Double] = [:]
    var phaseStart = ProcessInfo.processInfo.systemUptime
    func phase(_ name: String) {
        let current = ProcessInfo.processInfo.systemUptime
        timings[name] = current - phaseStart; phaseStart = current
    }
    let originalBytes = try Data(contentsOf: documentURL)
    let selectionBytes = try Data(contentsOf: selectionURL)
    let document = try JSONDecoder().decode(ProgramMigrationDocument.self, from: originalBytes)
    guard try CloudRecordCodec.canonicalBytes(originalBytes) == BackupService.bytes(document) else { throw BackupService.invalid("migration_unknown_or_noncanonical_fields") }
    let selection = try JSONDecoder().decode(MigrationSelection.self, from: selectionBytes)
    try validateMigrationDocument(document)
    phase("decode_and_source_admission")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("training.store")
    let repository = try TrainingRepository.open(at: url, archiveDirectory: source)
    let preview = try await repository.previewMigration(document: document, selection: selection)
    phase("repository_preview")
    let receipt = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: preview.storeFingerprint)
    guard receipt.accepted == 1, receipt.snapshot.externalSource == document.source,
          receipt.snapshot.history.count == 1, receipt.snapshot.state.processedEvents.isEmpty,
          receipt.snapshot.state.lastSessionDate == nil,
          receipt.snapshot.state.exercises.values.allSatisfy({ $0.exactRepState?.lastSuitableNormalDate == nil }) else { throw BackupService.invalid("migration_proof_root") }
    phase("atomic_import_and_snapshot")
    let backup = try await repository.exportBackup()
    _ = try BackupService.validate(backup)
    phase("export_and_native_replay")
    let repeatedPreview = try await repository.previewMigration(document: document, selection: selection)
    let repeated = try await repository.importMigration(document: document, selection: selection, expectedStoreFingerprint: repeatedPreview.storeFingerprint)
    guard repeated.accepted == 0, repeated.identical == 1, repeated.snapshot == receipt.snapshot,
          try await repository.exportBackup() == backup else { throw BackupService.invalid("migration_proof_repeat") }
    phase("repeat_preview_import")
    await repository.close()
    let reopened = try TrainingRepository.open(at: url, archiveDirectory: source)
    guard try await reopened.snapshot(programID: receipt.programID) == receipt.snapshot,
          try await reopened.externalSourceArchive(hash: document.source.contentHash) == document.source else { throw BackupService.invalid("migration_proof_reopen") }
    phase("reopen_and_source_lookup")
    let portable = try await reopened.exportBackup()
    let portableBytes = try BackupService.bytes(portable)
    let backupURL = directory.appendingPathComponent("native-backup.json")
    try portableBytes.write(to: backupURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    let restored = try TrainingRepository.open(at: directory.appendingPathComponent("restored.store"), archiveDirectory: source)
    let imported = try await restored.importBackup(JSONDecoder().decode(BackupDocument.self, from: portableBytes))
    guard imported.accepted == 1, imported.conflicted == 0,
          try await restored.snapshot(programID: receipt.programID) == receipt.snapshot,
          try await restored.exportBackup() == portable else { throw BackupService.invalid("migration_proof_restore") }
    phase("native_backup_restore_and_equal_export")
    let shuffled = try RecoveryVerifier().verify(BackupService.recoveryRecords(portable).reversed())
    guard shuffled.waiting.isEmpty, shuffled.quarantined.isEmpty, shuffled.envelopes.count == 1 else { throw BackupService.invalid("migration_proof_recovery") }
    phase("shuffled_recovery_admission")
    guard try Data(contentsOf: documentURL) == originalBytes, try Data(contentsOf: selectionURL) == selectionBytes else { throw BackupService.invalid("migration_proof_input_changed") }
    let vectors = try document.checkpoint.baselines.map { baseline -> [String: Any] in
        guard let state = receipt.snapshot.state.exercises[baseline.variantID], state.exactRepState?.normalTargets == baseline.targets else { throw BackupService.invalid("migration_proof_current_targets") }
        return ["baseMovementID": baseline.baseMovementID, "variantID": baseline.variantID,
            "targets": baseline.targets, "normalSets": state.normalSets, "nativeFloor": state.repFloor,
            "nativeCeiling": state.repCeiling, "sourceFloor": baseline.sourceRepFloor, "sourceCeiling": baseline.sourceRepCeiling,
            "minimumRir": receipt.snapshot.state.baseSafety?[baseline.baseMovementID]?.minimumRir ?? baseline.minimumRir,
            "load": state.load.map { ["amount": $0.amount, "unit": $0.unit.rawValue, "basis": $0.basis.rawValue] } ?? [:]]
    }
    let report: [String: Any] = ["proof": "root-only-local-disposable", "goalAndBasis": "explicit dry-run conditions; not user approval",
        "documentSHA256": BackupService.hash(originalBytes), "canonicalDocumentHash": try BackupService.hash(document),
        "sourceArchiveHash": document.source.contentHash, "programID": receipt.programID.uuidString.lowercased(),
        "rootHash": receipt.rootHash, "schemaVersion": receipt.snapshot.state.schemaVersion,
        "rulesetVersion": receipt.snapshot.state.rulesetVersion, "rulesetHash": receipt.snapshot.state.rulesetHash,
        "sourceDates": document.source.workouts.count, "sourceExerciseRows": document.source.workouts.reduce(0) { $0 + $1.rows.count },
        "sourceFiles": document.source.files.map { ["name": $0.name, "sha256": $0.sha256, "byteCount": $0.bytes.count] },
        "phaseSeconds": timings, "nativeWorkoutCount": 0, "repeatIdentical": repeated.identical, "reopenEqual": true, "backupRestoreEqual": true,
        "shuffledRecoveryEqual": true, "nativeBackupSHA256": BackupService.hash(portableBytes), "currentVectors": vectors,
        "dryRunSelection": try JSONSerialization.jsonObject(with: selectionBytes),
        "pendingDate": receipt.snapshot.state.activePrescription.date.iso8601, "pendingSlot": receipt.snapshot.state.activePrescription.slotID,
        "pending": receipt.snapshot.state.activePrescription.exercises.map { ["baseMovementID": $0.baseMovementID ?? $0.movementID,
            "targets": $0.sets.compactMap(\.targetReps), "restSeconds": $0.restSeconds] }]
    let reportURL = directory.appendingPathComponent("migration-proof-report.json")
    try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: reportURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
    await reopened.close(); await restored.close()
    print("MIGRATION ROOT PROOF PASSED sourceDates=\(document.source.workouts.count) exerciseRows=\(document.source.workouts.reduce(0) { $0 + $1.rows.count }) report=\(reportURL.path)")
}

/// Read-only bounded measurements of a completed disposable root-only proof.
func migrationSnapshotTiming(directory: URL, source: URL) async throws {
    let reportURL = directory.appendingPathComponent("migration-proof-report.json")
    guard let proof = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any],
          proof["proof"] as? String == "root-only-local-disposable",
          let text = proof["programID"] as? String, let id = UUID(uuidString: text) else { throw BackupService.invalid("migration_timing_requires_disposable_proof") }
    let repository = try TrainingRepository.open(at: directory.appendingPathComponent("training.store"), archiveDirectory: source)
    let coldStart = ProcessInfo.processInfo.systemUptime
    let cold = try await repository.snapshot(programID: id)
    let coldSeconds = ProcessInfo.processInfo.systemUptime - coldStart
    guard cold.history.count == 1, cold.state.processedEvents.isEmpty, cold.externalSource != nil,
          cold.history.first?.envelopeHash == proof["rootHash"] as? String else { throw BackupService.invalid("migration_timing_not_root_only") }
    var warmSeconds: [Double] = []
    for _ in 0..<2 {
        let start = ProcessInfo.processInfo.systemUptime
        guard try await repository.snapshot(programID: id) == cold else { throw BackupService.invalid("migration_timing_snapshot_changed") }
        warmSeconds.append(ProcessInfo.processInfo.systemUptime - start)
    }
    let metadataStart = ProcessInfo.processInfo.systemUptime
    let rules = try await repository.rules(for: cold.state)
    let movement = try resolveEffectiveMovement(config: cold.state.config, variantID: cold.state.activePrescription.exercises[0].movementID, rules: rules)
    guard movement.id == cold.state.activePrescription.exercises[0].baseMovementID else { throw BackupService.invalid("migration_timing_metadata") }
    let metadataSeconds = ProcessInfo.processInfo.systemUptime - metadataStart
    let timings: [String: Any] = ["proof": "read-only-disposable-source-snapshot-timing", "coldSnapshotSeconds": coldSeconds,
        "warmSnapshotSeconds": warmSeconds, "rulesAndMovementMetadataSeconds": metadataSeconds,
        "sourceRawBytes": cold.externalSource!.files.reduce(0) { $0 + $1.bytes.count }, "nativeWorkoutCount": 0]
    let output = directory.appendingPathComponent("migration-snapshot-timing.json")
    try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    await repository.close()
    print("MIGRATION SNAPSHOT TIMING cold=\(coldSeconds) warm=\(warmSeconds) metadata=\(metadataSeconds) output=\(output.path)")
}

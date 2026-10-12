import Darwin
import Foundation
import TrainingCore

struct CrashInput: Codable {
    var programID: UUID
    var event: CompletedWorkout
    var next: WorkoutSlot
    var base: String
}
func run() async throws {
    let args = CommandLine.arguments
    guard args.count >= 4 else { throw BackupService.invalid("harness_arguments") }
    let mode = args[1]
    let directory = URL(fileURLWithPath: args[2], isDirectory: true)
    let source = URL(fileURLWithPath: args[3], isDirectory: true)
    if mode == "migration-snapshot-timing" {
        guard args.count == 4 else { throw BackupService.invalid("migration_timing_arguments") }
        try await migrationSnapshotTiming(directory: directory, source: source)
        return
    }
    if mode == "migration-proof" {
        guard args.count == 6 else { throw BackupService.invalid("migration_proof_arguments") }
        try await migrationProof(directory: directory, source: source,
            documentURL: URL(fileURLWithPath: args[4]), selectionURL: URL(fileURLWithPath: args[5]))
        return
    }
    let url = directory.appendingPathComponent("training.store")
    let inputURL = directory.appendingPathComponent("input.json")
    let repository = try TrainingRepository.open(at: url, archiveDirectory: source)
    if mode.hasPrefix("setup") {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var config = try selectFixedProgram(goal: .size, programID: id)
        for movement in config.movements { config.initialLoads[movement.id] = .some(movement.availableLoads.first) }
        let first = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: config.weeklySlots[0].id)
        let initial = try await repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        let p = initial.state.activePrescription
        let logs = p.exercises.map { row -> ExerciseLog in
            let movement = config.movements.first { $0.id == row.baseMovementID }!
            return ExerciseLog(movementID: row.movementID, prescriptionID: p.id, status: .completed, actualLoad: row.load,
                actualSets: row.sets.map { _ in ActualSet(reps: 10, leftReps: movement.repCounting == .perSide ? 10 : nil,
                    rightReps: movement.repCounting == .perSide ? 10 : nil) }, finalEffort: .onTarget, problem: .none,
                baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot)
        }
        let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var event = CompletedWorkout(eventID: eventID.uuidString.lowercased(), date: p.date, slotID: p.slotID, prescriptionID: p.id,
            plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs)
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-06"), slotID: config.weeklySlots[1].id)
        var draftLogs = logs
        if mode == "setup-correction" {
            draftLogs[0].actualSets[0].reps = 7
            if draftLogs[0].actualSets[0].leftReps != nil { draftLogs[0].actualSets[0].leftReps = 7 }
            if draftLogs[0].actualSets[0].rightReps != nil { draftLogs[0].actualSets[0].rightReps = 7 }
        }
        if mode == "setup-variant" { for i in draftLogs.indices { draftLogs[i].actualSets = []; draftLogs[i].finalEffort = .unknown } }
        if mode != "setup-activation" {
            try await repository.saveDraft(WorkoutDraft(id: eventID, programID: config.programID, expectedRevision: 0,
                planned: p, displayed: p, date: p.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal,
                logs: draftLogs, workingSetsStarted: mode != "setup-variant"))
        }
        if mode == "setup-freeze" {
            var draft = try await repository.snapshot(programID: id).draft!
            draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
            draft.flow = WorkoutFlow(forward: .workoutReview, reviewedSummaryMovementIDs: draft.logs.map(\.movementID))
            _ = try await repository.saveDraft(draft)
            var replacement = draft.logs[0].actualSets[0]; replacement.reps = 11
            if replacement.leftReps != nil { replacement.leftReps = 11 }
            if replacement.rightReps != nil { replacement.rightReps = 11 }
            draft = try await repository.correctDraftSet(programID: id, expectedDraftHash: BackupService.hash(draft), operationID: UUID(),
                movementID: draft.logs[0].movementID, setIndex: 0, replacement: replacement).draft!
            draft.flow!.reviewedSummaryMovementIDs = draft.logs.map(\.movementID)
            _ = try await repository.saveDraft(draft)
            event.exercises = draft.logs; event.observationAudit = draft.observationAudit
        }
        if mode == "setup-activation" || mode == "setup-correction" || mode == "setup-freeze" {
            try BackupService.bytes(await repository.exportBackup()).write(to: directory.appendingPathComponent("original-backup.json"))
        }
        try BackupService.bytes(CrashInput(programID: id, event: event, next: next, base: p.exercises[0].baseMovementID!)).write(to: inputURL)
        print("SETUP disk revision=0 journal/head/draft/outbox/quarantine=\(try await repository.counts())")
    } else {
        let input = try JSONDecoder().decode(CrashInput.self, from: Data(contentsOf: inputURL))
        if mode.hasPrefix("commit") {
            let phase = args[4]
            let marker = directory.appendingPathComponent("marker")
            await repository.observeCommits { observed in
                if observed == phase {
                    do { try Data(observed.utf8).write(to: marker, options: .atomic) }
                    catch { fatalError("Marker write failed: \(error)") }
                    // The scoped host kills this exact child while its writer is stopped.
                    while true { pause() }
                }
            }
            if mode == "commit-freeze" {
                let draft = try await repository.snapshot(programID: input.programID).draft!
                _ = try await repository.freezeDraftFinish(programID: input.programID, expectedDraftHash: BackupService.hash(draft),
                    submission: PendingWorkoutFinish(event: input.event, next: input.next, expectedRevision: draft.expectedRevision))
            } else if mode == "commit-correction" {
                let draft = try await repository.snapshot(programID: input.programID).draft!
                var replacement = draft.logs[0].actualSets[0]; replacement.reps = 8
                if replacement.leftReps != nil { replacement.leftReps = 8 }
                if replacement.rightReps != nil { replacement.rightReps = 8 }
                _ = try await repository.correctDraftSet(programID: input.programID, expectedDraftHash: BackupService.hash(draft),
                    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    movementID: draft.logs[0].movementID, setIndex: 0, replacement: replacement)
            } else if mode == "commit-activation" {
                let document = try await repository.exportBackup()
                _ = try await repository.activateExactPolicy(programID: input.programID, expectedRevision: 0, expectedHeadHash: document.heads[input.programID.uuidString.lowercased()]!)
            } else if mode == "commit-variant" {
                _ = try await repository.applyVariantChange(programID: input.programID, expectedRevision: 0,
                    change: .create(baseMovementID: input.base, variantID: "crash-variant", modifications: "Grip"),
                    next: input.next, invalidateEmptyDraft: true)
            } else {
                _ = try await repository.finalize(programID: input.programID, expectedRevision: 0, event: input.event, next: input.next)
            }
        } else if mode == "verify-freeze" {
            let expected = Int(args[4])!
            let original = try JSONDecoder().decode(BackupDocument.self, from: Data(contentsOf: directory.appendingPathComponent("original-backup.json")))
            let snapshot = try await repository.snapshot(programID: input.programID)
            let document = try await repository.exportBackup(), counts = try await repository.counts()
            guard snapshot.state.revision == 0, counts == [1,1,1,1,0], document.journal == original.journal,
                  document.heads == original.heads, document.rules == original.rules, document.profiles == original.profiles,
                  var draft = snapshot.draft else { throw BackupService.invalid("freeze_crash_atomicity") }
            if expected == 0 {
                guard draft.pendingFinish == nil, document == original else { throw BackupService.invalid("freeze_partial_commit") }
            } else {
                let pending = PendingWorkoutFinish(event: input.event, next: input.next, expectedRevision: 0)
                guard try BackupService.bytes(draft.pendingFinish) == BackupService.bytes(pending),
                      draft.pendingFinish?.event.observationAudit == draft.observationAudit else { throw BackupService.invalid("freeze_payload_atomicity") }
                draft.pendingFinish = nil
                guard try BackupService.bytes(draft) == original.drafts[0].bytes else { throw BackupService.invalid("freeze_unrelated_mutation") }
            }
            print("FRESH PROCESS VERIFIED freeze=\(expected) exact event/audit/next/revision; unchanged journal/head/outbox counts=\(counts)")
        } else if mode == "verify-correction" {
            let expected = Int(args[4])!
            let original = try JSONDecoder().decode(BackupDocument.self, from: Data(contentsOf: directory.appendingPathComponent("original-backup.json")))
            let originalDraft = try JSONDecoder().decode(WorkoutDraft.self, from: original.drafts[0].bytes)
            let snapshot = try await repository.snapshot(programID: input.programID)
            let document = try await repository.exportBackup(), counts = try await repository.counts()
            guard snapshot.state.revision == 0, counts == [1,1,1,1,0],
                  document.journal == original.journal, document.heads == original.heads,
                  document.rules == original.rules, document.profiles == original.profiles,
                  let draft = snapshot.draft else { throw BackupService.invalid("correction_crash_atomicity") }
            if expected == 0 {
                guard document == original, try BackupService.bytes(draft) == BackupService.bytes(originalDraft) else {
                    throw BackupService.invalid("correction_partial_commit")
                }
            } else {
                guard draft.logs[0].actualSets[0].reps == 8, let audit = draft.observationAudit, audit.corrections.count == 1,
                      audit.corrections[0].before.reps == 7, audit.corrections[0].after.reps == 8,
                      try ObservationAuditValidator.originalLogs(effective: draft.logs, audit: audit, prescription: draft.displayed,
                        config: snapshot.state.config, schemaVersion: snapshot.state.schemaVersion) == originalDraft.logs else {
                    throw BackupService.invalid("correction_trail_atomicity")
                }
                var restored = draft; restored.logs = originalDraft.logs; restored.observationAudit = nil
                guard try BackupService.bytes(restored) == BackupService.bytes(originalDraft) else {
                    throw BackupService.invalid("correction_unrelated_mutation")
                }
            }
            print("FRESH PROCESS VERIFIED correction=\(expected) revision=0 journal/head/draft/outbox/quarantine=\(counts); original/trail atomic; unchanged journal/head/outbox")
        } else if mode == "verify" || mode == "verify-variant" || mode == "verify-activation" {
            let expected = Int(args[4])!
            let snapshot = try await repository.snapshot(programID: input.programID)
            let counts = try await repository.counts()
            let expectedCounts = expected == 0 ? [1,1,mode == "verify-activation" ? 0 : 1,1,0] : [2,1,0,2,0]
            guard snapshot.state.revision == expected, counts == expectedCounts else { throw BackupService.invalid("crash_atomicity") }
            if mode == "verify-activation" {
                let document = try await repository.exportBackup()
                let original = try JSONDecoder().decode(BackupDocument.self, from: Data(contentsOf: directory.appendingPathComponent("original-backup.json")))
                guard snapshot.state.schemaVersion == (expected == 0 ? 2 : 3),
                      document.journal.first == original.journal.first,
                      original.rules.allSatisfy({ document.rules.contains($0) }),
                      document.rules.count == (expected == 0 ? 1 : 2),
                      document.heads[input.programID.uuidString.lowercased()] == snapshot.history.last?.envelopeHash else { throw BackupService.invalid("activation_crash_atomicity") }
                if expected == 0 { guard document == original else { throw BackupService.invalid("activation_partial_commit") } }
                else {
                    guard case .activatePolicy = snapshot.history.last!.command,
                          snapshot.history.last!.inputStateHash == (try BackupService.hash(snapshot.history.first!.returnedState)),
                          snapshot.state.activePrescription.exercises.allSatisfy({ $0.sets.allSatisfy { $0.targetReps == 8 } }) else { throw BackupService.invalid("activation_chain") }
                }
            }
            if mode == "verify-variant" {
                guard (snapshot.state.config.activeVariantIDs![input.base] == "crash-variant") == (expected == 1),
                      (snapshot.state.exercises["crash-variant"] != nil) == (expected == 1) else { throw BackupService.invalid("variant_crash_atomicity") }
            }
            print("FRESH PROCESS VERIFIED revision=\(expected) journal/head/draft/outbox/quarantine=\(counts) full archived replay passed")
        } else if mode == "verify-cloud-metadata" {
            let before = try await repository.snapshot(programID: input.programID)
            let backup = try await repository.exportBackup()
            let scope = CloudScope(containerIdentifier: "synthetic", environment: .development, accountIdentifier: "old-store-test")
            try await repository.bindDataset(datasetID: UUID(uuidString: backup.datasetID)!, to: scope)
            let pending = try await repository.pendingCloudRecords(scope: scope)
            guard pending.count == 4, let item = pending.first else { throw BackupService.invalid("old_store_pending") }
            try await repository.saveCloudCursor(Data([1,2,3]), scope: scope)
            try await repository.acknowledge(records: [.init(recordID: item.recordID, verifiedHash: item.checksum, systemFields: Data([4,5]))], scope: scope)
            await repository.close()
            let reopened = try TrainingRepository.open(at: url, archiveDirectory: source)
            guard try await reopened.snapshot(programID: input.programID) == before,
                  try await reopened.exportBackup() == backup,
                  try await reopened.cloudCursor(scope: scope) == Data([1,2,3]),
                  try await reopened.pendingCloudRecords(scope: scope).count == 3,
                  try await reopened.cloudMetadata(scope: scope).acknowledgements[item.recordID]?.systemFields == Data([4,5]) else { throw BackupService.invalid("old_store_cloud_reopen") }
            await reopened.close()
            print("OLD BINARY STORE VERIFIED: training/draft/backup unchanged; binding/cursor/ack/system fields durable after reopen")
        } else { throw BackupService.invalid("harness_mode") }
    }
    await repository.close()
}
do { try await run() }
catch { fputs("CRASH HARNESS FAILED: \(error)\n", stderr); exit(1) }

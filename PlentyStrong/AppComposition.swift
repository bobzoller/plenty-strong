import Foundation
import Observation
import CloudKit
import TrainingCore

@MainActor @Observable final class AppComposition {
    let tips: TipStore
    private let operations: TrainingOperationGate
    var busy: Bool { operations.busy }
    private(set) var repository: TrainingRepository?
    private(set) var workout: WorkoutViewModel?
    private(set) var readOnlyProgram: StoreSnapshot?
    var errorText: String?
    var showingWorkout = false
    private(set) var loaded = false
    private(set) var optionalServicesUnavailable = false
    private var uiTesting = false
    private(set) var cloudStatus = SyncStatus()
    private(set) var cloudEnabled = false
    private(set) var recoveryPrograms: [RecoveryProgramSummary] = []
    private(set) var discoveryCandidates: [RecoveryCandidate] = []
    private(set) var recoveryMessage: String?
    private var cloudCoordinator: CloudSyncCoordinator?
    private var preferences = CloudRecoveryPreferences()
    private var preferencesURL: URL?
    private var cloudGeneration = 0
    // Root consent can expire without invalidating fresh incoming account data.
    private var selectionGeneration = 0
    private var stagedScope: CloudScope?
    private var verifiedCloudScope: CloudScope?
    private var stagedRecords: [DownloadedCloudRecord] = []
    private var lastIngestedObservations: Set<String> = []
    private var adoptingCloud = false
    var now: () -> Date = Date.init
    var timeZoneID = TimeZone.current.identifier
    #if DEBUG
    // Injection-only checkpoints outside the synchronous repository transaction.
    var restoreBeforeImportForTesting: (@MainActor () async throws -> Void)?
    var restoreBeforeAdoptionForTesting: (@MainActor () async throws -> Void)?
    var selectionBeforeAdoptionForTesting: (@MainActor () async throws -> Void)?
    #endif

    init(repository: TrainingRepository? = nil, workout: WorkoutViewModel? = nil, cloudCoordinator: CloudSyncCoordinator? = nil, preferencesURL: URL? = nil, tipStore: TipStore? = nil) {
        if let tipStore { tips = tipStore }
        else {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let synthetic = arguments.contains("-ui-testing") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
            if synthetic {
                let commerce = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PlentyStrong-Synthetic-Commerce", isDirectory: true)
                if arguments.contains("-reset-local-store"), FileManager.default.fileExists(atPath: commerce.path) { try? FileManager.default.removeItem(at: commerce) }
                let purchaser: any TipPurchasing = arguments.contains("-local-storekit-tips") ? StoreKitTipPurchaser() : UnavailableTipPurchaser()
                tips = TipStore(purchaser: purchaser, receiptURL: commerce.appendingPathComponent("receipts-v1.json"))
            } else { tips = TipStore(purchaser: StoreKitTipPurchaser()) }
            #else
            tips = TipStore(purchaser: StoreKitTipPurchaser())
            #endif
        }
        self.repository = repository; self.workout = workout; loaded = repository != nil
        if let workout, !AppTrainingCompatibility.supports(workout.snapshot) { self.workout = nil; readOnlyProgram = workout.snapshot }
        operations = workout?.operations ?? TrainingOperationGate()
        self.cloudCoordinator = cloudCoordinator; self.preferencesURL = preferencesURL
        operations.afterRelease = { [weak self] in self?.scheduleStagedIngestion() }
    }
    #if DEBUG
    var syntheticBackupURL: URL? {
        guard uiTesting else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("PlentyStrong-Synthetic-Recovery.json")
    }
    #endif
    func exportBackupFile() async throws -> URL {
        guard let repository else { throw EngineError(code: "repository_unavailable", field: "backup") }
        let bytes = try BackupService.bytes(await repository.exportBackup())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlentyStrong-Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("PlentyStrong-losslessJSON.json")
        try bytes.write(to: url, options: .atomic)
        #if DEBUG
        if let recovery = syntheticBackupURL { try bytes.write(to: recovery, options: .atomic) }
        #endif
        return url
    }
    func restoreBackupData(_ data: Data) async throws -> ImportReceipt {
        guard !busy else { throw EngineError(code: "operation_in_progress", field: "backup") }
        guard workout?.busy != true else { throw BackupUIError.protectedWorkout }
        return try await operations.perform { operation in
            try await restoreBackupDataBody(data, operation: operation)
        }
    }
    private func restoreBackupDataBody(_ data: Data, operation: TrainingOperationGate.Lease) async throws -> ImportReceipt {
        guard let repository else { throw EngineError(code: "repository_unavailable", field: "backup") }
        let document: BackupDocument
        do { document = try JSONDecoder().decode(BackupDocument.self, from: data); _ = try BackupService.validate(document) }
        catch { throw BackupUIError.invalid(error) }
        guard document.heads.count == 1 else { throw BackupUIError.oneProgramRequired }
        guard try await repository.exportBackup().drafts.isEmpty else { throw BackupUIError.protectedWorkout }
        if let workout {
            guard workout.canEditProgramSettings else { throw BackupUIError.protectedWorkout }
            guard document.heads.keys.first == workout.snapshot.state.config.programID else { throw BackupUIError.differentProgram }
            #if DEBUG
            try await restoreBeforeImportForTesting?()
            #endif
            let receipt = try await workout.restoreBackup(document, operation: operation)
            try await installSelectedSnapshot(workout.snapshot, repository: repository, operation: operation)
            return receipt
        }
        if let readOnlyProgram {
            guard document.heads.keys.first == readOnlyProgram.state.config.programID else { throw BackupUIError.differentProgram }
        }
        // Empty-store recovery occurs before onboarding creates a competing dataset.
        #if DEBUG
        try await restoreBeforeImportForTesting?()
        #endif
        let receipt = try await repository.importBackup(document)
        #if DEBUG
        try await restoreBeforeAdoptionForTesting?()
        #endif
        if receipt.conflicted == 0, let id = document.heads.keys.first, let uuid = UUID(uuidString: id) {
            try await installSelectedSnapshot(try await repository.snapshot(programID: uuid), repository: repository, operation: operation)
        }
        return receipt
    }
    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            try await operations.perform { operation in
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                var directory = base.appendingPathComponent("PlentyStrong", isDirectory: true)
                #if DEBUG
                uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
                if uiTesting {
                    // Dedicated, stable synthetic store. Release has no reset/clock override path.
                    directory = base.appendingPathComponent("PlentyStrong-Synthetic-UITests", isDirectory: true)
                    if ProcessInfo.processInfo.arguments.contains("-reset-local-store"), FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.removeItem(at: directory)
                    }
                    let arguments = ProcessInfo.processInfo.arguments
                    let offset: TimeInterval
                    if let index = arguments.firstIndex(of: "-ui-clock-offset"), arguments.indices.contains(index + 1),
                       let value = TimeInterval(arguments[index + 1]), value.isFinite { offset = value } else { offset = 0 }
                    now = { Date(timeIntervalSince1970: 1791316800 + offset) }
                    #if targetEnvironment(simulator)
                    if arguments.contains("-fixture-starter-intro") { now = { ISO8601DateFormatter().date(from: "2026-10-18T20:00:00Z")! } }
                    if arguments.contains("-fixture-exact-reps") { now = { ISO8601DateFormatter().date(from: "2026-10-08T20:00:00Z")!.addingTimeInterval(offset) } }
                    #endif
                    timeZoneID = "Pacific/Honolulu"
                    optionalServicesUnavailable = ProcessInfo.processInfo.arguments.contains("-cloud-disabled") || ProcessInfo.processInfo.arguments.contains("-products-unavailable")
                }
                #endif
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let repository = try TrainingRepository.open(at: directory.appendingPathComponent("training.store"))
                self.repository = repository
                let backup = try await repository.exportBackup()
                preferencesURL = directory.appendingPathComponent("recovery-preferences.json")
                if let url = preferencesURL, FileManager.default.fileExists(atPath: url.path) { preferences = (try? JSONDecoder().decode(CloudRecoveryPreferences.self, from: Data(contentsOf: url))) ?? .init() }
                cloudEnabled = preferences.enabled
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                #if targetEnvironment(simulator)
                if uiTesting, backup.heads.isEmpty, arguments.contains("-fixture-starter-intro") {
                    try await seedStarterIntroduction(repository)
                }
                if uiTesting, backup.heads.isEmpty, arguments.contains("-fixture-exact-reps") {
                    let modeIndex = arguments.firstIndex(of: "-fixture-exact-mode")
                    let mode = modeIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "normal"
                    try await seedExactHistory(repository, mode: mode)
                }
                #endif
                if uiTesting, backup.heads.isEmpty,
                   let index = arguments.firstIndex(of: "-fixture"), arguments.indices.contains(index + 1), (["history-10-10-9", "cloud-pending", "cloud-quota", "cloud-conflict", "cloud-partial"].contains(arguments[index + 1])) {
                    try await seedHistory(repository)
                    if arguments[index + 1] == "cloud-conflict" { try await seedCloudConflict(repository) }
                    if arguments[index + 1] == "cloud-partial" { try await seedPartialRecovery(repository) }
                }
                #endif
                #if DEBUG
                if uiTesting, backup.heads.isEmpty, let index = arguments.firstIndex(of: "-fixture"),
                   arguments.indices.contains(index + 1), arguments[index + 1] == "legacy-numeric" {
                    try await seedLegacyArchive(repository)
                }
                #endif
                let restored = try await repository.exportBackup()
                #if DEBUG
                if uiTesting, arguments.contains("-ui-fixture-unsupported-backup"), let url = syntheticBackupURL {
                    var unsupported = restored; unsupported.formatVersion = 99
                    try BackupService.bytes(unsupported).write(to: url, options: .atomic)
                }
                #endif
                try await restoreProgramSelection(operation: operation)
                if let model = workout, model.snapshot.health == .ready { try await model.prepareToday(operation: operation) }
            }
            do { try await installRecoveryServices() } catch { cloudStatus = .init(phase: .accountUnavailable); recoveryMessage = "Recovery configuration could not be opened. Local training is retained." }
            try await refreshRecoveryPrograms()
            if cloudEnabled {
                #if DEBUG
                await resumeRecovery(allowAssociation: uiTesting && ProcessInfo.processInfo.arguments.contains("-fixture"))
                #else
                await resumeRecovery()
                #endif
            }
        } catch { errorText = "Local training could not be opened. Your stored data has been retained. \(error)" }
    }
    #if DEBUG
    #if targetEnvironment(simulator)
    /// Disposable simulator-only records, produced by the same journal writer and
    /// core transitions as real local training. Optional services remain inert.
    private func seedStarterIntroduction(_ repository: TrainingRepository) async throws {
        var config = try selectStarterProgram(choice: .wholeBodyGlutes, goal: .size, programID: UUID())
        config.initialLoads["db_romanian_deadlift"] = Load(amount: "15", unit: .lb, basis: .perImplement)
        let rules = try RulesetCatalog.starter(.wholeBodyGlutes)
        let id = UUID(uuidString: config.programID)!
        var snapshot = try await repository.initialize(config: config, rules: rules,
            firstWorkout: WorkoutSlot(date: LocalDate(iso8601: "2026-10-04"), slotID: "SUN"))
        for nextDate in ["2026-10-11", "2026-10-18"] {
            let p = snapshot.state.activePrescription
            let logs = p.exercises.enumerated().map { index, row in
                ExerciseLog(movementID: row.movementID, prescriptionID: p.id, status: index == 0 ? .completed : .skipped,
                    actualLoad: index == 0 ? row.load : nil, actualSets: index == 0 ? row.sets.enumerated().map { ActualSet(reps: $0.element.targetReps!, setIndex: $0.offset) } : [],
                    finalEffort: index == 0 ? .onTarget : .unknown, problem: .none, baseMovementID: row.baseMovementID,
                    modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
            }
            let event = CompletedWorkout(eventID: UUID().uuidString.lowercased(), date: p.date, slotID: p.slotID,
                prescriptionID: p.id, plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs)
            let receipt = try await repository.finalize(programID: id, expectedRevision: snapshot.state.revision, event: event,
                next: WorkoutSlot(date: LocalDate(iso8601: nextDate), slotID: "SUN"))
            guard case .applied = receipt.result else { throw BackupService.invalid("starter_intro_fixture") }
            snapshot = receipt.snapshot
        }
    }
    private func seedExactHistory(_ repository: TrainingRepository, mode: String) async throws {
        guard ["normal", "no-history", "baseline", "legacy-unfinished", "easier", "per-side", "setup-review"].contains(mode) else { throw BackupService.invalid("exact_fixture_mode") }
        var config = try selectFixedProgram(goal: .size, programID: UUID())
        let firstBase = "incline_db_press_24"
        let load = Load(amount: mode == "setup-review" ? "5" : "40", unit: .lb, basis: .perImplement)
        config.initialLoads[firstBase] = load
        let legacy = mode == "legacy-unfinished"
        let fresh = ["no-history", "baseline", "legacy-unfinished", "per-side"].contains(mode)
        let rules = try legacy ? RulesetCatalog.fixedV1() : RulesetCatalog.exactV1()
        let first = WorkoutSlot(date: try LocalDate(iso8601: mode == "per-side" ? "2026-10-06" : fresh ? "2026-10-08" : "2026-10-01"), slotID: mode == "per-side" ? "TUE" : "THU")
        var snapshot = try await repository.initialize(config: config, rules: rules, firstWorkout: first)
        if !fresh {
            for (date, slot) in [("2026-10-04", "SUN"), ("2026-10-08", "THU")] {
                let prescription = snapshot.state.activePrescription
                let logs = prescription.exercises.enumerated().map { index, row in
                    ExerciseLog(movementID: row.movementID, prescriptionID: prescription.id, status: index == 0 ? .completed : .skipped,
                        actualLoad: index == 0 ? load : nil,
                        actualSets: index == 0 ? (mode == "setup-review" ? [1,1,1] : [10,10,9]).enumerated().map {
                            ActualSet(reps: $0.element, setIndex: $0.offset, missedGoalReason: mode == "setup-review" ? .effortLimit : nil)
                        } : [], finalEffort: index == 0 ? (mode == "setup-review" ? .tooHard : .onTarget) : .unknown, problem: .none,
                        baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
                }
                let event = CompletedWorkout(eventID: UUID().uuidString.lowercased(), date: prescription.date, slotID: prescription.slotID, prescriptionID: prescription.id, plannedPrescriptionID: prescription.id, sessionMode: .normal, exercises: logs)
                let receipt = try await repository.finalize(programID: UUID(uuidString: config.programID)!, expectedRevision: snapshot.state.revision, event: event, next: WorkoutSlot(date: LocalDate(iso8601: date), slotID: slot))
                guard case .applied = receipt.result else { throw BackupService.invalid("exact_fixture_rejected") }
                snapshot = receipt.snapshot
            }
        }
        if legacy || mode == "easier" {
            let model = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: "Pacific/Honolulu", now: now)
            try await model.start(easierToday: mode == "easier")
        }
        if mode == "per-side" {
            let planned = snapshot.state.activePrescription
            let displayed = try prepareWorkout(state: snapshot.state, rules: rules)
            let logs = displayed.exercises.map { row in
                ExerciseLog(movementID: row.movementID, prescriptionID: displayed.id, status: .partial, actualLoad: nil, actualSets: [], finalEffort: .unknown, problem: .none, baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot, effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
            }
            try await repository.saveDraft(WorkoutDraft(id: UUID(), programID: config.programID, expectedRevision: snapshot.state.revision, planned: planned, displayed: displayed, date: planned.date, timeZoneID: "Pacific/Honolulu", sessionMode: .normal, logs: logs, workingSetsStarted: false, acknowledgedMovementIDs: []))
        }
    }
    #endif
    private func fixtureRecords(_ source: TrainingRepository, scope: CloudScope) async throws -> [DownloadedCloudRecord] {
        let document = try await source.exportBackup()
        try await source.bindDataset(datasetID: UUID(uuidString: document.datasetID)!, to: scope)
        return try await source.pendingCloudRecords(scope: scope).map { record in
            DownloadedCloudRecord(observation: CloudObservation(recordID: record.recordID, zoneName: CloudRecordCodec.zoneID(record.datasetID).zoneName, recordType: record.kind.recordType, claimedChecksum: record.checksum, payload: record.payload, systemFields: Data()))
        }
    }
    private func seedCloudConflict(_ repository: TrainingRepository) async throws {
        let document = try await repository.exportBackup()
        let envelopes = try document.journal.map { try JSONDecoder().decode(JournalEnvelope.self, from: $0.bytes) }
        guard let root = envelopes.first(where: { $0.parentEnvelopeHash == nil }), let original = envelopes.first(where: { CloudRecordCodec.isWorkout($0.command) }), case let .workout(originalEvent, next) = original.command else { throw BackupService.invalid("fixture") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let remote = try TrainingRepository.open(at: directory.appendingPathComponent("remote.store"))
        let base = BackupDocument(datasetID: root.datasetID, heads: [root.programID: root.envelopeHash], journal: [try BackupService.object(root, id: root.eventID)], rules: document.rules, profiles: document.profiles, drafts: [])
        _ = try await remote.importBackup(base)
        var event = originalEvent
        event.eventID = UUID().uuidString.lowercased()
        for index in event.exercises.indices { event.exercises[index].problem = .none }
        _ = try await remote.finalize(programID: UUID(uuidString: root.programID)!, expectedRevision: 0, event: event, next: next)
        let scope = CloudScope(containerIdentifier: "synthetic-ui", environment: .development, accountIdentifier: "synthetic-A")
        _ = try await CloudIngestor(repository: repository).ingest(fixtureRecords(remote, scope: scope), scope: scope)
        await remote.close()
    }
    private func seedPartialRecovery(_ repository: TrainingRepository) async throws {
        // A known-schema incoming child waits for an absent parent; existing
        // original projection remains visible but cannot progress.
        let document = try await repository.exportBackup()
        guard let item = document.journal.first(where: { (try? JSONDecoder().decode(JournalEnvelope.self, from: $0.bytes)).map { CloudRecordCodec.isWorkout($0.command) } == true }) else { throw BackupService.invalid("fixture") }
        var child = try JSONDecoder().decode(JournalEnvelope.self, from: item.bytes)
        child.eventID = UUID().uuidString.lowercased(); child.parentEnvelopeHash = String(repeating: "a", count: 64)
        child.envelopeHash = try BackupService.envelopeHash(child)
        let bytes = try BackupService.bytes(child), dataset = UUID(uuidString: child.datasetID)!
        let observation = CloudObservation(recordID: try CloudRecordCodec.recordName(kind: .journal, datasetID: dataset, identity: child.eventID), zoneName: CloudRecordCodec.zoneID(dataset).zoneName, recordType: "JournalV1", claimedChecksum: BackupService.hash(bytes), payload: bytes, systemFields: Data())
        let scope = CloudScope(containerIdentifier: "synthetic-ui", environment: .development, accountIdentifier: "synthetic-A")
        _ = try await CloudIngestor(repository: repository).ingest([DownloadedCloudRecord(observation: observation)], scope: scope)
    }
    private func seedLegacyArchive(_ repository: TrainingRepository) async throws {
        // Synthetic schema-1 accepted archive; its omitted app fields stay omitted.
        let rules = try RulesetCatalog.numericV02(), program = UUID(), dataset = UUID()
        let load = Load(amount: "40.1", unit: .kg, basis: .total)
        let movement = Movement(id: "synthetic-legacy-lift", name: "Synthetic archived lift", primaryMuscles: ["back"], secondaryMuscles: [], minimumRir: 2, availableLoads: [load])
        var profile: [String: CanonicalValue] = ["schemaVersion": .integer(1), "profileId": .string("synthetic-prevariant"), "purpose": .string("Synthetic accepted archive UI fixture")]
        let profileHash = try CanonicalJSON.sha256(.object(profile)); profile["contentHash"] = .string(profileHash)
        let profileBytes = try CanonicalJSON.encode(.object(profile))
        let config = ProgramConfig(programID: program.uuidString.lowercased(), goal: .size, daysPerWeek: 2, movements: [movement],
            weeklySlots: [WeeklySlot(id: "A", movementIDs: [movement.id]), WeeklySlot(id: "B", movementIDs: [movement.id])], requiredMuscleGroups: ["back"], initialLoads: [movement.id: load])
        let slot = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: "A")
        let initialized = try initializeProgram(config: config, rules: rules, firstWorkout: slot)
        let command = JournalCommand.initialize(config: config, firstWorkout: slot)
        var envelope = JournalEnvelope(schemaVersion: 1, datasetID: dataset.uuidString.lowercased(), programID: config.programID, eventID: UUID().uuidString.lowercased(),
            eventHash: try BackupService.eventHash(command), parentEnvelopeHash: nil, inputRevision: -1, inputStateHash: nil,
            rulesetVersion: rules.version, rulesetHash: rules.hash, profileID: "synthetic-prevariant", profileHash: profileHash, sourceProfileID: "synthetic-prevariant", sourceProfileHash: profileHash,
            command: command, returnedState: initialized.state, returnedPrescription: initialized.workout, decisions: [], envelopeHash: "")
        envelope.envelopeHash = try BackupService.envelopeHash(envelope)
        var document = BackupDocument(datasetID: envelope.datasetID, heads: [config.programID: envelope.envelopeHash], journal: [try BackupService.object(envelope, id: envelope.eventID)],
            rules: [try BackupService.object(rules, id: rules.hash)], profiles: [ArchivedObject(id: profileHash, bytes: profileBytes, checksum: BackupService.hash(profileBytes))], drafts: [])
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
        document.formatVersion = 2
        document.recovery = BackupService.graphManifest(proof, originals: [], quarantines: [], resolved: [])
        _ = try await repository.importBackup(document)
    }
    private func seedHistory(_ repository: TrainingRepository) async throws {
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let first = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-04"), slotID: config.weeklySlots[0].id)
        let initial = try await repository.initialize(config: config, rules: RulesetCatalog.fixedV1(), firstWorkout: first)
        let p = initial.state.activePrescription
        let logs = p.exercises.enumerated().map { index, row -> ExerciseLog in
            let movement = config.movements.first { $0.id == row.baseMovementID }!
            let reps = index == 0 ? [10, 10, 9] : index == 3 ? [13, 13, 13] : [8]
            return ExerciseLog(movementID: row.movementID, prescriptionID: p.id,
                status: index == 1 ? .partial : index == 2 ? .stopped : .completed,
                actualLoad: movement.loadingMode == .externalLoad ? movement.availableLoads.first : nil,
                actualSets: (index == 4 ? [10, 10, 10] : reps).map { ActualSet(reps: $0, leftReps: movement.repCounting == .perSide ? $0 : nil, rightReps: movement.repCounting == .perSide ? $0 : nil) },
                finalEffort: .onTarget, problem: index == 2 ? .pain : .none, baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot)
        }
        let event = CompletedWorkout(eventID: UUID().uuidString.lowercased(), date: p.date, slotID: p.slotID, prescriptionID: p.id, plannedPrescriptionID: p.id, sessionMode: .normal, exercises: logs)
        let next = WorkoutSlot(date: try LocalDate(iso8601: "2026-10-06"), slotID: config.weeklySlots[1].id)
        let receipt = try await repository.finalize(programID: UUID(uuidString: config.programID)!, expectedRevision: initial.state.revision, event: event, next: next)
        if case let .rejected(_, errors) = receipt.result { throw EngineError(code: errors.joined(separator: ","), field: "syntheticSeed") }
    }
    #endif
    func confirm(choice: StarterProgramChoice, goal: Goal) async {
        guard let repository, workout == nil, readOnlyProgram == nil, errorText == nil, !busy else { return }
        do {
            try await operations.perform { operation in
                #if DEBUG
                let legacyRepairFixture = uiTesting && ProcessInfo.processInfo.arguments.contains("-ui-fixture-malformed-completion")
                let config = try legacyRepairFixture ? selectFixedProgram(goal: goal, programID: UUID()) : selectStarterProgram(choice: choice, goal: goal, programID: UUID())
                #else
                let config = try selectStarterProgram(choice: choice, goal: goal, programID: UUID())
                #endif
                try await requireSafeNewProgram(config, repository: repository)
                let today = try CalendarContext(timeZoneID: timeZoneID).localDate(at: now())
                let first = try WorkoutScheduler.nextSlot(onOrAfter: today, config: config)
                #if DEBUG
                let initializationRules = try legacyRepairFixture ? RulesetCatalog.fixedV1() : RulesetCatalog.starter(choice)
                #else
                let initializationRules = try RulesetCatalog.starter(choice)
                #endif
                let snapshot = try await repository.initialize(config: config, rules: initializationRules, firstWorkout: first)
                #if DEBUG
                workout = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: timeZoneID, now: now, operations: operations, activatesExactPolicy: !legacyRepairFixture)
                #else
                workout = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: timeZoneID, now: now, operations: operations, activatesExactPolicy: true)
                #endif
                #if DEBUG
                if legacyRepairFixture, let model = workout {
                    // Synthetic restored-draft regression fixture, created through the real writer.
                    // Only during fresh test-program initialization; existing stores are never seeded.
                    try await model.start(easierToday: false, operation: operation)
                    var draft = model.snapshot.draft!
                    draft.acknowledgedMovementIDs = draft.logs.map(\.movementID)
                    for i in draft.logs.indices { draft.logs[i].status = .completed }
                    draft.logs[0].actualLoad = model.movement(for: draft.displayed.exercises[0]).availableLoads[0]
                    draft.logs[0].actualSets = [ActualSet(reps: 4, setIndex: draft.planned.exercises[0].sets.first?.targetReps != nil ? 0 : nil)]
                    draft.logs[0].problem = .pain; draft.workingSetsStarted = true
                    try await repository.saveDraft(draft)
                    workout = WorkoutViewModel(repository: repository, snapshot: try await repository.snapshot(programID: model.programID), timeZoneID: timeZoneID, now: now, operations: operations, activatesExactPolicy: true)
                }
                #endif
            }
        } catch { errorText = "Could not save your program. \(error)" }
        if cloudEnabled, workout != nil { await resumeRecovery(allowAssociation: true) }
    }
}

private enum BackupUIError: LocalizedError {
    case invalid(any Error), oneProgramRequired, differentProgram, protectedWorkout, retainedRestrictions
    var errorDescription: String? {
        switch self {
        case let .invalid(error): "The JSON backup is unsupported or corrupt. Original data is retained. \(error)"
        case .oneProgramRequired: "This app supports a backup containing exactly one program. Original data is retained."
        case .protectedWorkout: "Finish your protected workout safely before restoring. Your saved observations are retained."
        case .retainedRestrictions: "This version cannot create a separate program while retained programs need recovery review, contain a saved workout, or have safety restrictions beyond the new defaults. Existing local programs and exports remain available."
        case .differentProgram: "This backup belongs to a different program. Restore it into an empty installation; your current program is retained."
        }
    }
}

extension AppComposition {
    func reloadLocalProductChoices() async throws {
        try await operations.perform { operation in
            if let url = preferencesURL, let bytes = try? Data(contentsOf: url) { preferences = (try? JSONDecoder().decode(CloudRecoveryPreferences.self, from: bytes)) ?? .init() }
            cloudEnabled = preferences.enabled
            try await restoreProgramSelection(operation: operation)
            try await refreshRecoveryPrograms()
        }
    }
    private func restoreProgramSelection(operation: TrainingOperationGate.Lease) async throws {
        guard let repository, workout == nil, readOnlyProgram == nil else { return }
        let document = try await repository.exportBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
        let verifiedRoots = Set(proof.envelopes.values.filter { $0.parentEnvelopeHash == nil }.map(\.programID))
        let ids = document.heads.keys.filter { verifiedRoots.contains($0) }.sorted()
        let id = preferences.activeProgramID.flatMap { ids.contains($0) ? $0 : nil } ?? (ids.count == 1 ? ids.first : nil)
        if let id, let uuid = UUID(uuidString: id) {
            try await installSelectedSnapshot(try await repository.snapshot(programID: uuid), repository: repository, operation: operation)
        }
    }
    // One admission for restore, reopen, selection and incoming adoption. Valid
    // unsupported archives stay exact and never become a fixed-routine trainer.
    private func installSelectedSnapshot(_ snapshot: StoreSnapshot, repository: TrainingRepository, operation: TrainingOperationGate.Lease) async throws {
        try operations.requireOwnership(operation)
        guard AppTrainingCompatibility.supports(snapshot) else {
            workout = nil; readOnlyProgram = snapshot; showingWorkout = false; return
        }
        readOnlyProgram = nil
        if let model = workout, model.snapshot.state.config.programID == snapshot.state.config.programID {
            try model.adoptRecoverySnapshot(snapshot, operation: operation)
        } else {
            workout = WorkoutViewModel(repository: repository, snapshot: snapshot, timeZoneID: timeZoneID, now: now, operations: operations, activatesExactPolicy: true)
            showingWorkout = false
        }
        try await workout?.refreshWorkingAdmission(operation: operation)
    }
    private func savePreferences() throws {
        preferences.enabled = cloudEnabled
        if let preferencesURL { try JSONEncoder().encode(preferences).write(to: preferencesURL, options: .atomic) }
    }
    private func installRecoveryServices() async throws {
        guard let repository else { return }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if uiTesting, let index = args.firstIndex(of: "-fixture"), args.indices.contains(index + 1), args[index + 1].hasPrefix("cloud-") {
            let fixture = args[index + 1]
            let scope = CloudScope(containerIdentifier: "synthetic-ui", environment: .development, accountIdentifier: "synthetic-A")
            let provider = SyntheticRecoveryAccount(fixture == "cloud-no-account" ? nil : scope)
            let transport = SyntheticRecoveryTransport(repository: repository, reason: fixture == "cloud-quota" ? "iCloud storage is full. Local history and pending recovery records are retained." : "Waiting for a network connection. Local training remains available.")
            cloudCoordinator = CloudSyncCoordinator(repository: repository, accountProvider: provider, makeTransport: { transport })
            if fixture != "cloud-no-account" { cloudEnabled = true; try savePreferences() }
        }
        #endif
        // Construction itself is gated, before any CKContainer/account access.
        if cloudCoordinator == nil, CloudRuntimeConfiguration.isProvisioned {
            let container = CKContainer(identifier: CloudRuntimeConfiguration.containerIdentifier)
            guard let environment = CloudRuntimeConfiguration.environment else { return }
            let provider = CloudKitAccountProvider(container: container, environment: environment)
            cloudCoordinator = CloudSyncCoordinator(repository: repository, accountProvider: provider, makeTransport: {
                CloudKitTransport(container: container, accountProvider: provider, repository: repository)
            })
        }
        await cloudCoordinator?.setUpdateHandler { [weak self] scope in
            await self?.cloudRecordsChanged(scope)
        }
    }
    func refreshRecoveryPrograms() async throws {
        guard let repository else { return }
        recoveryPrograms = try await repository.recoveryPrograms()
    }
    func setCloudRecoveryEnabled(_ enabled: Bool) async {
        cloudGeneration += 1; cloudEnabled = enabled; verifiedCloudScope = nil
        let ticket = cloudGeneration
        do { try savePreferences() } catch { recoveryMessage = "The recovery preference could not be saved. Local history is retained." }
        if enabled {
            await cloudCoordinator?.setUpdateHandler { [weak self] scope in await self?.cloudRecordsChanged(scope) }
            await resumeRecovery(allowAssociation: true)
        }
        else {
            await cloudCoordinator?.disable()
            guard ticket == cloudGeneration, !cloudEnabled else { return }
            cloudStatus = .init(); recoveryMessage = "Recovery is off. Local history and pending records are retained."
        }
    }
    private struct RecoveryRootChoice: Equatable, Sendable {
        let programID: String
        let datasetID: UUID
        let rootHash: String
    }
    private func recoveryRootChoice(for model: WorkoutViewModel) async throws -> RecoveryRootChoice {
        let document = try await model.repository.exportBackup()
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
        let program = model.programID.uuidString.lowercased()
        let roots = proof.envelopes.values.filter { $0.programID == program && $0.parentEnvelopeHash == nil }
        guard roots.count == 1, let root = roots.first, let dataset = UUID(uuidString: root.datasetID),
              (document.recovery?.rootDatasets[root.envelopeHash] ?? root.datasetID) == root.datasetID,
              document.heads[program] != nil else { throw BackupService.invalid("root_selection") }
        return .init(programID: program, datasetID: dataset, rootHash: root.envelopeHash)
    }
    private func associateRecoveryRoot(_ root: RecoveryRootChoice, model: WorkoutViewModel, scope: CloudScope, ticket: Int, selectionTicket: Int) async throws {
        try await operations.perform { _ in
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === model else { throw CloudFailure.accountUnavailable }
            let currentRoot = try await recoveryRootChoice(for: model)
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === model, currentRoot == root else { throw CloudFailure.accountUnavailable }
            try await model.repository.bindDataset(datasetID: root.datasetID, to: scope)
        }
    }
    private func resumeRecovery(allowAssociation: Bool = false, expectedScope: CloudScope? = nil) async {
        guard cloudEnabled else { return }
        guard let coordinator = cloudCoordinator else {
            cloudStatus = .init(phase: .accountUnavailable, retryReason: "iCloud recovery is unavailable in this unsigned or unconfigured build. Local training and JSON backups remain available.")
            return
        }
        let ticket = cloudGeneration
        let selectionTicket = selectionGeneration
        let selectedModel = workout
        do {
            // Consent targets the selection at entry, before optional service waits.
            let selectedRoot: RecoveryRootChoice?
            if let selectedModel { selectedRoot = try await recoveryRootChoice(for: selectedModel) }
            else { selectedRoot = nil }
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel else { return }
            let freshScope = try await coordinator.verifiedScope()
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel else { return }
            guard let scope = freshScope else {
                cloudStatus = .init(phase: .accountUnavailable, retryReason: "Sign in to iCloud in iOS Settings to enable recovery. There is no app login."); return
            }
            guard expectedScope == nil || expectedScope == scope else { throw CloudFailure.accountUnavailable }
            // Fresh read-only discovery must precede every explicit association.
            let candidates = try await coordinator.discoverRecoveryCandidates()
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, try await coordinator.verifiedScope() == scope else { return }
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel else { return }
            discoveryCandidates = candidates
            if let selectedModel, let selectedRoot {
                let currentRoot = try await recoveryRootChoice(for: selectedModel)
                guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel, currentRoot == selectedRoot else { return }
                let dataset = selectedRoot.datasetID
                let association = try await selectedModel.repository.datasetAssociation(dataset)
                guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel else { return }
                guard association == nil || association == scope.key else {
                    cloudStatus = .init(phase: .accountUnavailable, retryReason: "The iCloud account changed. View or export old local history, or explicitly create a separate program for this account. Old history will not be transferred."); return
                }
                if association == nil, !allowAssociation {
                    cloudStatus = .init(phase: .accountUnavailable, retryReason: "Choose Associate selected program to explicitly use the current iCloud account. Local history is retained."); return
                }
                try await coordinator.enable(datasetID: dataset, expectedScope: scope, associationAction: { scope in
                    try await self.associateRecoveryRoot(selectedRoot, model: selectedModel, scope: scope, ticket: ticket, selectionTicket: selectionTicket)
                })
                guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel else { return }
                await coordinator.requestSync()
            }
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel else { return }
            await cloudRecordsChanged(scope)
        } catch {
            guard ticket == cloudGeneration, selectionTicket == selectionGeneration, cloudEnabled, workout === selectedModel else { return }
            cloudStatus = .init(phase: .accountUnavailable, retryReason: "Recovery could not start. Local history and existing account associations are retained."); recoveryMessage = error.localizedDescription
        }
    }
    func retryCloudRecovery() async { await resumeRecovery() }
    func pauseRecoveryForBackground() async {
        cloudGeneration += 1; verifiedCloudScope = nil
        let ticket = cloudGeneration
        await cloudCoordinator?.disable()
        if ticket == cloudGeneration, cloudEnabled { cloudStatus.retryReason = "Recovery will retry when this app is active. Local training and pending records are retained." }
    }
    func cloudRecordsChanged(_ scope: CloudScope) async {
        guard cloudEnabled, let coordinator = cloudCoordinator else { return }
        let ticket = cloudGeneration
        do {
            let currentScope = try await coordinator.verifiedScope()
            guard ticket == cloudGeneration, cloudEnabled else { return }
            guard currentScope == scope else {
                cloudGeneration += 1; verifiedCloudScope = nil
                cloudStatus = .init(phase: .accountUnavailable, retryReason: "The iCloud account changed. Old local history and pending records are retained."); return
            }
            let records = try await coordinator.retainedObservations(scope: scope)
            guard ticket == cloudGeneration, cloudEnabled else { return }
            // Reserve local adoption as soon as fresh durable records arrive.
            // The deferred lease contains only local work; subsequent optional
            // status/account waits cannot let another training write overtake it.
            verifiedCloudScope = scope
            let keys = try Set(records.map { scope.key + ":" + (try BackupService.hash($0.observation)) })
            if !keys.isSubset(of: lastIngestedObservations) {
                stagedScope = scope; stagedRecords = records
                cloudStatus.phase = .incomplete
                if workout?.snapshot.draft != nil || workout?.hasAmbiguousFinish == true {
                    cloudStatus.retryReason = "Incoming recovery data is saved for review after all saved workouts are safely finished. Unfinished drafts stay on this phone."
                }
                scheduleStagedIngestion()
            }
            let transportStatus = await coordinator.syncStatus()
            guard ticket == cloudGeneration, cloudEnabled, try await coordinator.verifiedScope() == scope else { return }
            guard ticket == cloudGeneration, cloudEnabled else { return }
            let stagedReason = cloudStatus.retryReason
            cloudStatus = transportStatus
            // Local adoption may have finished during the service await; never
            // replace its authoritative health with an older transport status.
            let selectedHealth = workout?.snapshot.health
            if [.integrityConflict, .mixedPolicyConflict].contains(selectedHealth) || recoveryPrograms.contains(where: { [.integrityConflict, .mixedPolicyConflict].contains($0.health) }) { cloudStatus.phase = .conflict }
            else if stagedScope != nil || (selectedHealth != nil && selectedHealth != .ready) || recoveryPrograms.contains(where: { $0.health != .ready }) {
                cloudStatus.phase = .incomplete
                if stagedScope != nil { cloudStatus.retryReason = stagedReason }
            }
        } catch {
            guard ticket == cloudGeneration, cloudEnabled else { return }
            verifiedCloudScope = nil; cloudStatus = .init(phase: .accountUnavailable, retryReason: "Recovery is waiting for the original iCloud account. Local data is retained.")
        }
    }
    private func scheduleStagedIngestion() {
        guard !adoptingCloud, cloudEnabled, let scope = stagedScope, verifiedCloudScope == scope, let repository else { return }
        adoptingCloud = true
        let ticket = cloudGeneration
        operations.whenIdle { [weak self] operation in
            guard let self else { return }
            var ingested = false
            defer {
                self.adoptingCloud = false
                // An expired reservation must hand off a freshly verified
                // replacement generation before the gate can admit a writer.
                // Same-generation protected drafts deliberately wait for release.
                if ingested || ticket != self.cloudGeneration { self.scheduleStagedIngestion() }
            }
            do {
                guard self.cloudEnabled, ticket == self.cloudGeneration, self.verifiedCloudScope == scope else { return }
                let document = try await repository.exportBackup()
                guard document.drafts.isEmpty, self.workout?.hasAmbiguousFinish != true else {
                    self.cloudStatus.phase = .incomplete
                    self.cloudStatus.retryReason = "Incoming recovery data is saved for review after all saved workouts are safely finished. Unfinished drafts stay on this phone."
                    return
                }
                let records = self.stagedRecords
                guard ticket == self.cloudGeneration, self.cloudEnabled else { return }
                _ = try await CloudIngestor(repository: repository).ingest(records, scope: scope)
                if let model = self.workout {
                    let current = try await repository.snapshot(programID: model.programID)
                    try await self.installSelectedSnapshot(current, repository: repository, operation: operation)
                } else if let current = self.readOnlyProgram, let id = UUID(uuidString: current.state.config.programID) {
                    try await self.installSelectedSnapshot(try await repository.snapshot(programID: id), repository: repository, operation: operation)
                }
                self.lastIngestedObservations.formUnion(try records.map { scope.key + ":" + (try BackupService.hash($0.observation)) })
                ingested = true
                let currentKeys = try Set(self.stagedRecords.map { scope.key + ":" + (try BackupService.hash($0.observation)) })
                if currentKeys.isSubset(of: self.lastIngestedObservations) { self.stagedScope = nil; self.stagedRecords = [] }
                try await self.refreshRecoveryPrograms()
                let retryReason = self.cloudStatus.retryReason
                guard ticket == self.cloudGeneration, self.cloudEnabled, self.verifiedCloudScope == scope else { return }
                let status = try await repository.cloudStatus(scope: scope)
                guard ticket == self.cloudGeneration, self.cloudEnabled, self.verifiedCloudScope == scope else { return }
                self.cloudStatus = status
                self.cloudStatus.retryReason = retryReason
                if self.recoveryPrograms.contains(where: { [.integrityConflict, .mixedPolicyConflict].contains($0.health) }) { self.cloudStatus.phase = .conflict }
                else if self.recoveryPrograms.contains(where: { $0.health != .ready }) { self.cloudStatus.phase = .incomplete }
            } catch {
                guard ticket == self.cloudGeneration, self.cloudEnabled else { return }
                self.cloudStatus.phase = .incomplete; self.cloudStatus.retryReason = "Recovery needs review. All local and incoming observations are retained."
            }
        }
    }
    func selectRecoveryProgram(_ id: String) async throws {
        guard let repository, let uuid = UUID(uuidString: id) else { throw BackupService.invalid("program_selection") }
        guard workout?.snapshot.draft == nil || workout?.snapshot.state.config.programID == id,
              workout?.hasAmbiguousFinish != true else { throw BackupUIError.protectedWorkout }
        try await operations.perform { operation in
            let document = try await repository.exportBackup()
            let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
            let roots = proof.envelopes.values.filter { $0.programID == id && $0.parentEnvelopeHash == nil }
            guard roots.count == 1, let root = roots.first,
                  (document.recovery?.rootDatasets[root.envelopeHash] ?? root.datasetID) == root.datasetID,
                  document.heads[id] != nil else { throw BackupService.invalid("unverified_root") }
            let snapshot = try await repository.snapshot(programID: uuid)
            #if DEBUG
            try await selectionBeforeAdoptionForTesting?()
            #endif
            if workout?.programID != uuid && readOnlyProgram?.state.config.programID != id { selectionGeneration += 1 }
            try await installSelectedSnapshot(snapshot, repository: repository, operation: operation)
            preferences.activeProgramID = id; try savePreferences()
        }
    }
    // Called inside the shared training gate and reads current authoritative heads.
    // Historical restrictions that were actually cleared do not block creation.
    func requireSafeNewProgram(_ config: ProgramConfig, repository: TrainingRepository) async throws {
        guard workout?.hasAmbiguousFinish != true else { throw BackupUIError.retainedRestrictions }
        let document = try await repository.exportBackup()
        guard document.drafts.isEmpty else { throw BackupUIError.retainedRestrictions }
        let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
        let programs = Set(document.heads.keys).union(proof.envelopes.values.filter { $0.parentEnvelopeHash == nil }.map(\.programID))
        if config.profileID == "starter-upper-v1" || config.profileID == "starter-glute-v1" {
            let choice = try StarterProgramCatalog.choice(for: config)
            try validate(config: config, rules: RulesetCatalog.starter(choice))
            guard proof.waiting.isEmpty, proof.quarantined.isEmpty else { throw BackupUIError.retainedRestrictions }
            var defaults: [String: Int] = [:]
            for emphasis in StarterProgramChoice.allCases {
                let definition = try StarterProgramCatalog.definition(emphasis)
                for movement in definition.movements {
                    let family = starterSafetyFamily(for: movement.id)
                    defaults[family] = max(defaults[family] ?? 0, movement.minimumRir)
                }
            }
            for program in programs {
                guard let uuid = UUID(uuidString: program), document.heads[program] != nil else { throw BackupUIError.retainedRestrictions }
                let current = try await repository.snapshot(programID: uuid)
                guard current.health == .ready, current.draft == nil, AppTrainingCompatibility.supports(current),
                      !current.state.exercises.values.contains(where: { $0.mode == .paused }) else { throw BackupUIError.retainedRestrictions }
                var retained = current.state.retainedSafety ?? [:]
                for movement in current.state.config.movements {
                    let family = starterSafetyFamily(for: movement.id)
                    let restriction = current.state.baseSafety?[movement.id] ?? MovementSafetyState(paused: false,
                        minimumRir: movement.minimumRir, sourceEventIDs: [])
                    if let previous = retained[family] {
                        retained[family] = MovementSafetyState(paused: previous.paused || restriction.paused,
                            minimumRir: max(previous.minimumRir, restriction.minimumRir), sourceEventIDs: [])
                    } else { retained[family] = restriction }
                }
                guard retained.allSatisfy({ family, restriction in
                    defaults[family] != nil && !restriction.paused && restriction.minimumRir <= defaults[family]!
                }) else { throw BackupUIError.retainedRestrictions }
            }
            return
        }
        let defaults = Dictionary(uniqueKeysWithValues: config.movements.map { ($0.id, $0.minimumRir) })
        for program in programs {
            guard let uuid = UUID(uuidString: program), document.heads[program] != nil else { throw BackupUIError.retainedRestrictions }
            let current = try await repository.snapshot(programID: uuid)
            guard current.health == .ready, current.draft == nil,
                  !current.state.exercises.values.contains(where: { $0.mode == .paused }),
                  !(current.state.baseSafety ?? [:]).values.contains(where: { $0.paused }),
                  current.state.config.movements.allSatisfy({ $0.minimumRir <= (defaults[$0.id] ?? 0) }),
                  (current.state.baseSafety ?? [:]).allSatisfy({ $0.value.minimumRir <= (defaults[$0.key] ?? 0) }) else {
                throw BackupUIError.retainedRestrictions
            }
        }
    }
    func createSeparateCloudProgram(choice: StarterProgramChoice, goal: Goal) async throws {
        guard let repository, cloudEnabled, let coordinator = cloudCoordinator,
              workout?.snapshot.draft == nil, workout?.hasAmbiguousFinish != true else { throw BackupUIError.protectedWorkout }
        let ticket = cloudGeneration
        guard let scope = try await coordinator.verifiedScope() else { throw CloudFailure.accountUnavailable }
        _ = try await coordinator.discoverRecoveryCandidates()
        guard ticket == cloudGeneration, cloudEnabled, try await coordinator.verifiedScope() == scope else { throw CloudFailure.accountUnavailable }
        try await operations.perform { operation in
            guard ticket == cloudGeneration, cloudEnabled else { throw CloudFailure.accountUnavailable }
            let config = try selectStarterProgram(choice: choice, goal: goal, programID: UUID())
            try await requireSafeNewProgram(config, repository: repository)
            let date = try CalendarContext(timeZoneID: timeZoneID).localDate(at: now())
            let snapshot = try await repository.initialize(config: config, rules: RulesetCatalog.starter(choice), firstWorkout: WorkoutScheduler.nextSlot(onOrAfter: date, config: config), datasetID: UUID())
            try await installSelectedSnapshot(snapshot, repository: repository, operation: operation)
            preferences.activeProgramID = config.programID; try savePreferences()
            try await refreshRecoveryPrograms()
        }
        await resumeRecovery(allowAssociation: true, expectedScope: scope)
    }
    func associateSelectedProgram() async { await resumeRecovery(allowAssociation: true) }
    func recoveryProof() async throws -> VerifiedCloudBatch {
        guard let repository else { throw BackupService.invalid("repository") }
        return try RecoveryVerifier().verify(BackupService.recoveryRecords(await repository.exportBackup()))
    }
    func resolveRecoveryConflict(programID: String, heads: [String], selection: BranchSelection) async throws {
        guard let repository, let uuid = UUID(uuidString: programID) else { throw BackupService.invalid("program") }
        try await operations.perform { operation in
            guard try await repository.exportBackup().drafts.isEmpty, workout?.hasAmbiguousFinish != true else { throw BackupUIError.protectedWorkout }
            let proof = try await recoveryProof()
            guard let selected = proof.envelopes[selection.selectedHeadHash] else { throw BackupService.invalid("selection") }
            let date = try CalendarContext(timeZoneID: timeZoneID).localDate(at: now())
            let next: WorkoutSlot
            if selected.returnedState.schedulingPolicy == .flexibleV1 {
                let latest = heads.compactMap { proof.envelopes[$0]?.returnedState.lastSessionDate }.max()
                next = try WorkoutScheduler.pendingAfterRecovery(state: selected.returnedState, latestSessionDate: latest)
            } else {
                next = try WorkoutScheduler.nextSlot(onOrAfter: date, config: selected.returnedState.config)
            }
            let snapshot = try await repository.resolveConflict(programID: uuid, expectedHeadHashes: heads, selection: selection, next: next)
            if workout?.programID == uuid || readOnlyProgram?.state.config.programID == programID {
                try await installSelectedSnapshot(snapshot, repository: repository, operation: operation)
            }
            try await refreshRecoveryPrograms()
        }
    }
}

extension AppComposition {
    func exportStagedOriginalsFile() async throws -> URL {
        guard let repository else { throw BackupService.invalid("repository") }
        let bytes = try BackupService.bytes(await repository.stagedRecoveryOriginals())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlentyStrong-Staged-Originals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("PlentyStrong-staged-originals-evidence.json")
        try bytes.write(to: url, options: .atomic); return url
    }
}


/// App support is narrower than archive verification. No archived data is
/// changed, migrated, or assigned invented profile/variant identifiers here.
enum AppTrainingCompatibility {
    static func supports(_ snapshot: StoreSnapshot) -> Bool {
        guard [2,3,4].contains(snapshot.state.schemaVersion), let rules = try? RulesetCatalog.resolve(version: snapshot.state.rulesetVersion, hash: snapshot.state.rulesetHash),
              (try? ProgramPolicy.resolve(schemaVersion: snapshot.state.schemaVersion, rules: rules)) != nil,
              snapshot.state.rulesetHash == rules.hash,
              (try? validate(config: snapshot.state.config, rules: rules)) != nil else { return false }
        let bases = Set(snapshot.state.config.movements.map(\.id))
        let prescriptions = [snapshot.state.activePrescription] + (snapshot.draft.map { [$0.planned, $0.displayed] } ?? [])
        return prescriptions.allSatisfy { prescription in
            prescription.exercises.allSatisfy { row in
                guard let base = row.baseMovementID else { return false }
                return bases.contains(base) && snapshot.state.config.variants?[row.movementID]?.baseMovementID == base
            }
        }
    }
}

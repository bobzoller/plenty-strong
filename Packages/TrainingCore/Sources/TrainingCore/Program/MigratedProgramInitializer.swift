import Foundation

private func migrationInvalid(_ field: String) -> EngineError { EngineError(code: "invalid_migration", field: field) }

public func validateExternalSourceArchive(_ archive: ExternalSourceArchive) throws {
    guard archive.archiveKind == "external-program-source-v1", archive.schemaVersion == 1,
          !archive.files.isEmpty, archive.files.count <= 16, archive.files.allSatisfy({ $0.bytes.count <= 50_000_000 }), archive.files.reduce(0, { $0 + $1.bytes.count }) <= 50_000_000,
          archive.sourceBindings.count <= 300_000,
          archive.workouts.count <= 30_000, archive.workouts.flatMap(\.rows).count <= 100_000,
          Set(archive.files.map(\.name)).count == archive.files.count,
          archive.files.allSatisfy({ !$0.name.isEmpty && !$0.mediaType.isEmpty && $0.sha256 == migrationDataHash($0.bytes) }),
          Set(archive.workouts.map(\.sourceKey)).count == archive.workouts.count,
          archive.workouts.allSatisfy({ !$0.sourceKey.isEmpty }),
          Set(archive.workouts.flatMap(\.rows).map(\.sourceKey)).count == archive.workouts.flatMap(\.rows).count,
          archive.workouts.flatMap(\.rows).allSatisfy({ !$0.sourceKey.isEmpty && !$0.movementLabel.isEmpty }) else {
        throw migrationInvalid("source_archive")
    }
    guard archive.contentHash == (try migrationHash(archive, excluding: "contentHash")) else { throw migrationInvalid("source_hash") }
    try validateMigrationSourceBindings(archive)
}

public func validateMigrationDocument(_ document: ProgramMigrationDocument) throws {
    guard document.format == "plenty-strong-program-migration", document.schemaVersion == 1,
          document.continuationPolicy == "native_exact_v1", document.checkpoint.version == 1 else { throw migrationInvalid("version") }
    try validateExternalSourceArchive(document.source)
    guard document.checkpoint.externalArchiveHash == document.source.contentHash,
          document.checkpoint.baselines == document.source.baselines,
          document.checkpoint.externalLastSessionDate == document.source.workouts.map(\.date).max() else { throw migrationInvalid("source_checkpoint") }
}

public func previewProgramMigration(document: ProgramMigrationDocument, selection: MigrationSelection,
                                    acceptance: MigrationAcceptance, programID: UUID) throws -> ProgramMigrationPreview {
    try validateMigrationDocument(document)
    let initialized = try migrateProgram(checkpoint: document.checkpoint, selection: selection, acceptance: acceptance,
        source: document.source, programID: programID, rules: RulesetCatalog.migratedExactV1())
    var differences = ["Source calibration/qualifying counters are archived; native comparison counters begin empty.",
        "Source calendar phases are archived; native effort reserve, goal rest and exact progression govern future sessions."]
    for row in document.checkpoint.baselines {
        let dose = initialized.state.migration!.doses[row.variantID]!
        if dose.repFloor != row.sourceRepFloor || dose.initialRepCeiling != row.sourceRepCeiling {
            differences.append("\(row.baseMovementID): source range \(row.sourceRepFloor)–\(row.sourceRepCeiling); admitted native range \(dose.repFloor)–\(dose.initialRepCeiling). Current targets retained.")
        }
    }
    return ProgramMigrationPreview(initialized: initialized, importIdentity: try migrationImportIdentity(document: document, selection: selection),
        differences: differences, externalWorkoutCount: document.source.workouts.count,
        externalExerciseCount: document.source.workouts.reduce(0) { $0 + $1.rows.count }, documentHash: try migrationHash(document),
        checkpointHash: try migrationHash(document.checkpoint), selectionHash: try migrationHash(selection))
}

public func migrateProgram(checkpoint: ProgramMigrationCheckpoint, selection: MigrationSelection,
                           acceptance: MigrationAcceptance, source: ExternalSourceArchive,
                           programID: UUID, rules: Ruleset) throws -> InitializedProgram {
    let document = ProgramMigrationDocument(source: source, checkpoint: checkpoint)
    try validateMigrationDocument(document)
    guard selection.acceptedNativePolicy, try ProgramPolicy.resolve(schemaVersion: 5, rules: rules) == .migratedExactV1 else { throw migrationInvalid("policy_acceptance") }
    let date = try SessionTiming.localDate(milliseconds: acceptance.acceptedAtMilliseconds, timeZoneID: acceptance.timeZoneID)
    guard checkpoint.externalLastSessionDate.map({ $0 <= date && checkpoint.nextWorkout.date > $0 }) ?? true else { throw migrationInvalid("dates") }
    var config = try selectFixedProgram(goal: selection.goal, programID: programID)
    let rows = checkpoint.baselines
    guard Set(rows.map(\.baseMovementID)) == Set(config.movements.map(\.id)), rows.count == config.movements.count,
          Set(rows.map(\.variantID)).count == rows.count,
          Set(selection.confirmedLoads.keys).isSubset(of: Set(rows.filter { $0.unresolvedLoadAmount != nil }.map(\.baseMovementID))) else { throw migrationInvalid("baselines") }
    let parameters = try rules.resolvedParameters
    var exercises: [String: ExerciseState] = [:], safety: [String: MovementSafetyState] = [:]
    var doses: [String: MigratedDose] = [:], anchors: [String: LocalDate] = [:]
    for row in rows {
        let movement = config.movements.first { $0.id == row.baseMovementID }!
        let minimumFloor = movement.loadingMode == .externalLoad ? (movement.lowRepLoadingAllowed ? 4 : 8) : 1
        let maximum = parameters.maximumRepCeiling
        guard !row.variantID.isEmpty, row.modifications == row.modifications.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...3).contains(row.targets.count), row.targets.allSatisfy({ $0 > 0 && $0 <= maximum }),
              row.sourceRepFloor > 0, row.sourceRepCeiling >= row.sourceRepFloor, row.sourceRepCeiling <= maximum,
              row.minimumRir >= 2, !row.sourceKeys.isEmpty, row.sourceKeys.allSatisfy({ !$0.isEmpty }),
              Set(row.sourceKeys).count == row.sourceKeys.count, !row.recoveryStatus.isEmpty else { throw migrationInvalid("baseline_shape") }
        let floor = min(row.sourceRepFloor, row.targets.min()!)
        guard floor >= minimumFloor else { throw migrationInvalid("unsafe_floor") }
        let ceiling = max(row.sourceRepCeiling, row.targets.max()!)
        let dose = MigratedDose(normalSets: row.targets.count, repFloor: floor, initialRepCeiling: ceiling)
        var load = row.load
        if let amount = row.unresolvedLoadAmount {
            guard row.load == nil, let confirmed = selection.confirmedLoads[row.baseMovementID], confirmed.amount == amount else { throw migrationInvalid("load_confirmation") }
            load = confirmed
        }
        if movement.loadingMode == .externalLoad {
            guard load.map({ movement.availableLoads.contains($0) }) ?? true else { throw migrationInvalid("load") }
        } else { guard load == nil, row.unresolvedLoadAmount == nil else { throw migrationInvalid("manual_load") } }
        let defaultID = try defaultVariantID(programID: config.programID, baseMovementID: row.baseMovementID)
        guard config.variants?[row.variantID] == nil || row.variantID == defaultID else { throw migrationInvalid("variant_identity") }
        config.variants![row.variantID] = MovementVariant(id: row.variantID, baseMovementID: row.baseMovementID, modifications: row.modifications)
        config.activeVariantIDs![row.baseMovementID] = row.variantID
        let restriction = MovementSafetyState(paused: row.paused, minimumRir: max(row.minimumRir, movement.minimumRir), sourceEventIDs: [])
        safety[row.baseMovementID] = restriction
        for id in Set([defaultID, row.variantID]) {
            let imported = id == row.variantID
            doses[id] = dose
            exercises[id] = ExerciseState(load: imported ? load : nil, mode: row.paused ? .paused : imported ? .normal : .baseline,
                normalSets: dose.normalSets, repFloor: dose.repFloor, repCeiling: dose.initialRepCeiling,
                ceilingStreak: 0, strainStreak: 0, lastCompletedDate: nil, nextSetOverride: nil, interruptedReturn: false,
                recentComparable: [], setupRevision: 1, exactRepState: ExactRepState(normalTargets: imported ? row.targets : Array(repeating: floor, count: dose.normalSets),
                    shortfallStreak: 0, lastSuitableNormalDate: nil, setupReviewRequired: row.reviewRequired))
            if imported && !row.paused && !row.reviewRequired { anchors[id] = date }
        }
    }
    try validate(config: config, rules: rules)
    var state = ProgramState(schemaVersion: 5, rulesetVersion: rules.version, rulesetHash: rules.hash, config: config, revision: 0,
        exercises: exercises, lastSessionDate: nil, activePrescription: WorkoutPrescription(id: "", date: checkpoint.nextWorkout.date, slotID: checkpoint.nextWorkout.slotID, exercises: []),
        processedEvents: [:], baseSafety: safety)
    state.schedulingPolicy = .flexibleV1
    state.migration = ProgramMigrationOrigin(externalArchiveHash: source.contentHash, checkpointHash: try migrationHash(checkpoint),
        importIdentity: try migrationImportIdentity(document: document, selection: selection), acceptance: acceptance,
        externalLastSessionDate: checkpoint.externalLastSessionDate, doses: doses, baselines: rows, clockAnchors: anchors)
    state.activePrescription = try plannedExactWorkout(state: state, rules: rules, slot: checkpoint.nextWorkout)
    _ = try prepareWorkout(state: state, rules: rules)
    return InitializedProgram(state: state, workout: state.activePrescription)
}

/// Registered schema-5 state constraints; legacy policy branches never consult it.
func validateMigratedState(_ state: ProgramState, rules: Ruleset) throws {
    guard state.schemaVersion == 5, let origin = state.migration,
          !origin.externalArchiveHash.isEmpty, !origin.checkpointHash.isEmpty, !origin.importIdentity.isEmpty,
          Set(origin.doses.keys) == Set(state.exercises.keys),
          Set(origin.clockAnchors.keys).isSubset(of: Set(state.exercises.keys)), state.retainedSafety == nil,
          state.exercises.values.allSatisfy({ $0.starterState == nil }),
          Set(origin.baselines.map(\.baseMovementID)) == Set(state.config.movements.map(\.id)),
          origin.baselines.count == state.config.movements.count,
          Set(origin.clearedSafetyBaseIDs).count == origin.clearedSafetyBaseIDs.count,
          Set(origin.clearedSafetyBaseIDs).isSubset(of: Set(state.config.movements.map(\.id))) else { throw migrationInvalid("origin") }
    let parameters = try rules.resolvedParameters
    for (id, dose) in origin.doses {
        guard let variant = state.config.variants?[id], let movement = state.config.movements.first(where: { $0.id == variant.baseMovementID }),
              let exercise = state.exercises[id], (1...3).contains(dose.normalSets), dose.repFloor >= 1,
              dose.initialRepCeiling >= dose.repFloor, dose.initialRepCeiling <= parameters.maximumRepCeiling,
              dose.repFloor >= (movement.loadingMode == .externalLoad ? (movement.lowRepLoadingAllowed ? 4 : 8) : 1),
              exercise.normalSets == dose.normalSets, exercise.repFloor == dose.repFloor, exercise.repCeiling >= dose.initialRepCeiling else { throw migrationInvalid("dose") }
        if let original = origin.baselines.first(where: { $0.baseMovementID == movement.id }) {
            guard (state.baseSafety?[movement.id]?.minimumRir ?? 0) >= original.minimumRir else { throw migrationInvalid("safety") }
            if !origin.clearedSafetyBaseIDs.contains(movement.id) {
                guard !original.paused || state.baseSafety?[movement.id]?.paused == true,
                      !original.reviewRequired || exercise.exactRepState?.setupReviewRequired == true else { throw migrationInvalid("uncleared_safety") }
            }
        }
    }
}

func migratedClockDate(state: ProgramState, id: String) -> LocalDate? {
    state.exercises[id]?.exactRepState?.lastSuitableNormalDate ?? (state.schemaVersion == 5 ? state.migration?.clockAnchors[id] : nil)
}

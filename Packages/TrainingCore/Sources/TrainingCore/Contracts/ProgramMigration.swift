import CryptoKit
import Foundation

public struct ExternalSourceFile: Codable, Equatable, Sendable {
    public var name: String
    public var mediaType: String
    public var bytes: Data
    public var sha256: String
    public init(name: String, mediaType: String, bytes: Data) throws {
        self.name = name; self.mediaType = mediaType; self.bytes = bytes
        sha256 = migrationDataHash(bytes)
    }
}

public struct ExternalExerciseObservation: Codable, Equatable, Sendable {
    public var sourceKey: String
    public var movementLabel: String
    public var raw: [String: CanonicalValue]
    public init(sourceKey: String, movementLabel: String, raw: [String: CanonicalValue]) {
        self.sourceKey = sourceKey; self.movementLabel = movementLabel; self.raw = raw
    }
}
public struct ExternalWorkoutObservation: Codable, Equatable, Sendable {
    public var date: LocalDate
    public var sourceKey: String
    public var rows: [ExternalExerciseObservation]
    public init(date: LocalDate, sourceKey: String, rows: [ExternalExerciseObservation]) {
        self.date = date; self.sourceKey = sourceKey; self.rows = rows
    }
}

/// Typed source projection. Raw original files and safety descriptions remain
/// authoritative provenance; no member certifies a native historical exposure.
public struct MigrationBaseline: Codable, Equatable, Sendable {
    public var baseMovementID: String
    public var variantID: String
    public var modifications: String
    public var load: Load?
    public var targets: [Int]
    public var sourceRepFloor: Int
    public var sourceRepCeiling: Int
    public var minimumRir: Int
    public var paused: Bool
    public var reviewRequired: Bool
    public var recoveryStatus: String
    public var safetyText: String
    public var sourceKeys: [String]
    public var unresolvedLoadAmount: String?
    public var recoveryRequired: Bool = false
    public init(baseMovementID: String, variantID: String, modifications: String, load: Load?, targets: [Int], sourceRepFloor: Int, sourceRepCeiling: Int, minimumRir: Int, paused: Bool, reviewRequired: Bool, recoveryStatus: String, safetyText: String, sourceKeys: [String], unresolvedLoadAmount: String? = nil, recoveryRequired: Bool = false) {
        self.baseMovementID = baseMovementID; self.variantID = variantID; self.modifications = modifications; self.load = load; self.targets = targets
        self.sourceRepFloor = sourceRepFloor; self.sourceRepCeiling = sourceRepCeiling; self.minimumRir = minimumRir; self.paused = paused
        self.reviewRequired = reviewRequired; self.recoveryStatus = recoveryStatus; self.safetyText = safetyText; self.sourceKeys = sourceKeys; self.unresolvedLoadAmount = unresolvedLoadAmount; self.recoveryRequired = recoveryRequired
    }
}

public struct MigrationRecoveryAttestation: Codable, Equatable, Sendable {
    public var movementID: String
    public var checkedAtMilliseconds: Int64
    public var externalArchiveHash: String
    public init(movementID: String, checkedAtMilliseconds: Int64, externalArchiveHash: String) {
        self.movementID = movementID; self.checkedAtMilliseconds = checkedAtMilliseconds; self.externalArchiveHash = externalArchiveHash
    }
}

public struct ExternalSourceArchive: Codable, Equatable, Sendable {
    public var archiveKind = "external-program-source-v1"
    public var schemaVersion = 1
    public var contentHash: String
    public var files: [ExternalSourceFile]
    public var baselines: [MigrationBaseline]
    public var workouts: [ExternalWorkoutObservation]
    public var sourceState: [String: CanonicalValue]
    public var sourceBindings: [MigrationSourceBinding]
    public init(files: [ExternalSourceFile], baselines: [MigrationBaseline], workouts: [ExternalWorkoutObservation], sourceState: [String: CanonicalValue], sourceBindings: [MigrationSourceBinding] = []) throws {
        contentHash = ""; self.files = files; self.baselines = baselines; self.workouts = workouts; self.sourceState = sourceState
        self.sourceBindings = sourceBindings
        contentHash = try migrationHash(self, excluding: "contentHash")
    }
}

public struct MigrationSourceBinding: Codable, Equatable, Sendable {
    public var targetPointer: String
    public var fileName: String
    public var sourcePointer: String
    public var conversion: String
    public init(targetPointer: String, fileName: String, sourcePointer: String, conversion: String = "exact") {
        self.targetPointer = targetPointer; self.fileName = fileName; self.sourcePointer = sourcePointer; self.conversion = conversion
    }
}

public struct ProgramMigrationCheckpoint: Codable, Equatable, Sendable {
    public var version = 1
    public var externalArchiveHash: String
    public var baselines: [MigrationBaseline]
    public var externalLastSessionDate: LocalDate?
    public var nextWorkout: WorkoutSlot
    public init(externalArchiveHash: String, baselines: [MigrationBaseline], externalLastSessionDate: LocalDate?, nextWorkout: WorkoutSlot) {
        self.externalArchiveHash = externalArchiveHash; self.baselines = baselines
        self.externalLastSessionDate = externalLastSessionDate; self.nextWorkout = nextWorkout
    }
}
public struct ProgramMigrationDocument: Codable, Equatable, Sendable {
    public var format = "plenty-strong-program-migration"
    public var schemaVersion = 1
    public var continuationPolicy = "native_exact_v1"
    public var source: ExternalSourceArchive
    public var checkpoint: ProgramMigrationCheckpoint
    public init(source: ExternalSourceArchive, checkpoint: ProgramMigrationCheckpoint) { self.source = source; self.checkpoint = checkpoint }
}
public struct MigrationSelection: Codable, Equatable, Sendable {
    public var goal: Goal
    public var acceptedNativePolicy: Bool
    /// Explicit future load confirmation only; original source stays unchanged.
    public var confirmedLoads: [String: Load]
    public init(goal: Goal, acceptedNativePolicy: Bool, confirmedLoads: [String: Load] = [:]) {
        self.goal = goal; self.acceptedNativePolicy = acceptedNativePolicy; self.confirmedLoads = confirmedLoads
    }
}
public struct MigrationAcceptance: Codable, Equatable, Sendable {
    public var acceptedAtMilliseconds: Int64
    public var timeZoneID: String
    public init(acceptedAtMilliseconds: Int64, timeZoneID: String) { self.acceptedAtMilliseconds = acceptedAtMilliseconds; self.timeZoneID = timeZoneID }
}
public struct MigratedDose: Codable, Equatable, Sendable {
    public var normalSets: Int
    public var repFloor: Int
    public var initialRepCeiling: Int
    public init(normalSets: Int, repFloor: Int, initialRepCeiling: Int) { self.normalSets = normalSets; self.repFloor = repFloor; self.initialRepCeiling = initialRepCeiling }
}
public struct ProgramMigrationOrigin: Codable, Equatable, Sendable {
    public var externalArchiveHash: String
    public var checkpointHash: String
    public var importIdentity: String
    public var acceptance: MigrationAcceptance
    public var externalLastSessionDate: LocalDate?
    public var doses: [String: MigratedDose]
    public var baselines: [MigrationBaseline]
    /// Current-checkpoint continuity only; never a suitable historical workout.
    public var clockAnchors: [String: LocalDate]
    public var clearedSafetyBaseIDs: [String] = []
}
public struct ProgramMigrationPreview: Equatable, Sendable {
    public var initialized: InitializedProgram
    public var importIdentity: String
    public var differences: [String]
    public var externalWorkoutCount: Int
    public var externalExerciseCount: Int
    public var documentHash: String
    public var checkpointHash: String
    public var selectionHash: String
}

public func migrationDataHash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
public func migrationHash(_ value: some Encodable, excluding key: String? = nil) throws -> String {
    var canonical = try JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value))
    if let key, case .object(var fields) = canonical { fields.removeValue(forKey: key); canonical = .object(fields) }
    return try CanonicalJSON.sha256(canonical)
}
public func migrationImportIdentity(document: ProgramMigrationDocument, selection: MigrationSelection) throws -> String {
    try CanonicalJSON.sha256(.array([.string("program-migration-v1"), .string(try migrationHash(document)), .string(try migrationHash(selection))]))
}

import Foundation
import TrainingCore

struct ArchivedObject: Codable, Equatable, Sendable {
    var id: String
    var bytes: Data
    var checksum: String
}
struct BackupDocument: Codable, Equatable, Sendable {
    var formatVersion = 1
    var datasetID: String
    var heads: [String: String]
    var journal: [ArchivedObject]
    var rules: [ArchivedObject]
    var profiles: [ArchivedObject]
    var drafts: [ArchivedObject]
    var recovery: RecoveryGraph? = nil
}
struct ImportReceipt: Equatable, Sendable {
    var accepted: Int
    var identical: Int
    var conflicted: Int
}
enum StoreHealth: String, Codable, Sendable {
    case ready, integrityConflict, unsupportedVersion, incompleteRecovery
    case mixedPolicyConflict = "mixed_policy_conflict"
}
struct StoreSnapshot: Equatable, Sendable {
    var state: ProgramState
    var draft: WorkoutDraft?
    var history: [JournalEnvelope]
    var decisions: [Decision]
    var health: StoreHealth
}
struct FinalizationReceipt: Sendable { var result: AdvanceResult; var snapshot: StoreSnapshot }
struct WorkoutDraft: Codable, Equatable, Sendable {
    var id: UUID
    var programID: String
    var expectedRevision: Int
    var planned: WorkoutPrescription
    var displayed: WorkoutPrescription
    var date: LocalDate
    var timeZoneID: String
    var sessionMode: SessionMode
    var logs: [ExerciseLog]
    var workingSetsStarted: Bool
    // UI-only metadata. Nil preserves old draft encoding and compatibility.
    var acknowledgedMovementIDs: [String]? = nil
    var restDeadline: Date? = nil
    // Nil retains pre-flexible drafts byte-for-byte and their original date policy.
    var startedAtMilliseconds: Int64? = nil
    // Persisted UI deadlines use whole reference seconds; recording rounds up by <1s.
    // Supported bounds are Foundation's distantPast...distantFuture dates, inclusive.
    static var supportedRestDeadlineRange: ClosedRange<Date> { .distantPast ... .distantFuture }
    var hasObservations: Bool { workingSetsStarted || logs.contains { !$0.actualSets.isEmpty || $0.problem != .none || !($0.skippedSetIndices ?? []).isEmpty || $0.mixedLoads == true } }
}

/// Format 2 explicitly describes a causal graph. Legacy datasetID is descriptive
/// only; every root retains its own dataset. Transport metadata never enters it.
struct RecoveryGraph: Codable, Equatable, Sendable {
    var version = 1
    var originals: [ArchivedRecord] = []
    var heads: [String: [String]] = [:]
    var rootDatasets: [String: String] = [:]
    var quarantines: [PortableQuarantine] = []
    var resolvedQuarantineKeys: [String] = []
}
struct PortableQuarantine: Codable, Equatable, Sendable {
    var id: String
    var bytes: Data
    var reason: String
}
/// Semantic metadata lives in an existing opaque slot, separate from transport.
/// It is reproduced in format 2 without account associations or system fields.
struct RecoveryStoreState: Codable, Sendable {
    var version = 1
    var graphRequired: Bool? = nil
    var originals: [ArchivedRecord] = []
    var resolvedQuarantineKeys: [String] = []
}

struct RecoveryProgramSummary: Equatable, Sendable {
    var programID: String
    var datasetIDs: [String]
    var headHashes: [String]
    var projectedHeadHash: String?
    var knownCompletedWorkoutCount: Int
    var health: StoreHealth
}

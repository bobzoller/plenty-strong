import Foundation

struct SyncStatus: Equatable, Sendable {
    enum Phase: String, Sendable {
        case localOnly, accountUnavailable, pending, sending, upToDateForKnownRecords, incomplete, conflict
    }
    var phase: Phase = .localOnly
    var pendingRecordCount = 0
    var pendingCompletedWorkoutCount = 0
    var acknowledgedCompletedWorkoutCount = 0
    var lastRecordAcknowledgement: Date?
    var retryReason: String?
}
struct RecoveryCandidate: Equatable, Sendable {
    enum Verification: String, Sendable { case verified, incomplete, unsupported }
    let datasetID: UUID
    let programID: UUID
    let knownCompletedWorkoutCount: Int
    let status: Verification
}

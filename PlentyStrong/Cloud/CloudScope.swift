import Foundation

/// An opaque account identity from the container, never an email address. Scope
/// keys isolate metadata across accounts, containers and CloudKit environments.
struct CloudScope: Codable, Hashable, Sendable {
    enum Environment: String, Codable, Sendable { case development, production }
    let containerIdentifier: String
    let environment: Environment
    let accountIdentifier: String
    var key: String {
        // All members are strings; the canonical tuple makes delimiters harmless.
        "cloud-v1:" + (try! BackupService.hash([containerIdentifier, environment.rawValue, accountIdentifier]))
    }
}

struct PendingCloudRecord: Codable, Equatable, Sendable {
    let recordID: String
    let kind: CloudRecordKind
    let datasetID: UUID
    let identity: String
    let payload: Data
    let checksum: String
    let archiveReferences: [String]
    let programID: String?
    let isRoot: Bool
    let isCompletedWorkout: Bool
    let systemFields: Data?
}
struct CloudAcknowledgement: Codable, Equatable, Sendable {
    let recordID: String
    let verifiedHash: String
    let systemFields: Data
}
struct StoredCloudAcknowledgement: Codable, Equatable, Sendable {
    let verifiedHash: String
    let systemFields: Data
    let date: Date
}
/// Incoming original asset bytes are observations, never authoritative heads.
struct CloudObservation: Codable, Equatable, Sendable {
    let recordID: String
    let zoneName: String
    let recordType: String
    let claimedChecksum: String?
    let payload: Data
    let systemFields: Data
}
struct CloudScopeMetadata: Codable, Sendable {
    var version = 1
    var cursor: Data?
    var acknowledgements: [String: StoredCloudAcknowledgement] = [:]
    var observations: [String: CloudObservation] = [:]
    var conflictingRecordIDs: Set<String> = []
    var deletedRecordIDs: Set<String> = []
}
struct CloudBindings: Codable, Sendable {
    var version = 1
    var datasets: [String: String] = [:]
}

/// Only an attempted durable transport-metadata commit receives this wrapper.
/// Account checks, decoding/validation and source conflicts are not write failures.
struct CloudPersistenceError: Error { let underlying: any Error }

import Foundation

struct DownloadedCloudRecord: Equatable, Sendable {
    let observation: CloudObservation
    var recordID: String { observation.recordID }
    var rawCanonicalBytes: Data { observation.payload }
    var assetChecksum: String? { observation.claimedChecksum }
}
struct IngestionReport: Equatable, Sendable {
    var accepted: Int
    var identical: Int
    var waitingForDependencies: Int
    var quarantined: Int
    var health: StoreHealth
}
struct CloudIngestor: Sendable {
    let repository: TrainingRepository
    func ingest(_ batch: [DownloadedCloudRecord], scope: CloudScope) async throws -> IngestionReport {
        try await repository.retainCloudObservations(batch.map(\.observation), scope: scope)
        let proof = try RecoveryVerifier().verify(batch.map { ArchivedRecord(observation: $0.observation) })
        return try await repository.ingestCloud(proof, scope: scope)
    }
}

import CloudKit
import Foundation

/// Phone-local product choices. Never part of immutable history or an export.
struct CloudRecoveryPreferences: Codable {
    var enabled = false
    var activeProgramID: String?
}

enum CloudRuntimeConfiguration {
    // Signing-time review must explicitly change this Info.plist configuration.
    // DEBUG never constructs a real container, regardless of stored consent.
    static var environment: CloudScope.Environment? {
        switch Bundle.main.object(forInfoDictionaryKey: "PlentyStrongCloudEnvironment") as? String {
        case "Development": .development
        case "Production": .production
        default: nil
        }
    }
    static var isProvisioned: Bool {
        #if DEBUG
        false
        #else
        Bundle.main.object(forInfoDictionaryKey: "PlentyStrongCloudProvisioningReviewed") as? String == "YES" && environment != nil
        #endif
    }
    static let containerIdentifier = "iCloud.us.zoller.PlentyStrong"
}

#if DEBUG
actor SyntheticRecoveryAccount: CloudAccountProvider {
    let scope: CloudScope?
    init(_ scope: CloudScope?) { self.scope = scope }
    func currentScope() -> CloudScope? { scope }
}
/// DEBUG UI fixture replaces only external services; counts come from the writer.
actor SyntheticRecoveryTransport: CloudTransport {
    let repository: TrainingRepository
    let reason: String
    private var scope: CloudScope?
    init(repository: TrainingRepository, reason: String) { self.repository = repository; self.reason = reason }
    func start(scope: CloudScope) { self.scope = scope }
    func requestSync() {}
    func stop() { scope = nil }
    func syncStatus() async -> SyncStatus {
        guard let scope else { return .init() }
        var value = (try? await repository.cloudStatus(scope: scope)) ?? .init(phase: .incomplete)
        value.retryReason = reason; return value
    }
    func discoverRecoveryCandidates(scope: CloudScope) -> [RecoveryCandidate] { [] }
}
#endif

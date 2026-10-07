import Foundation

protocol CloudAccountProvider: Sendable {
    func currentScope() async throws -> CloudScope?
}
/// Optional cloud work owns its own lifecycle; it never acquires the app's
/// training operation gate, replaces workout models, or touches draft rows.
actor CloudSyncCoordinator {
    private let repository: TrainingRepository
    private let accountProvider: any CloudAccountProvider
    private let makeTransport: @Sendable () -> any CloudTransport
    private var transport: (any CloudTransport)?
    private var generation = 0
    private var status = SyncStatus()
    private var updateHandler: (@Sendable (CloudScope) async -> Void)?
    func setUpdateHandler(_ handler: (@Sendable (CloudScope) async -> Void)?) async {
        updateHandler = handler; await transport?.setUpdateHandler(handler)
    }
    func verifiedScope() async throws -> CloudScope? { try await accountProvider.currentScope() }
    func retainedObservations(scope: CloudScope) async throws -> [DownloadedCloudRecord] {
        guard try await accountProvider.currentScope() == scope else { throw CloudFailure.accountUnavailable }
        let records = try await repository.cloudMetadata(scope: scope).observations.values.map { DownloadedCloudRecord(observation: $0) }
        guard try await accountProvider.currentScope() == scope else { throw CloudFailure.accountUnavailable }
        return records
    }
    init(repository: TrainingRepository, accountProvider: any CloudAccountProvider,
         makeTransport: @escaping @Sendable () -> any CloudTransport) {
        self.repository = repository; self.accountProvider = accountProvider; self.makeTransport = makeTransport
    }
    func syncStatus() async -> SyncStatus {
        if let transport { return await transport.syncStatus() }; return status
    }
    /// Explicit selection/binding only. Merely discovering accounts never opts in.
    func enable(datasetID: UUID, expectedScope: CloudScope? = nil,
                associationAction: (@Sendable (CloudScope) async throws -> Void)? = nil) async throws {
        generation += 1; let ticket = generation
        let previous = transport; transport = nil
        await previous?.stop()
        guard ticket == generation else { return }
        guard let scope = try await accountProvider.currentScope() else {
            status.phase = .accountUnavailable; return
        }
        guard ticket == generation else { return }
        guard expectedScope == nil || expectedScope == scope else { throw CloudFailure.accountUnavailable }
        // Optional app admission serializes consent against local root selection.
        // All stop/account waits above remain outside that local action's lease.
        if let associationAction { try await associationAction(scope) }
        else { try await repository.bindDataset(datasetID: datasetID, to: scope) }
        guard ticket == generation else { return }
        let candidate = makeTransport()
        do { await candidate.setUpdateHandler(updateHandler); try await candidate.start(scope: scope) }
        catch {
            await candidate.stop()
            guard ticket == generation else { return }
            status = .init(phase: .accountUnavailable, retryReason: "iCloud recovery is unavailable. Local training remains saved.")
            throw error
        }
        guard ticket == generation else { await candidate.stop(); return }
        transport = candidate
    }
    func disable() async {
        generation += 1
        let previous = transport; transport = nil; status = .init()
        await previous?.stop()
    }
    func requestSync() async { await transport?.requestSync() }
    /// Fresh installations can inspect roots without binding or uploading.
    func discoverRecoveryCandidates() async throws -> [RecoveryCandidate] {
        guard let scope = try await accountProvider.currentScope() else { return [] }
        let reader = makeTransport()
        return try await reader.discoverRecoveryCandidates(scope: scope)
    }
}

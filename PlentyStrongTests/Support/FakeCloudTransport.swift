import Foundation
import CloudKit
@testable import PlentyStrong

actor FakeCloudAccountProvider: CloudAccountProvider {
    var account: CloudScope?
    init(_ account: CloudScope?) { self.account = account }
    func set(_ account: CloudScope?) { self.account = account }
    func currentScope() -> CloudScope? { account }
}
/// A synthetic immutable server, retained across fake process lifetimes.
actor FakeCloudServer {
    var records: [String: CloudObservation] = [:]
    var creates = 0
    var error: CKError.Code?
    var shouldPause = false
    var pauseContinuation: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func pauseNextCreate() { shouldPause = true }
    func waitForPause() async {
        if pauseContinuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resumeCreate() { pauseContinuation?.resume(); pauseContinuation = nil }
    func fail(_ code: CKError.Code?) { error = code }
    func put(_ observation: CloudObservation) { records[observation.recordID] = observation }
    func all() -> [CloudObservation] { Array(records.values) }
    func create(_ item: PendingCloudRecord) async throws -> CloudObservation {
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { pauseContinuation = $0; observer?.resume(); observer = nil }
        }
        if let error { throw CKError(error) }
        if let stored = records[item.recordID] { return stored }
        let observation = CloudObservation(recordID: item.recordID, zoneName: CloudRecordCodec.zoneID(item.datasetID).zoneName,
            recordType: item.kind.recordType, claimedChecksum: item.checksum, payload: item.payload, systemFields: Data([9]))
        records[item.recordID] = observation; creates += 1
        return observation
    }
}
actor FakeCloudTransport: CloudTransport {
    let repository: TrainingRepository
    let accountProvider: FakeCloudAccountProvider
    let server: FakeCloudServer
    var scope: CloudScope?
    var dropNextAcknowledgement = false
    var startedCount = 0
    var status = SyncStatus()
    init(repository: TrainingRepository, accountProvider: FakeCloudAccountProvider, server: FakeCloudServer) {
        self.repository = repository; self.accountProvider = accountProvider; self.server = server
    }
    func simulateDeathAfterSave() { dropNextAcknowledgement = true }
    func start(scope: CloudScope) async throws {
        guard await accountProvider.currentScope() == scope else { throw CloudFailure.accountUnavailable }
        self.scope = scope; startedCount += 1
        status = try await repository.cloudStatus(scope: scope)
    }
    func stop() { scope = nil; status = .init() }
    func syncStatus() -> SyncStatus { status }
    func requestSync() async {
        guard let scope else { return }
        do {
            guard await accountProvider.currentScope() == scope else { throw CloudFailure.accountUnavailable }
            for record in try await repository.pendingCloudRecords(scope: scope) {
                guard await accountProvider.currentScope() == scope, self.scope == scope else { throw CloudFailure.accountUnavailable }
                let observation = try await server.create(record)
                if dropNextAcknowledgement { dropNextAcknowledgement = false; return }
                guard await accountProvider.currentScope() == scope else { throw CloudFailure.accountUnavailable }
                try await repository.acceptCloudSaveObservation(observation, scope: scope)
            }
            status = try await repository.cloudStatus(scope: scope)
        } catch {
            status = (try? await repository.cloudStatus(scope: scope)) ?? .init()
            if error as? CloudFailure == .accountUnavailable { status.phase = .accountUnavailable }
            status.retryReason = "Synthetic transport failure; durable pending work retained."
        }
    }
    func discoverRecoveryCandidates(scope: CloudScope) async throws -> [RecoveryCandidate] {
        guard await accountProvider.currentScope() == scope else { throw CloudFailure.accountUnavailable }
        let observations = await server.all()
        guard await accountProvider.currentScope() == scope else { throw CloudFailure.accountUnavailable }
        try await repository.retainCloudObservations(observations, scope: scope)
        return CloudRecordCodec.recoveryCandidates(observations)
    }
}

/// Throws once before returning the selected synthetic account. Used directly
/// by the production callback handler, never by FakeCloudTransport.
actor ThrowingCloudAccountProvider: CloudAccountProvider {
    var account: CloudScope?
    var failure: CKError.Code?
    private var verificationGate: ControlledCloudRetryClock?
    init(_ account: CloudScope?, failure: CKError.Code? = nil) { self.account = account; self.failure = failure }
    func set(_ account: CloudScope?) { self.account = account }
    func failNext(_ code: CKError.Code) { failure = code }
    func blockNextVerification(_ gate: ControlledCloudRetryClock) { verificationGate = gate }
    func currentScope() async throws -> CloudScope? {
        if let gate = verificationGate { verificationGate = nil; await gate.wait(0) }
        if let failure { self.failure = nil; throw CKError(failure) }; return account
    }
}

/// Holds the production retry wait until the test advances it. Cancellation is
/// checked by the transport after the wait returns, before retry/requestSync.
actor ControlledCloudRetryClock {
    private var sleepers: [(Double, CheckedContinuation<Void, Never>)] = []
    nonisolated private let time = LockedRetryTime()
    nonisolated func now() -> Date { time.now() }
    func wait(_ delay: Double) async {
        await withCheckedContinuation { sleepers.append((delay, $0)) }
    }
    func sleeperCount() -> Int { sleepers.count }
    func advance(by seconds: Double? = nil) {
        let waiting = sleepers; sleepers.removeAll()
        time.advance(seconds ?? waiting.map(\.0).max() ?? 0)
        for (_, continuation) in waiting { continuation.resume() }
    }
}
private final class LockedRetryTime: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1791316800)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

/// Replaces only the external network operation, below requestSync's real
/// account verification, queue, generation and retry-completion handling.
actor CloudNetworkSyncProbe {
    private var attempts = 0
    private var action: (@Sendable () async throws -> Void)?
    func setAction(_ action: (@Sendable () async throws -> Void)?) { self.action = action }
    func sync() async throws { attempts += 1; try await action?() }
    func count() -> Int { attempts }
}

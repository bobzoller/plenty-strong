import CloudKit
import Foundation

protocol CloudTransport: Sendable {
    func start(scope: CloudScope) async throws
    func setUpdateHandler(_ handler: (@Sendable (CloudScope) async -> Void)?) async
    func requestSync() async
    func stop() async
    func syncStatus() async -> SyncStatus
    func discoverRecoveryCandidates(scope: CloudScope) async throws -> [RecoveryCandidate]
}

extension CloudTransport {
    func setUpdateHandler(_ handler: (@Sendable (CloudScope) async -> Void)?) async {}
}

struct CloudKitAccountProvider: CloudAccountProvider {
    let container: CKContainer
    let environment: CloudScope.Environment
    func currentScope() async throws -> CloudScope? {
        guard try await container.accountStatus() == .available,
              let identifier = container.containerIdentifier else { return nil }
        let user = try await container.userRecordID()
        return CloudScope(containerIdentifier: identifier, environment: environment, accountIdentifier: user.recordName)
    }
}

/// Explicitly constructed only after an opt-in. No cloud initialization occurs
/// on the local app launch path. Engine scheduling is manual to verify the
/// current account before every fetch, send, batch, and acknowledgement.
actor CloudKitTransport: CloudTransport, CKSyncEngineDelegate {
    private let container: CKContainer?
    private let accountProvider: any CloudAccountProvider
    private let repository: TrainingRepository
    private var scope: CloudScope?
    private var engine: CKSyncEngine?
    private var status = SyncStatus()
    private var updateHandler: (@Sendable (CloudScope) async -> Void)?
    // Explicit async also keeps concrete awaited calls off the no-op default.
    func setUpdateHandler(_ handler: (@Sendable (CloudScope) async -> Void)?) async { updateHandler = handler }
    private func notify(_ scope: CloudScope) {
        guard let updateHandler else { return }
        // Detached from the serial SDK callback; never fetch/send recursively.
        Task { await updateHandler(scope) }
    }
    private var generation = 0
    private var syncing = false
    private var retryTask: Task<Void, Never>?
    private var failures = 0
    private var assets: [URL] = []
    private var verificationRecordIDs: Set<CKRecord.ID> = []
    // If durable handling fails, ignore later cursor advances for this engine.
    private var persistenceFailed = false
    private var retryDelay: Double?
    private var deferredCallbacks: [CloudTransportCallback] = []
    private var drainingCallbacks = false
    private enum RetryOwner { case callback, operation }
    private var callbackRetryReason: String?
    private var operationRetryReason: String?
    private var operationFailureSerial = 0
    private var retryAfterCurrentSync = false
    private var retryAfterCallbacks = false
    private var retryScheduleToken = 0
    // Conservatively retain the greatest provider floor until all retry owners
    // resolve. Recovery of one owner cannot discharge the other's server limit.
    private var providerNotBefore: Date?

    init(container: CKContainer, accountProvider: any CloudAccountProvider, repository: TrainingRepository) {
        self.container = container; self.accountProvider = accountProvider; self.repository = repository
    }
    #if DEBUG
    private var retryNowForTesting: (@Sendable () -> Date)?
    private var retryWaitForTesting: (@Sendable (Double) async throws -> Void)?
    private var networkSyncForTesting: (@Sendable () async throws -> Void)?
    /// Inert adapter for SDK events whose initializers are not public. It calls
    /// the production callback handler and never creates a container or engine.
    init(testingScope: CloudScope, accountProvider: any CloudAccountProvider, repository: TrainingRepository,
         retryWait: (@Sendable (Double) async throws -> Void)? = nil,
         retryNow: (@Sendable () -> Date)? = nil,
         networkSync: (@Sendable () async throws -> Void)? = nil) {
        container = nil; self.scope = testingScope; self.accountProvider = accountProvider; self.repository = repository
        retryWaitForTesting = retryWait; retryNowForTesting = retryNow; networkSyncForTesting = networkSync
    }
    func deliverCallbackForTesting(_ callback: CloudTransportCallback) async {
        guard let scope else { return }; await processCallback(callback, scope: scope, engine: nil)
    }
    func deliverSDKFailureForTesting(_ error: CKError) async {
        guard let scope else { return }; await recordFailure(error, scope: scope)
    }
    func retryScheduleTokenForTesting() -> Int { retryScheduleToken }
    func deliverScheduledRetryForTesting(token: Int) async { await retry(ticket: generation, scheduleToken: token) }
    func callbackDiagnosticsForTesting() -> (persistenceFailed: Bool, retryDelay: Double?, deferredCount: Int) {
        (persistenceFailed, retryDelay, deferredCallbacks.count)
    }
    #endif
    func start(scope: CloudScope) async throws {
        guard let container else { throw CloudFailure.accountUnavailable }
        let (ticket, previous) = invalidateLifecycle()
        await previous?.cancelOperations()
        guard ticket == generation else { throw CancellationError() }
        guard try await accountProvider.currentScope() == scope, ticket == generation,
              container.containerIdentifier == scope.containerIdentifier else { throw CloudFailure.accountUnavailable }
        let bytes = try await repository.cloudCursor(scope: scope)
        guard ticket == generation else { throw CancellationError() }
        let serialization = try bytes.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        self.scope = scope; persistenceFailed = false; verificationRecordIDs.removeAll()
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: serialization, delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration); self.engine = engine
        try await rebuildPending(scope: scope, engine: engine)
        let updatedStatus = try await repository.cloudStatus(scope: scope)
        guard ticket == generation else { return }
        status = updatedStatus
    }
    private func invalidateLifecycle() -> (Int, CKSyncEngine?) {
        generation += 1; providerNotBefore = nil; retryScheduleToken += 1; retryTask?.cancel(); retryTask = nil; retryDelay = nil; deferredCallbacks.removeAll()
        callbackRetryReason = nil; operationRetryReason = nil; retryAfterCurrentSync = false; retryAfterCallbacks = false
        let previous = engine; engine = nil; scope = nil; status = .init(); verificationRecordIDs.removeAll()
        return (generation, previous)
    }
    func stop() async {
        let (ticket, previous) = invalidateLifecycle()
        await previous?.cancelOperations()
        // The in-flight request owns asset cleanup after cancellation returns.
        if ticket == generation && !syncing { cleanupAssets() }
    }
    func syncStatus() -> SyncStatus { status }
    private func checkAccount(_ expected: CloudScope, engine expectedEngine: CKSyncEngine? = nil) async throws {
        guard scope == expected || expectedEngine == nil,
              expectedEngine == nil || engine === expectedEngine else { throw CloudFailure.accountUnavailable }
        guard try await accountProvider.currentScope() == expected,
              expectedEngine == nil || (scope == expected && engine === expectedEngine) else { throw CloudFailure.accountUnavailable }
    }
    private func rebuildPending(scope: CloudScope, engine: CKSyncEngine) async throws {
        let records = try await repository.pendingCloudRecords(scope: scope)
        let metadata = try await repository.cloudMetadata(scope: scope)
        guard self.scope == scope, self.engine === engine else { return }
        // Engine state is a cache. Remove stale/deletion work and rebuild only
        // account-permitted, immutable sends from authoritative durable rows.
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        let permitted = records.filter { !metadata.conflictingRecordIDs.contains($0.recordID) }
        let zones = Set(permitted.map { CloudRecordCodec.zoneID($0.datasetID) })
        engine.state.add(pendingDatabaseChanges: zones.map { .saveZone(CKRecordZone(zoneID: $0)) })
        engine.state.add(pendingRecordZoneChanges: permitted.map { .saveRecord(CloudRecordCodec.recordID($0)) })
    }
    private var providerAllowsRequest: Bool { providerNotBefore.map { retryNow() >= $0 } ?? true }
    func requestSync() async {
        guard !syncing, let scope, providerAllowsRequest else { return }
        let engine = self.engine
        #if DEBUG
        guard engine != nil || networkSyncForTesting != nil else { return }
        #else
        guard engine != nil else { return }
        #endif
        let ticket = generation
        let failureSerial = operationFailureSerial
        // The SDK retry keeps ownership until this attempt actually recovers;
        // an occupied callback queue may cause this explicit request to return.
        syncing = true
        defer {
            syncing = false; cleanupAssets()
            if ticket == generation && retryAfterCurrentSync {
                retryAfterCurrentSync = false
                handOffExpiredRetry(ticket: ticket)
            }
        }
        do {
            await drainCallbacks(scope: scope, engine: engine)
            guard deferredCallbacks.isEmpty, !persistenceFailed else { return }
            try await checkAccount(scope, engine: engine)
            guard ticket == generation, self.scope == scope, providerAllowsRequest else { return }
            guard try await performNetworkSync(scope: scope, engine: engine, ticket: ticket) else { return }
            guard ticket == generation else { return }
            let finalStatus = try await repository.cloudStatus(scope: scope)
            guard ticket == generation else { return }
            // Awaited fetch/send may have delivered another SDK failure. Only
            // this attempt's unchanged failure token permits clearing its owner.
            if operationFailureSerial == failureSerial && verificationRecordIDs.isEmpty &&
                deferredCallbacks.isEmpty && !persistenceFailed {
                operationRetryReason = nil
                cancelRetryIfResolved()
            }
            let failureStatus = status
            status = finalStatus
            status.retryReason = operationRetryReason ?? callbackRetryReason
            if operationFailureSerial != failureSerial || !deferredCallbacks.isEmpty || persistenceFailed || !verificationRecordIDs.isEmpty {
                status.retryReason = failureStatus.retryReason ?? status.retryReason
                if failureStatus.phase == .accountUnavailable || failureStatus.phase == .incomplete { status.phase = failureStatus.phase }
            }
            if status.retryReason == nil && status.pendingRecordCount == 0 { failures = 0 }
        } catch {
            guard ticket == generation else { return }
            await recordFailure(error, scope: scope)
        }
    }
    private func performNetworkSync(scope: CloudScope, engine: CKSyncEngine?, ticket: Int) async throws -> Bool {
        #if DEBUG
        if let networkSyncForTesting {
            guard ticket == generation, self.scope == scope, providerAllowsRequest else { return false }
            try await networkSyncForTesting(); return true
        }
        #endif
        guard let engine, let container else { throw CloudFailure.accountUnavailable }
        try await rebuildPending(scope: scope, engine: engine)
        guard ticket == generation else { return false }
        let sendingStatus = try await repository.cloudStatus(scope: scope)
        guard ticket == generation else { return false }
        status = sendingStatus; status.phase = .sending
        status.retryReason = operationRetryReason ?? callbackRetryReason
        guard ticket == generation, self.scope == scope, providerAllowsRequest else { return false }
        try await engine.fetchChanges()
        try await checkAccount(scope, engine: engine)
        guard !persistenceFailed else { throw CloudFailure.persistence }
        guard ticket == generation, self.scope == scope, providerAllowsRequest else { return false }
        try await engine.sendChanges()
        // Save/conflict responses may omit downloaded CKAsset bytes. Fetch
        // those exact IDs outside the serial delegate callback before ack.
        for id in verificationRecordIDs {
            try await checkAccount(scope, engine: engine)
            guard ticket == generation, self.scope == scope, providerAllowsRequest else { return false }
            let fetched = try await container.privateCloudDatabase.record(for: id)
            await processSaveResponse(fetched, scope: scope, engine: engine, allowDeferredFetch: false)
            guard ticket == generation else { return false }
            verificationRecordIDs.remove(id)
        }
        return true
    }
    private func retryNow() -> Date {
        #if DEBUG
        if let retryNowForTesting { return retryNowForTesting() }
        #endif
        return Date()
    }
    private func waitForRetry(_ delay: Double) async throws {
        #if DEBUG
        if let retryWaitForTesting { try await retryWaitForTesting(delay); try Task.checkCancellation(); return }
        #endif
        try await Task.sleep(for: .seconds(delay))
    }
    private func cleanupAssets() {
        for url in assets { try? FileManager.default.removeItem(at: url) }; assets.removeAll()
    }
    private func handOffExpiredRetry(ticket: Int) {
        guard ticket == generation, !persistenceFailed,
              operationRetryReason != nil || callbackRetryReason != nil else { return }
        let scheduleToken = retryScheduleToken
        Task { [weak self] in await self?.retry(ticket: ticket, scheduleToken: scheduleToken) }
    }
    private func cancelRetryIfResolved() {
        guard callbackRetryReason == nil, operationRetryReason == nil else { return }
        retryScheduleToken += 1
        retryAfterCurrentSync = false; retryAfterCallbacks = false; providerNotBefore = nil
        retryTask?.cancel(); retryTask = nil; retryDelay = nil
    }
    private func recordFailure(_ error: any Error, scope: CloudScope, owner: RetryOwner = .operation) async {
        defer { notify(scope) }
        let ticket = generation
        guard self.scope == scope else { return }
        if owner == .operation { operationFailureSerial += 1 }
        let metadataStatus = try? await repository.cloudStatus(scope: scope)
        guard ticket == generation, self.scope == scope else { return }
        if let metadataStatus { status = metadataStatus }
        if error as? CloudFailure == .accountUnavailable || (error as? CKError)?.code == .notAuthenticated {
            status.phase = .accountUnavailable
            status.retryReason = "Sign in to the original iCloud account to resume recovery."
            return
        }
        if error as? CloudFailure == .bindingMetadataUnavailable {
            status.phase = .incomplete
            status.retryReason = "Recovery association metadata needs repair. Local training remains available."
            return
        }
        if persistenceFailed {
            status.phase = .incomplete; status.retryReason = "Recovery metadata could not be saved. Restart recovery to retry safely."; return
        }
        if status.phase == .conflict {
            status.retryReason = "A cloud record differs from the saved original. Recovery needs review."; return
        }
        status.phase = .pending
        let reason = Self.retryReason(error)
        if owner == .callback { callbackRetryReason = reason } else { operationRetryReason = reason }
        status.retryReason = reason
        failures = min(failures + 1, 10)
        let now = retryNow()
        if let seconds = (error as? CKError)?.retryAfterSeconds, seconds > 0 {
            let deadline = now.addingTimeInterval(seconds)
            providerNotBefore = max(providerNotBefore ?? deadline, deadline)
        }
        let floor = max(0, providerNotBefore?.timeIntervalSince(now) ?? 0)
        scheduleRetry(delay: max(floor, min(pow(2, Double(failures)) * 5, 3_600)), ticket: ticket)
    }
    private func scheduleRetry(delay: Double, ticket: Int) {
        retryDelay = delay
        // Replacing a timer never replaces an outstanding provider floor.
        retryAfterCurrentSync = false; retryAfterCallbacks = false
        retryTask?.cancel(); retryScheduleToken += 1
        let scheduleToken = retryScheduleToken
        retryTask = Task { [weak self] in
            do { try await self?.waitForRetry(delay) } catch { return }
            await self?.retry(ticket: ticket, scheduleToken: scheduleToken)
        }
    }
    private func retry(ticket: Int, scheduleToken: Int) async {
        // A queued elapsed handoff must not consume a newer scheduled backoff.
        guard generation == ticket, retryScheduleToken == scheduleToken, let scope,
              operationRetryReason != nil || callbackRetryReason != nil else { return }
        if let deadline = providerNotBefore, retryNow() < deadline {
            scheduleRetry(delay: deadline.timeIntervalSince(retryNow()), ticket: ticket); return
        }
        retryTask = nil; retryDelay = nil
        // A timer that expires during an awaited sync cannot start overlapping
        // work or disappear at the syncing guard. Hand it off after this attempt.
        if syncing { retryAfterCurrentSync = true; return }
        if drainingCallbacks { retryAfterCallbacks = true; return }
        await drainCallbacks(scope: scope, engine: engine)
        guard generation == ticket, retryScheduleToken == scheduleToken,
              deferredCallbacks.isEmpty, !persistenceFailed,
              operationRetryReason != nil || callbackRetryReason != nil else { return }
        if let deadline = providerNotBefore, retryNow() < deadline {
            scheduleRetry(delay: deadline.timeIntervalSince(retryNow()), ticket: ticket); return
        }
        if syncing { retryAfterCurrentSync = true; return }
        await requestSync()
    }
    private static func retryReason(_ error: any Error) -> String {
        switch (error as? CKError)?.code {
        case .quotaExceeded: "iCloud storage is full. Local history and pending recovery records are retained."
        case .networkFailure, .networkUnavailable: "Waiting for a network connection. Local training remains available."
        case .requestRateLimited, .serviceUnavailable, .zoneBusy: "iCloud is busy. Recovery will retry later."
        default: "Recovery could not finish. Pending records are retained for retry."
        }
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let scope, engine === syncEngine, !persistenceFailed else { return nil }
        do {
            try await checkAccount(scope, engine: syncEngine)
            let pending = try await repository.pendingCloudRecords(scope: scope)
            let metadata = try await repository.cloudMetadata(scope: scope)
            guard self.scope == scope, engine === syncEngine else { return nil }
            let wanted = Set(syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }.compactMap { change -> CKRecord.ID? in
                if case .saveRecord(let id) = change { return id }; return nil
            })
            var records: [CKRecord] = []
            for item in pending where wanted.contains(CloudRecordCodec.recordID(item)) && !metadata.conflictingRecordIDs.contains(item.recordID) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("plenty-cloud-" + UUID().uuidString)
                assets.append(url)
                records.append(try CloudRecordCodec.makeRecord(item, assetURL: url))
                if records.count == 100 { break }
            }
            // Revalidate after building assets; no await occurs between this
            // verification and returning this account-bound batch to the engine.
            try await checkAccount(scope, engine: syncEngine)
            return records.isEmpty ? nil : .init(recordsToSave: records, atomicByZone: false)
        } catch { await recordFailure(error, scope: scope); return nil }
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine, let scope else { return }
        let ticket = generation
        if case .accountChange(let change) = event {
            if case .signIn(let user) = change.changeType, user.recordName == scope.accountIdentifier { return }
            // Stop using this engine immediately. Cancellation runs after the
            // callback returns; never await fetch/send inside a delegate event.
            generation += 1; providerNotBefore = nil; retryScheduleToken += 1; self.scope = nil; engine = nil; retryTask?.cancel(); retryTask = nil; retryDelay = nil; deferredCallbacks.removeAll()
            callbackRetryReason = nil; operationRetryReason = nil; retryAfterCurrentSync = false; retryAfterCallbacks = false
            status.phase = .accountUnavailable; status.retryReason = "The iCloud account changed. Pending records remain bound to the original account."
            Task { await syncEngine.cancelOperations() }
            notify(scope)
            return
        }
        do {
            switch event {
            case .stateUpdate(let update):
                await processCallback(.cursor(try JSONEncoder().encode(update.stateSerialization)), scope: scope, engine: syncEngine)
            case .fetchedDatabaseChanges(let changes):
                let deletedZones = changes.deletions.filter { $0.zoneID.zoneName.hasPrefix(CloudRecordCodec.zonePrefix) }
                await processCallback(.fetched([], deletedRecordIDs: deletedZones.map { "zone:" + $0.zoneID.zoneName }), scope: scope, engine: syncEngine)
            case .fetchedRecordZoneChanges(let changes):
                await processCallback(.fetchedRecords(changes.modifications.map(\.record), deletedRecordIDs: changes.deletions.map { $0.recordID.recordName }), scope: scope, engine: syncEngine)
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    await processSaveResponse(record, scope: scope, engine: syncEngine)
                }
                for failure in changes.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                        // Never trust the error's hash field without reading bytes.
                        await processSaveResponse(server, scope: scope, engine: syncEngine)
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    } else { await recordFailure(failure.error, scope: scope) }
                }
            case .sentDatabaseChanges(let changes):
                for failed in changes.failedZoneSaves { await recordFailure(failed.error, scope: scope) }
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error { await recordFailure(error, scope: scope) }
            default: break
            }
        } catch {
            guard ticket == generation, engine === syncEngine else { return }
            await recordFailure(error, scope: scope)
        }
    }
    private func processSaveResponse(_ record: CKRecord, scope: CloudScope, engine: CKSyncEngine, allowDeferredFetch: Bool = true) async {
        let ticket = generation
        do {
            guard self.scope == scope, self.engine === engine else { return }
            if allowDeferredFetch && (record["payload"] as? CKAsset)?.fileURL == nil {
                verificationRecordIDs.insert(record.recordID)
                status.phase = .incomplete; status.retryReason = "Saved recovery records still need their original bytes verified."
                return
            }
            await processCallback(.saved(try CloudRecordCodec.observation(record)), scope: scope, engine: engine)
        }
        catch {
            guard ticket == generation, self.engine === engine else { return }
            await recordFailure(error, scope: scope)
        }
    }
    private func processCallback(_ callback: CloudTransportCallback, scope: CloudScope, engine: CKSyncEngine?) async {
        guard self.scope == scope, !persistenceFailed, engine == nil || self.engine === engine else { return }
        // Capture readable fetched assets before returning the SDK callback: its
        // temporary file URLs are not a durable source for a later account retry.
        let captured: CloudTransportCallback
        if case .fetchedRecords(let records, let deletions) = callback,
           let observations = try? records.map({ try CloudRecordCodec.observation($0) }) {
            captured = .fetched(observations, deletedRecordIDs: deletions)
        } else { captured = callback }
        // Keep only the latest consecutive state snapshot behind earlier data.
        if case .cursor = captured, case .cursor? = deferredCallbacks.last { deferredCallbacks.removeLast() }
        deferredCallbacks.append(captured)
        await drainCallbacks(scope: scope, engine: engine)
    }
    private func drainCallbacks(scope: CloudScope, engine: CKSyncEngine?) async {
        guard self.scope == scope, !persistenceFailed, !drainingCallbacks,
              engine == nil || self.engine === engine else { return }
        let ticket = generation
        drainingCallbacks = true
        defer {
            drainingCallbacks = false
            if ticket == generation && retryAfterCallbacks {
                retryAfterCallbacks = false
                if syncing { retryAfterCurrentSync = true }
                else { handOffExpiredRetry(ticket: ticket) }
            }
        }
        while let callback = deferredCallbacks.first {
            // Verification errors retain this callback and its following cursor
            // for bounded retry. They never set the durable-write poison flag.
            do { try await checkAccount(scope, engine: engine) }
            catch {
                guard ticket == generation, self.scope == scope else { return }
                await recordFailure(error, scope: scope, owner: .callback); return
            }
            guard ticket == generation, self.scope == scope else { return }
            do {
                switch callback {
                case .cursor(let bytes): try await repository.saveCloudCursor(bytes, scope: scope)
                case .fetched(let observations, let deletions):
                    try await repository.retainCloudObservations(observations, deletedRecordIDs: deletions, scope: scope)
                case .fetchedRecords(let records, let deletions):
                    let observations = try records.map { try CloudRecordCodec.observation($0) }
                    try await repository.retainCloudObservations(observations, deletedRecordIDs: deletions, scope: scope)
                case .saved(let observation):
                    try await repository.acceptCloudSaveObservation(observation, scope: scope)
                }
            } catch {
                guard ticket == generation, self.scope == scope else { return }
                if error is CloudPersistenceError { persistenceFailed = true }
                let metadata = try? await repository.cloudMetadata(scope: scope)
                guard ticket == generation, self.scope == scope else { return }
                // A successfully retained immutable conflict is a completed
                // observation, not a failed durable write or retryable save.
                if case .saved(let observation) = callback,
                   metadata?.conflictingRecordIDs.contains(observation.recordID) == true,
                   !(error is CloudPersistenceError) {
                    deferredCallbacks.removeFirst()
                    await recordFailure(error, scope: scope, owner: .callback)
                    continue
                }
                await recordFailure(error, scope: scope, owner: .callback); return
            }
            guard ticket == generation, self.scope == scope else { return }
            deferredCallbacks.removeFirst()
            notify(scope)
        }
        let currentStatus = try? await repository.cloudStatus(scope: scope)
        guard ticket == generation, self.scope == scope else { return }
        callbackRetryReason = nil
        if let currentStatus { status = currentStatus }
        // Durable callback recovery resolves its own retry only. An unrelated
        // SDK fetch/save failure still needs the shared timer to request sync.
        status.retryReason = operationRetryReason
        cancelRetryIfResolved()
    }
    func discoverRecoveryCandidates(scope: CloudScope) async throws -> [RecoveryCandidate] {
        guard let container else { throw CloudFailure.accountUnavailable }
        try await checkAccount(scope)
        let zones = try await container.privateCloudDatabase.allRecordZones()
        var observations: [CloudObservation] = []
        // Read-only enumeration uses per-zone change fetches, avoiding query
        // indexes and never creating a zone, subscription, or dataset binding.
        for zone in zones where zone.zoneID.zoneName.hasPrefix(CloudRecordCodec.zonePrefix) {
            var token: CKServerChangeToken?
            var more = true
            while more {
                try await checkAccount(scope)
                let changes = try await container.privateCloudDatabase.recordZoneChanges(inZoneWith: zone.zoneID, since: token)
                var page: [CloudObservation] = []
                for (_, result) in changes.modificationResultsByID {
                    let record = try result.get().record
                    page.append(try CloudRecordCodec.observation(record))
                }
                try await checkAccount(scope)
                try await repository.retainCloudObservations(page, scope: scope)
                observations.append(contentsOf: page)
                token = changes.changeToken; more = changes.moreComing
            }
        }
        try await checkAccount(scope)
        try await repository.retainCloudObservations(observations, scope: scope)
        return CloudRecordCodec.recoveryCandidates(observations)
    }
}

enum CloudFailure: Error, Equatable { case accountUnavailable, persistence, bindingMetadataUnavailable }

enum CloudTransportCallback: Sendable {
    case cursor(Data)
    case fetched([CloudObservation], deletedRecordIDs: [String])
    case fetchedRecords([CKRecord], deletedRecordIDs: [String])
    case saved(CloudObservation)
}

import Foundation
import Testing
import TrainingCore
@testable import PlentyStrong

@Suite(.serialized) @MainActor struct DeveloperDemoModeTests {
    private let instant = ISO8601DateFormatter().date(from: "2026-10-10T20:00:00Z")!
    private func empty() async throws -> (AppComposition, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = try await TrainingRepository.openInBackground(at: directory.appendingPathComponent("real.store"))
        let real = AppComposition(repository: repository)
        real.now = { instant }; real.timeZoneID = "Pacific/Honolulu"
        return (real, directory)
    }
    @Test func admittedSeedHasSixCompleteWorkoutsSteadyDosesAndExactTargets() async throws {
        let (real, directory) = try await empty()
        let mode = DeveloperDemoMode(real: real, directory: directory.appendingPathComponent("demo"))
        await mode.setEnabled(true)
        #expect(mode.errorText == nil)
        let snapshot = try #require(mode.active.workout?.snapshot)
        #expect(snapshot.state.config.profileID == "starter-upper-v1")
        #expect(snapshot.state.config.goal == .size)
        #expect(snapshot.state.schedulingPolicy == .flexibleV1)
        #expect(snapshot.draft == nil)
        let workouts = snapshot.history.compactMap { envelope -> CompletedWorkout? in
            if case let .workout(event, _) = envelope.command { return event }; return nil
        }
        #expect(workouts.map(\.slotID) == ["SUN", "TUE", "THU", "SUN", "TUE", "THU"])
        #expect(snapshot.state.exercises.values.allSatisfy { $0.mode == .normal && $0.normalSets == 3 && $0.starterState?.doseStage == .fixed && !$0.interruptedReturn })
        #expect(snapshot.state.activePrescription.exercises.allSatisfy { $0.phase == .normal && $0.sets.allSatisfy { $0.targetReps != nil } })
        for row in snapshot.state.activePrescription.exercises {
            let summary = MovementPrescriptionSummary.make(row: row, state: snapshot.state, history: snapshot.history, draft: nil)
            let prior = try #require(summary.prior)
            #expect(prior.phase == .normal && prior.effortScope == .allWorkingSets)
            #expect(prior.actualSets.count == 3)
            #expect(summary.targetReps == row.sets.compactMap(\.targetReps))
            #expect(!prior.contextLabels.contains("Previous goals unavailable"))
        }
        for envelope in snapshot.history {
            guard case .workout = envelope.command else { continue }
            let issued = try #require(MovementPrescriptionSummary.issuedWorkout(envelope: envelope, history: snapshot.history))
            #expect(issued.displayed.exercises.allSatisfy { $0.sets.allSatisfy { $0.targetReps != nil } })
        }
        for event in workouts {
            #expect(event.exercises.allSatisfy { $0.status == .completed && $0.problem == .none && $0.actualSets.count == 3 })
            for log in event.exercises {
                let movement = try #require(snapshot.state.config.movements.first { $0.id == log.baseMovementID })
                if movement.loadingMode == .bodyweight { #expect(log.actualLoad == nil) }
                if movement.repCounting == .perSide { #expect(log.actualSets.allSatisfy { $0.leftReps == $0.reps && $0.rightReps == $0.reps }) }
                if let load = log.actualLoad { #expect(movement.availableLoads.contains(load)) }
            }
        }
        _ = try BackupService.validate(await mode.active.repository!.exportBackup())
        try await mode.active.workout!.start(easierToday: false)
        #expect(mode.active.workout?.snapshot.draft != nil)
        await mode.setEnabled(false)
        #expect(mode.active === real)
        #expect(real.workout == nil)
        #expect(try await real.repository!.exportBackup().heads.isEmpty)
    }
    @Test func realDraftAndMetadataAreExactWhileDemoEditsAndOldCallbacksAreIsolated() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let model = WorkoutViewModel(repository: s.repository, snapshot: try await s.repository.snapshot(programID: s.programID), timeZoneID: "Pacific/Honolulu", now: { instant })
        let real = AppComposition(repository: s.repository, workout: model)
        real.now = { instant }; real.timeZoneID = "Pacific/Honolulu"
        try await model.start(easierToday: false)
        let row = try #require(model.snapshot.draft?.displayed.exercises.first)
        try await model.confirmLoad(movementID: row.movementID, load: model.movement(for: row).availableLoads[0])
        try await model.recordSet(movementID: row.movementID, index: 0, actual: ActualSet(reps: 9))
        let before = try await s.repository.exportBackup()
        let mode = DeveloperDemoMode(real: real, directory: s.storeURL.deletingLastPathComponent().appendingPathComponent("demo"))
        await mode.setEnabled(true)
        #expect(mode.errorText == nil)
        let demoModel = try #require(mode.active.workout)
        let identity = mode.viewIdentity
        try await demoModel.start(easierToday: false)
        await #expect(throws: (any Error).self) { try await model.recordEffort(movementID: row.movementID, effort: .tooEasy) }
        await #expect(throws: (any Error).self) { _ = try await real.restoreBackupData(BackupService.bytes(before)) }
        #expect(try await s.repository.exportBackup() == before)
        await mode.setEnabled(false)
        #expect(mode.active.workout === model)
        #expect(mode.viewIdentity != identity)
        #expect(try await s.repository.exportBackup() == before)
        await #expect(throws: (any Error).self) { try await demoModel.prepareToday() }
        await mode.setEnabled(true)
        #expect(mode.active.workout?.snapshot.draft == nil)
        #expect(mode.active.workout?.programID != demoModel.programID)
        await mode.setEnabled(false)
    }
    @Test func missingEnabledSandboxFailsOpenToRealContextAndRetry() async throws {
        let (real, directory) = try await empty()
        let url = directory.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let missing = UUID().uuidString
        try Data("{\"enabled\":true,\"explained\":true,\"sandbox\":\"\(missing)\"}".utf8).write(to: url.appendingPathComponent("selection.json"))
        let before = try await real.repository!.exportBackup()
        let mode = DeveloperDemoMode(real: real, directory: url)
        await mode.load()
        #expect(mode.active === real && !mode.enabled && mode.errorText != nil)
        #expect(try await real.repository!.exportBackup() == before)
        await mode.setEnabled(true)
        #expect(mode.enabled && mode.errorText == nil)
        await mode.setEnabled(false)
    }
    @Test func seedAndSwitchKeepMainActorResponsive() async throws {
        let (real, directory) = try await empty()
        let mode = DeveloperDemoMode(real: real, directory: directory.appendingPathComponent("demo"))
        let clock = ContinuousClock()
        var last = clock.now
        var maxGap: Duration = .zero
        var ticks = 0
        let switching = Task { await mode.setEnabled(true) }
        while !mode.enabled && mode.errorText == nil {
            try await Task.sleep(for: .milliseconds(10))
            let current = clock.now
            maxGap = max(maxGap, last.duration(to: current)); last = current; ticks += 1
        }
        await switching.value
        print("DEMO_RESPONSIVENESS ticks=\(ticks) maximum_MainActor_gap=\(maxGap)")
        #expect(mode.enabled && ticks > 3)
        #expect(maxGap < .milliseconds(250))
        await mode.setEnabled(false)
    }
    @Test func enabledRelaunchReopensSameSandboxWithSavedDemoEdits() async throws {
        let (real, directory) = try await empty()
        let url = directory.appendingPathComponent("demo")
        var mode: DeveloperDemoMode? = DeveloperDemoMode(real: real, directory: url)
        await mode!.setEnabled(true)
        let demo = mode!.active
        try await demo.workout!.start(easierToday: false)
        let before = try await demo.repository!.exportBackup()
        await demo.suspendContext(); await demo.repository!.close()
        mode = nil
        let relaunched = DeveloperDemoMode(real: real, directory: url)
        await real.resumeContext()
        await relaunched.load()
        #expect(relaunched.enabled)
        #expect(relaunched.errorText == nil)
        #expect(try await relaunched.active.repository!.exportBackup() == before)
        await relaunched.setEnabled(false)
    }
    @Test func failedSelectionRollsBackAndCanRetryAndBusySwitchIsRejected() async throws {
        let (real, directory) = try await empty()
        let mode = DeveloperDemoMode(real: real, directory: directory.appendingPathComponent("demo"))
        mode.beforePersistForTesting = { throw BackupService.invalid("injected") }
        await mode.setEnabled(true)
        #expect(!mode.enabled && mode.active === real && mode.errorText != nil)
        #expect(!real.busy)
        mode.beforePersistForTesting = nil
        try await real.performContextTransition { await mode.setEnabled(true); #expect(!mode.enabled) }
        await mode.setEnabled(true)
        #expect(mode.enabled && mode.errorText == nil)
        mode.beforePersistForTesting = { throw BackupService.invalid("injected") }
        await mode.setEnabled(false)
        #expect(mode.enabled && mode.active !== real)
        mode.beforePersistForTesting = nil
        await mode.setEnabled(false)
        #expect(!mode.enabled && mode.active === real)
    }
    @Test func demoNeverTouchesCloudProviderOrRealConsentAndStaleCallbackCannotAdopt() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let provider = DemoCountingAccount()
        let transport = DemoCountingTransport()
        let coordinator = CloudSyncCoordinator(repository: s.repository, accountProvider: provider, makeTransport: { transport })
        let preferences = s.storeURL.deletingLastPathComponent().appendingPathComponent("preferences.json")
        let model = WorkoutViewModel(repository: s.repository, snapshot: try await s.repository.snapshot(programID: s.programID), timeZoneID: "Pacific/Honolulu", now: { instant })
        let real = AppComposition(repository: s.repository, workout: model, cloudCoordinator: coordinator, preferencesURL: preferences)
        real.now = { instant }; real.timeZoneID = "Pacific/Honolulu"
        await real.setCloudRecoveryEnabled(true)
        let consent = try Data(contentsOf: preferences)
        let mode = DeveloperDemoMode(real: real, directory: s.storeURL.deletingLastPathComponent().appendingPathComponent("demo"))
        await mode.setEnabled(true)
        let queries = await provider.queries
        let original = try await s.repository.exportBackup()
        await mode.active.setCloudRecoveryEnabled(true)
        await mode.active.retryCloudRecovery()
        await transport.emitRetainedCallback(recoveryScope)
        await real.cloudRecordsChanged(recoveryScope)
        #expect(await provider.queries == queries)
        #expect(await transport.stops > 0)
        #expect(!mode.active.cloudEnabled)
        #expect(try Data(contentsOf: preferences) == consent)
        #expect(try await s.repository.exportBackup() == original)
        await mode.setEnabled(false)
        #expect(real.cloudEnabled)
        #expect(await provider.queries > queries)
        #expect(try Data(contentsOf: preferences) == consent)
    }
}
private actor DemoCountingAccount: CloudAccountProvider {
    var queries = 0
    func currentScope() -> CloudScope? { queries += 1; return recoveryScope }
}
private actor DemoCountingTransport: CloudTransport {
    var stops = 0
    var retainedHandler: (@Sendable (CloudScope) async -> Void)?
    func setUpdateHandler(_ handler: (@Sendable (CloudScope) async -> Void)?) async {
        if let handler { retainedHandler = handler }
    }
    func emitRetainedCallback(_ scope: CloudScope) async { await retainedHandler?(scope) }
    func start(scope: CloudScope) { }
    func stop() { stops += 1 }
    func requestSync() { }
    func syncStatus() -> SyncStatus { .init() }
    func discoverRecoveryCandidates(scope: CloudScope) -> [RecoveryCandidate] { [] }
}

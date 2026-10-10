#if DEBUG
import Foundation
import Observation
import TrainingCore

/// DEBUG-only selector. Each composition owns its repository, preferences, model
/// callbacks and writer lease; the real context is parked without rewriting it.
@MainActor @Observable final class DeveloperDemoMode {
    private struct Selection: Codable {
        var enabled = false
        var explained = false
        var sandbox: String?
    }
    let real: AppComposition
    private(set) var active: AppComposition
    private(set) var enabled = false
    private(set) var switching = false
    private(set) var loaded = false
    private(set) var viewIdentity = UUID()
    var errorText: String?
    private(set) var progressText = "Switching local data…"
    private var selection = Selection()
    private let directory: URL
    // close() releases writer ownership, while SwiftData may retain SQLite
    // handles. Never unlink a directory opened anywhere in this process.
    private static var openedSandboxes: Set<URL> = []
    private var demo: AppComposition?
    var needsExplanation: Bool { !selection.explained }
    // Failure injection occurs before publishing a new context or selection.
    var beforePersistForTesting: (() throws -> Void)?

    init(real: AppComposition = AppComposition(), directory: URL? = nil) {
        self.real = real; active = real
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let synthetic = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        self.directory = directory ?? base.appendingPathComponent(synthetic ? "PlentyStrong-Synthetic-Developer" : "PlentyStrong-Developer", isDirectory: true)
        if synthetic, ProcessInfo.processInfo.arguments.contains("-reset-local-store"), directory == nil {
            try? FileManager.default.removeItem(at: self.directory)
        }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("selection.json")),
           let saved = try? JSONDecoder().decode(Selection.self, from: data) { selection = saved }
    }
    func load() async {
        guard !loaded else { return }; loaded = true
        await cleanUnselectedSandboxes()
        await real.load(installOptionalServices: !selection.enabled)
        if selection.enabled {
            do { try await switchOn(reopening: true) }
            catch {
                errorText = "Demo data could not be opened. Your real data is available. \(error.localizedDescription)"
                selection.enabled = false; try? persist(selection)
            }
        }
    }
    func setEnabled(_ value: Bool) async {
        guard value != enabled, !switching, !active.busy else { return }
        errorText = nil
        do {
            if value { try await switchOn(reopening: false) }
            else { try await switchOff() }
        } catch { errorText = "Could not switch data. Your original data is retained. \(error.localizedDescription)" }
    }
    private func persist(_ value: Selection) throws {
        try beforePersistForTesting?()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("selection.json"), options: .atomic)
    }
    private func sandboxURL(_ name: String) throws -> URL {
        guard UUID(uuidString: name) != nil else { throw BackupService.invalid("demo_directory") }
        return directory.appendingPathComponent(name, isDirectory: true)
    }
    private func cleanUnselectedSandboxes() async {
        let directory = directory
        let retained = selection.sandbox
        let opened = Self.openedSandboxes
        await Task.detached {
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                guard UUID(uuidString: url.lastPathComponent) != nil,
                      url.lastPathComponent != retained, !opened.contains(url) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }
    private func switchOn(reopening: Bool) async throws {
        switching = true; progressText = reopening ? "Opening demo data…" : "Preparing demo data…"
        defer { switching = false }
        do {
            try await real.performContextTransition {
                await real.suspendContext()
                let name = reopening ? selection.sandbox ?? "" : UUID().uuidString
                let sandbox = try sandboxURL(name)
                var repository: TrainingRepository?
                do {
                    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
                    Self.openedSandboxes.insert(sandbox)
                    let opened = try await TrainingRepository.openInBackground(at: sandbox.appendingPathComponent("training.store"))
                    repository = opened
                    let snapshot: StoreSnapshot
                    if reopening {
                        let roots = try await opened.snapshots()
                        guard roots.count == 1, let root = roots.first, root.health == .ready, await Task.detached(operation: { AppTrainingCompatibility.supports(root) }).value else { throw BackupService.invalid("demo_store") }
                        snapshot = root
                    } else {
                        snapshot = try await DeveloperDemoSeed.create(in: opened, at: real.now(), timeZoneID: real.timeZoneID) { [weak self] text in self?.progressText = text }
                    }
                    let model = WorkoutViewModel(repository: opened, snapshot: snapshot, timeZoneID: real.timeZoneID, now: real.now, activatesExactPolicy: true)
                    let candidate = AppComposition(repository: opened, workout: model, tipStore: real.tips)
                    candidate.isDemoContext = true; candidate.now = real.now; candidate.timeZoneID = real.timeZoneID
                    progressText = "Checking demo history…"
                    try await model.prepareToday()
                    var saved = selection; saved.enabled = true; saved.explained = true; saved.sandbox = name
                    try persist(saved)
                    // No throwing work follows the persisted selection. Crash before
                    // adoption reopens this admitted sandbox on the next launch.
                    selection = saved; demo = candidate; active = candidate; enabled = true
                    viewIdentity = UUID()
                } catch {
                    await repository?.close()
                    throw error
                }
            }
        } catch { await real.resumeContext(); throw error }
    }
    private func switchOff() async throws {
        guard let demo else { return }
        switching = true; progressText = "Returning to your data…"
        defer { switching = false }
        try await demo.performContextTransition {
            var saved = selection; saved.enabled = false
            try persist(saved)
            await demo.suspendContext()
            active = real; enabled = false; selection = saved; self.demo = nil
            real.showingWorkout = false; viewIdentity = UUID()
            await demo.repository?.close()
        }
        await real.resumeContext()
    }
}

/// Synthetic deterministic observations. All hashes, targets and transitions
/// are generated/admitted by the registered engine and the sole journal writer.
enum DeveloperDemoSeed {
    static func create(in repository: TrainingRepository, at date: Date, timeZoneID: String,
                       progress: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> StoreSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let today = try CalendarContext(timeZoneID: timeZoneID).localDate(at: date)
            var config = try selectStarterProgram(choice: .upperBody, goal: .size, programID: UUID())
            let pounds: [String: String] = ["incline_db_press_24": "25", "chest_supported_db_row_38_neutral": "30",
                "db_lateral_raise": "10", "lying_db_curls": "15", "suitcase_db_squat": "25",
                "db_romanian_deadlift": "30", "bulgarian_split_squat": "15", "cross_body_hammer_curl": "15", "db_triceps_extension": "15"]
            for movement in config.movements where movement.loadingMode == .externalLoad {
                guard let amount = pounds[movement.id], let load = movement.availableLoads.first(where: { $0.amount == amount }) else { throw BackupService.invalid("demo_load") }
                config.initialLoads[movement.id] = load
            }
            let rules = try RulesetCatalog.starter(.upperBody)
            let programID = UUID(uuidString: config.programID)!
            // Two genuine cadence weeks before the most recent Sunday. The
            // pending SUN is never future-dated, even on an off-cadence day.
            let referenceSunday = try LocalDate(iso8601: "2026-10-04")
            let weekday = ((referenceSunday.days(until: today) % 7) + 7) % 7
            let pendingSunday = try today.adding(days: -weekday)
            let offsets = [-14, -12, -10, -7, -5, -3, 0]
            let slots = ["SUN", "TUE", "THU", "SUN", "TUE", "THU", "SUN"]
            var snapshot = try await repository.initialize(config: config, rules: rules,
                firstWorkout: WorkoutSlot(date: pendingSunday.adding(days: offsets[0]), slotID: slots[0]))
            for index in 0..<6 {
                await progress("Preparing demo workout \(index + 1) of 6…")
                let planned = snapshot.state.activePrescription
                let displayed = try prepareWorkout(state: snapshot.state, rules: rules)
                let logs = try displayed.exercises.map { row -> ExerciseLog in
                    guard let movement = config.movements.first(where: { $0.id == row.baseMovementID }) else { throw BackupService.invalid("demo_movement") }
                    let sets = row.sets.enumerated().map { setIndex, set in
                        let reps = row.phase == .baseline ? 10 : set.targetReps!
                        return ActualSet(reps: reps, leftReps: movement.repCounting == .perSide ? reps : nil,
                            rightReps: movement.repCounting == .perSide ? reps : nil, setIndex: setIndex)
                    }
                    return ExerciseLog(movementID: row.movementID, prescriptionID: displayed.id, status: .completed,
                        actualLoad: row.load, actualSets: sets, finalEffort: .onTarget, problem: .none,
                        baseMovementID: row.baseMovementID, modificationsSnapshot: row.modificationsSnapshot,
                        effortScope: .allWorkingSets, skippedSetIndices: [], mixedLoads: false)
                }
                let event = CompletedWorkout(eventID: UUID().uuidString.lowercased(), date: displayed.date,
                    slotID: displayed.slotID, prescriptionID: displayed.id, plannedPrescriptionID: planned.id,
                    sessionMode: .normal, exercises: logs)
                let receipt = try await repository.finalize(programID: programID, expectedRevision: snapshot.state.revision, event: event,
                    next: WorkoutSlot(date: pendingSunday.adding(days: offsets[index + 1]), slotID: slots[index + 1]))
                guard case .applied = receipt.result else { throw BackupService.invalid("demo_completion") }
                snapshot = receipt.snapshot
            }
            return try await repository.activateFlexibleSchedule(programID: programID, expectedRevision: snapshot.state.revision)
        }.value
    }
}
#endif

import SwiftUI
import TrainingCore

@main struct PlentyStrongApp: App {
    private enum Screen: Hashable { case today, history, settings }
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = Screen.today
    #if DEBUG
    @State private var developerMode = DeveloperDemoMode()
    private var composition: AppComposition { developerMode.active }
    #else
    @State private var composition = AppComposition()
    #endif
    var body: some Scene {
        WindowGroup {
            Group {
                if let error = composition.errorText {
                    ContentUnavailableView("Local training unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let model = composition.workout {
                    TabView(selection: $selectedTab) {
                        Tab("Today", systemImage: "figure.strengthtraining.traditional", value: Screen.today) {
                            NavigationStack {
                                Group {
                                    if composition.showingWorkout { WorkoutView(model: model, close: { composition.showingWorkout = false }) }
                                    else { TodayView(model: model, optionalServicesUnavailable: composition.optionalServicesUnavailable, start: { composition.showingWorkout = true }) }
                                }.navigationTitle("Plenty Strong")
                            }
                        }.accessibilityIdentifier("tab.today")
                        Tab("History", systemImage: "clock", value: Screen.history) {
                            NavigationStack { HistoryView(snapshot: model.snapshot) }
                        }.accessibilityIdentifier("tab.history")
                        Tab("Settings", systemImage: "gearshape", value: Screen.settings) {
                            NavigationStack { SettingsView(composition: composition, model: model) }
                        }.accessibilityIdentifier("tab.settings")
                    }
                } else if let snapshot = composition.readOnlyProgram {
                    NavigationStack { ArchivedProgramView(composition: composition, snapshot: snapshot) }
                } else if composition.loaded, composition.repository != nil {
                    NavigationStack {
                        if !composition.recoveryPrograms.isEmpty { CloudRecoveryView(composition: composition) }
                        else { OnboardingView(composition: composition, operationInProgress: composition.busy, confirm: composition.confirm, restore: { BackupSettingsView(composition: composition) })
                            .navigationTitle("Plenty Strong") }
                    }
                } else { ProgressView("Opening local training…") }
            }
            #if DEBUG
            .id(developerMode.viewIdentity)
            .environment(developerMode)
            .safeAreaInset(edge: .top) {
                if developerMode.enabled {
                    Text("Demo data").font(.caption.bold()).frame(maxWidth: .infinity).padding(6)
                        .background(.yellow.opacity(0.25)).accessibilityIdentifier("developer.demo-banner")
                }
            }
            .overlay {
                if developerMode.switching {
                    ProgressView(developerMode.progressText).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.1))
                        .accessibilityIdentifier("developer.switching")
                }
            }
            .allowsHitTesting(!developerMode.switching)
            .onChange(of: developerMode.viewIdentity) { _, _ in selectedTab = .today }
            #endif
            .modifier(SyntheticAccessibilityOverrides())
            .task {
                #if DEBUG
                await developerMode.load()
                #else
                await composition.load()
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, composition.cloudEnabled { Task { await composition.retryCloudRecovery() } }
                else if phase != .active { Task { await composition.pauseRecoveryForBackground() } }
            }
        }
    }
}
private struct SyntheticAccessibilityOverrides: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ui-testing") {
            content.dynamicTypeSize(args.contains("-ui-large-text") ? .accessibility5 : .large)
                .preferredColorScheme(args.contains("-ui-dark") ? .dark : nil)
        } else { content }
        #else
        content
        #endif
    }
}


private struct ArchivedProgramView: View {
    let composition: AppComposition
    let snapshot: StoreSnapshot
    var body: some View {
        List {
            #if DEBUG
            DeveloperModeSection()
            #endif
            Section("Archived program") {
                Text("Training unavailable for this archived program").font(.headline).accessibilityIdentifier("archive.training-unavailable")
                Text("This valid archived routine is not supported by the fixed trainer. Original history, prescriptions and saved observations remain available for viewing, lossless export and recovery. No training changes have been made.")
                Text("Program: \(snapshot.state.config.programID)").textSelection(.enabled)
                Text("Stored status: \(snapshot.health.rawValue)")
            }
            Section("Stored prescription") {
                ForEach(snapshot.state.activePrescription.exercises, id: \.movementID) { row in
                    Text(snapshot.state.config.movements.first { $0.id == (row.baseMovementID ?? row.movementID) }?.name ?? row.baseMovementID ?? row.movementID)
                    Text("\(row.kind.rawValue) · \(row.sets.count) prescribed sets")
                    if let set = row.sets.first { Text("Stored target: \(set.repFloor)–\(set.repCeiling) reps · \(set.effortInstruction)") }
                    if let load = row.load { Text("Stored load: \(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") }
                }
            }
            if let draft = snapshot.draft {
                Section("Preserved saved observations") {
                    Text("Original workout date: \(draft.date.iso8601). This version cannot continue this archived routine; its saved draft remains in lossless backups.")
                    ForEach(draft.logs, id: \.movementID) { log in
                        Text("\(log.baseMovementID ?? log.movementID): \(log.status.rawValue) · \(log.finalEffort.rawValue) · \(log.problem.rawValue)")
                        Text(WorkoutDetailView.reps(log)).textSelection(.enabled)
                        if let load = log.actualLoad { Text("Recorded load: \(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")") }
                    }
                }
            }
            NavigationLink("View original history") { HistoryView(snapshot: snapshot) }
            NavigationLink("Backup and restore") { BackupSettingsView(composition: composition) }
            NavigationLink("Recovery and saved programs") { CloudRecoveryView(composition: composition) }
        }.navigationTitle("Plenty Strong")
    }
}

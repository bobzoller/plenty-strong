import SwiftUI

/// Optional recovery status never determines healthy offline availability.
struct SettingsView: View {
    let composition: AppComposition
    let model: WorkoutViewModel
    var body: some View {
        List {
            #if DEBUG
            DeveloperModeSection()
            #endif
            if model.snapshot.health != .ready { Text("Local store requires attention: \(model.snapshot.health.rawValue)").accessibilityIdentifier("store.health") }
            NavigationLink("Program and saved setups") { ProgramSettingsView(model: model) }.accessibilityIdentifier("settings.program")
            NavigationLink("Lossless backup and restore") { BackupSettingsView(composition: composition) }.accessibilityIdentifier("settings.backup")
            NavigationLink("iCloud recovery") { CloudRecoveryView(composition: composition) }.accessibilityIdentifier("settings.cloud-recovery")
                #if DEBUG
                .disabled(composition.isDemoContext)
                #endif
            NavigationLink("Optional tips") { TipJarView(store: composition.tips) }.accessibilityIdentifier("settings.tips")
            NavigationLink("About and privacy") { AboutView() }.accessibilityIdentifier("settings.about")
            Section("Optional services") {
                Text(composition.cloudEnabled ? "iCloud recovery is enabled. Review upload and recovery status." : "iCloud recovery is optional. Local workouts and JSON backups are available.").accessibilityIdentifier("settings.cloud-status")
                Text("Tips are voluntary and unlock nothing. All training features are free.").accessibilityIdentifier("settings.tips-status")
            }
        }.navigationTitle("Settings")
    }
}

#if DEBUG
struct DeveloperModeSection: View {
    @Environment(DeveloperDemoMode.self) private var mode
    @State private var confirming = false
    var body: some View {
        Section("Development") {
            Toggle("Developer mode", isOn: Binding(get: { mode.enabled }, set: { enabled in
                if enabled && mode.needsExplanation { confirming = true }
                else { Task { await mode.setEnabled(enabled) } }
            }))
            .disabled(mode.switching || mode.active.busy)
            .accessibilityIdentifier("developer.toggle")
            Text("Use disposable Upper-body / Size demo data. Turn off to return to your original local data. iCloud is unavailable in demo mode.")
                .font(.footnote)
            if let error = mode.errorText { Text(error).foregroundStyle(.red).accessibilityIdentifier("developer.error") }
        }
        .alert("Switch to demo data?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { }
            Button("Use demo data") { Task { await mode.setEnabled(true) } }
        } message: {
            Text("Your data switches temporarily to a separate local sandbox with six synthetic workouts. Your original history, saved workout and preferences remain intact. Turn Developer mode off to return. Each new activation resets the demo data.")
        }
    }
}
#endif

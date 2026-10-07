import SwiftUI

/// Optional recovery status never determines healthy offline availability.
struct SettingsView: View {
    let composition: AppComposition
    let model: WorkoutViewModel
    var body: some View {
        List {
            if model.snapshot.health != .ready { Text("Local store requires attention: \(model.snapshot.health.rawValue)").accessibilityIdentifier("store.health") }
            NavigationLink("Program and saved setups") { ProgramSettingsView(model: model) }.accessibilityIdentifier("settings.program")
            NavigationLink("Lossless backup and restore") { BackupSettingsView(composition: composition) }.accessibilityIdentifier("settings.backup")
            NavigationLink("iCloud recovery") { CloudRecoveryView(composition: composition) }.accessibilityIdentifier("settings.cloud-recovery")
            NavigationLink("Optional tips") { TipJarView(store: composition.tips) }.accessibilityIdentifier("settings.tips")
            NavigationLink("About and privacy") { AboutView() }.accessibilityIdentifier("settings.about")
            Section("Optional services") {
                Text(composition.cloudEnabled ? "iCloud recovery is enabled. Review upload and recovery status." : "iCloud recovery is optional. Local workouts and JSON backups are available.").accessibilityIdentifier("settings.cloud-status")
                Text("Tips are voluntary and unlock nothing. All training features are free.").accessibilityIdentifier("settings.tips-status")
            }
        }.navigationTitle("Settings")
    }
}

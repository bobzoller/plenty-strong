import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    let composition: AppComposition
    @State private var importing = false
    @State private var exportURL: URL?
    @State private var resultText: String?
    @State private var busy = false
    var body: some View {
        List {
            Section("Lossless JSON") {
                Text("Backups retain original workout observations, saved setups, decisions, rule/profile archives and saved drafts. Keep a copy somewhere you control. JSON is the lossless format; CSV and charts are not available in this version.")
                Button("Prepare lossless JSON backup") {
                    busy = true; resultText = nil; exportURL = nil
                    Task {
                        do { exportURL = try await composition.exportBackupFile(); resultText = "Lossless JSON backup prepared on this device." }
                        catch { resultText = "Could not prepare backup. Your stored data is retained. \(error.localizedDescription)" }
                        busy = false
                    }
                }.disabled(busy).accessibilityIdentifier("backup.export")
                if let exportURL { ShareLink("Share JSON backup", item: exportURL).accessibilityIdentifier("backup.share") }
                Text("Sharing is your choice. The chosen destination receives the training data in this file. No account or network is required to prepare a backup.")
            }
            Section("Restore") {
                Text("Choose an original JSON backup. Validation and replay happen before writing. Identical data is not duplicated; incompatible histories are retained for review without replacing your originals.")
                Button("Choose JSON backup to restore") { importing = true }
                    .disabled(busy || composition.busy || composition.workout?.busy == true || composition.workout?.canEditProgramSettings == false).accessibilityIdentifier("backup.import")
                if let model = composition.workout, model.snapshot.health != .ready {
                    Text("Local storage requires review before restoring. Original training data is retained. Status: \(model.snapshot.health.rawValue)").accessibilityIdentifier("backup.health")
                } else if composition.workout?.canEditProgramSettings == false { Text("Return to Today and finish the protected workout safely before restoring.").accessibilityIdentifier("backup.draft-lock") }
            }
            #if DEBUG
            if let url = composition.syntheticBackupURL, FileManager.default.fileExists(atPath: url.path) {
                Section("Synthetic UI-test local file") {
                    Button("Restore synthetic local JSON file") {
                        busy = true
                        Task {
                            do {
                                let receipt = try await composition.restoreBackupData(Data(contentsOf: url))
                                resultText = "Restore verified: \(receipt.accepted) accepted records, \(receipt.identical) already present."
                            } catch { resultText = "Could not restore this backup. Your original data is retained. \(error.localizedDescription)" }
                            busy = false
                        }
                    }.disabled(busy || composition.busy || composition.workout?.busy == true || composition.workout?.canEditProgramSettings == false).accessibilityIdentifier("backup.restore-synthetic-file")
                }
            }
            #endif
        }.navigationTitle("Backup and restore")
        .safeAreaInset(edge: .bottom) {
            if let resultText { Text(resultText).padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial).accessibilityIdentifier("backup.result").textSelection(.enabled) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                busy = true; resultText = nil
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() }; busy = false }
                    do {
                        let receipt = try await composition.restoreBackupData(Data(contentsOf: url))
                        resultText = receipt.conflicted > 0 ? "Incompatible backup retained for review. Original training data is unchanged." : "Restore verified: \(receipt.accepted) accepted records, \(receipt.identical) already present."
                    } catch { resultText = "Could not restore this backup. Your original data is retained. \(error.localizedDescription)" }
                }
            case let .failure(error): resultText = "Could not open the selected file. Your original data is retained. \(error.localizedDescription)"
            }
        }
    }
}

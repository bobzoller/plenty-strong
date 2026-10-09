import SwiftUI
import TrainingCore

struct CloudRecoveryView: View {
    let composition: AppComposition
    @State private var exportURL: URL?
    @State private var stagedExportURL: URL?
    @State private var message: String?
    @State private var creating = false
    @State private var newGoal: Goal?
    @State private var newChoice: StarterProgramChoice?
    var body: some View {
        List {
            Section("Optional iCloud recovery") {
                Text("Training works without iCloud. Recovery uses your private iCloud storage and requires the same Apple account, app container and environment, plus successful uploads.")
                Text("Unfinished workouts remain on this phone and are not recovered through iCloud.").accessibilityIdentifier("sync.draft-disclosure")
                Button(composition.cloudEnabled ? "Turn off recovery" : "Enable iCloud recovery") {
                    Task { await composition.setCloudRecoveryEnabled(!composition.cloudEnabled) }
                }.accessibilityIdentifier(composition.cloudEnabled ? "sync.disable" : "sync.enable")
                Text("This preference is separate from the iCloud switch for this app in iOS Settings. Turning recovery off preserves local history and pending uploads.")
            }
            Section("Recovery status") {
                status
                let count = composition.cloudStatus.pendingCompletedWorkoutCount
                Text(count == 1 ? "1 completed workout waiting to upload" : "\(count) completed workouts waiting to upload").accessibilityIdentifier("sync.pending-count")
                Text("\(composition.cloudStatus.pendingRecordCount) recovery records waiting; \(composition.cloudStatus.acknowledgedCompletedWorkoutCount) completed workouts have all required recovery data available.")
                if let date = composition.cloudStatus.lastRecordAcknowledgement {
                    Text("Last record acknowledgement: \(date.formatted())").accessibilityIdentifier("sync.last-acknowledgement")
                }
                if let reason = composition.cloudStatus.retryReason { Text(reason).accessibilityIdentifier(composition.cloudStatus.phase == .accountUnavailable ? "sync.account-unavailable" : "sync.retry-reason") }
                if composition.cloudEnabled {
                    Button("Associate selected program with current iCloud account") { Task { await composition.associateSelectedProgram() } }.accessibilityIdentifier("sync.associate")
                    Button("Discover and retry recovery") { Task { await composition.retryCloudRecovery() } }.accessibilityIdentifier("sync.retry") }
            }
            Section("Keep a copy you control") {
                Button("Prepare lossless JSON backup") {
                    Task { do { exportURL = try await composition.exportBackupFile() } catch { message = error.localizedDescription } }
                }.accessibilityIdentifier("sync.export")
                if let exportURL { ShareLink("Share JSON backup", item: exportURL).accessibilityIdentifier("sync.share") }
                Text("The export preserves saved program history, adopted branches, invalid originals retained in training history, and local drafts. Incoming data awaiting safe adoption remains in this phone’s recovery metadata. Sharing sends training data to your chosen destination.")
            }
            Section("Preserve incoming originals awaiting adoption") {
                Text("This separate evidence file retains exact incoming originals waiting behind a saved workout. It excludes account and engine metadata. It is not an ordinary restorable training backup.")
                Button("Prepare staged originals JSON") {
                    Task { do { stagedExportURL = try await composition.exportStagedOriginalsFile(); message = "Staged originals evidence prepared. This is not an ordinary restorable training backup." } catch { message = error.localizedDescription } }
                }.accessibilityIdentifier("sync.export-staged")
                if let stagedExportURL { ShareLink("Share staged originals evidence", item: stagedExportURL).accessibilityIdentifier("sync.share-staged") }
            }
            if !composition.recoveryPrograms.isEmpty {
                Section("Choose a saved program") {
                    Text("Choose explicitly when several programs are available. Other programs and their original observations remain available here and in exports.")
                    ForEach(composition.recoveryPrograms, id: \.programID) { program in
                        NavigationLink("Program \(program.programID.prefix(8)) · \(program.knownCompletedWorkoutCount) completed workouts · \(program.health.rawValue)") {
                            RecoveryProgramView(composition: composition, program: program)
                        }.accessibilityIdentifier("sync.program.\(program.programID)")
                    }
                }
            }
            if !composition.discoveryCandidates.isEmpty {
                Section("Discovered recovery data") {
                    Text("Discovery does not select a program or promise a complete restore. Missing or unsupported data cannot start progression.")
                    ForEach(composition.discoveryCandidates, id: \.datasetID) { item in
                        Text("Program \(item.programID.uuidString.prefix(8)) · \(item.knownCompletedWorkoutCount) known workouts · \(item.status.rawValue)")
                    }
                }
            }
            if composition.cloudEnabled {
                Section("Use a different iCloud account") {
                    Text("Old local history remains available for viewing and export. Create a separate program for the current account; this does not transfer old history.")
                    Text("This version cannot create a separate program while retained programs need recovery review, contain a saved workout, or have safety restrictions beyond the new defaults.")
                    ProgramChoiceView(selection: $newChoice, identifierPrefix: "sync.new-program")
                    Picker("New program goal", selection: $newGoal) {
                        Text("Choose a goal").tag(Optional<Goal>.none)
                        ForEach(Goal.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    if let choice = newChoice, let goal = newGoal {
                        NavigationLink("Preview this program") { ProgramPreviewView(choice: choice, goal: goal) }
                    }
                    Button("Create separate program for current account") { creating = true }
                        .disabled(newChoice == nil || newGoal == nil || composition.busy || composition.workout?.snapshot.draft != nil || composition.workout?.hasAmbiguousFinish == true)
                        .accessibilityIdentifier("sync.new-account-program")
                }
            }
            if let message { Text(message).accessibilityIdentifier("sync.result") }
            if let message = composition.recoveryMessage { Text(message) }
        }.navigationTitle("iCloud recovery")
        .task { try? await composition.refreshRecoveryPrograms() }
        .confirmationDialog("Create a separate program? All existing history stays on this phone and retains its original iCloud association.", isPresented: $creating) {
            Button("Create separate program") { guard let newChoice, let newGoal else { return }; Task { do { try await composition.createSeparateCloudProgram(choice: newChoice, goal: newGoal) } catch { message = error.localizedDescription } } }
        }
    }
    @ViewBuilder private var status: some View {
        switch composition.cloudStatus.phase {
        case .localOnly: Text("Recovery is off. Training is saved locally.")
        case .accountUnavailable: Text("Recovery unavailable")
        case .sending: Text("Uploading recovery data…")
        case .pending: Text("Recovery uploads pending")
        case .incomplete:
            Text("Recovery incomplete").accessibilityIdentifier("sync.incomplete")
            Text("Imported histories require verified recovery records in the current account; association alone does not upload them.")
        case .conflict: Text("Recovery conflict needs review").accessibilityIdentifier("sync.conflict")
        case .upToDateForKnownRecords:
            if composition.cloudStatus.lastRecordAcknowledgement != nil, composition.cloudStatus.pendingRecordCount == 0, composition.cloudStatus.pendingCompletedWorkoutCount == 0 {
                Text("All known completed workouts uploaded").accessibilityIdentifier("sync.all-uploaded")
                Text("This describes acknowledged data, not a promise of future availability or recovery of unfinished workouts.")
            } else { Text("No uploads acknowledged on this phone. Recovered data has been checked locally.") }
        }
    }
}

private struct RecoveryProgramView: View {
    let composition: AppComposition
    let program: RecoveryProgramSummary
    @State private var snapshot: StoreSnapshot?
    @State private var message: String?
    var body: some View {
        List {
            Text("Program identity: \(program.programID)").textSelection(.enabled)
            Text("Status: \(program.health.rawValue)")
            if let snapshot {
                Text("Stored goal: \(snapshot.state.config.goal.title)")
                NavigationLink("View original local history") { HistoryView(snapshot: snapshot) }.accessibilityIdentifier("sync.old-history")
                Button("Use this program on this phone") { Task { do { try await composition.selectRecoveryProgram(program.programID); message = "Program selected. Every other program is retained." } catch { message = error.localizedDescription } } }
                    .disabled(composition.busy || (composition.workout?.snapshot.draft != nil && composition.workout?.snapshot.state.config.programID != program.programID))
                    .accessibilityIdentifier("sync.select-program")
            }
            if !program.headHashes.isEmpty {
                NavigationLink("Compare retained branches and safety") { ConflictResolutionView(composition: composition, programID: program.programID) }.accessibilityIdentifier("sync.compare-branches")
            } else { Text("Missing verified data. This program cannot be selected yet.") }
            if let message { Text(message) }
        }.navigationTitle("Saved program")
        .task { if let id = UUID(uuidString: program.programID), let repository = composition.repository { snapshot = try? await repository.snapshot(programID: id) } }
    }
}

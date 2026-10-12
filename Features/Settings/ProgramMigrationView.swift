import SwiftUI
import UniformTypeIdentifiers
import TrainingCore

struct ProgramMigrationView: View {
    let composition: AppComposition
    @State private var choosingFile = false
    @State private var document: ProgramMigrationDocument?
    @State private var goal: Goal?
    @State private var confirmedLoads: [String: Load] = [:]
    @State private var acknowledgement = false
    @State private var preview: MigrationPreviewReceipt?
    @State private var receipt: MigrationImportReceipt?
    @State private var busy = false
    @State private var message: String?
    private var selection: MigrationSelection? {
        guard let goal, acknowledgement, let document,
              document.checkpoint.baselines.filter({ $0.unresolvedLoadAmount != nil }).allSatisfy({ confirmedLoads[$0.baseMovementID] != nil }) else { return nil }
        return MigrationSelection(goal: goal, acceptedNativePolicy: acknowledgement, confirmedLoads: confirmedLoads)
    }
    var body: some View {
        Form {
            Section("Import your existing program") {
                Text("Import the original program, established targets, source history and safeguards into a new local program. Your other programs remain available in backup and recovery.")
                Button("Choose program migration JSON") { choosingFile = true }
                    .disabled(busy || composition.busy).accessibilityIdentifier("migration.choose-file")
                #if DEBUG
                if let url = composition.syntheticMigrationURL {
                    Button("Open synthetic migration file") { Task { await open(url) } }
                        .disabled(busy || composition.busy).accessibilityIdentifier("migration.synthetic-file")
                }
                #endif
            }
            if let document {
                Section("Source originals") {
                    Text("\(document.source.workouts.count) source dates · \(document.source.workouts.reduce(0) { $0 + $1.rows.count }) exercise rows")
                        .accessibilityIdentifier("migration.source-counts")
                    NavigationLink("Review original history and source metadata") { ExternalSourceArchiveView(source: document.source) }
                    Text("Source observations stay labeled as external history. Missing effort, timing, outcomes and load basis remain unrecorded.")
                }
                Section("Choose your future goal") {
                    ForEach(Goal.allCases, id: \.self) { value in
                        Button { goal = value; invalidate() } label: {
                            HStack { Text(value.title); Spacer(); if goal == value { Image(systemName: "checkmark") } }
                        }.accessibilityIdentifier("migration.goal.\(value.rawValue)")
                            .disabled(busy || receipt != nil)
                    }
                    Text("The original calendar and phase label do not select your goal.")
                }
                if document.checkpoint.baselines.contains(where: { $0.unresolvedLoadAmount != nil }) {
                    Section("Confirm future load basis") {
                        ForEach(document.checkpoint.baselines.filter { $0.unresolvedLoadAmount != nil }, id: \.baseMovementID) { baseline in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(baseline.baseMovementID.replacingOccurrences(of: "_", with: " ")).font(.headline)
                                Text("Source current load: \(baseline.unresolvedLoadAmount ?? "unrecorded"). Historical load basis remains unknown. This confirmation applies only to future sessions.")
                                ForEach(Array(supportedLoads(baseline).enumerated()), id: \.offset) { _, load in
                                    Button("Confirm \(MigrationPresentation.load(load)) for future sessions") {
                                        confirmedLoads[baseline.baseMovementID] = load
                                        invalidate()
                                    }.accessibilityIdentifier("migration.basis.\(baseline.baseMovementID)")
                                        .disabled(busy || receipt != nil)
                                }
                                if let load = confirmedLoads[baseline.baseMovementID] { Text("Future basis selected: \(MigrationPresentation.load(load))").font(.caption) }
                                Text("Only the fixed setup's supported amount and basis can continue. Choose a goal first. If this interpretation is incorrect, leave it unresolved and review the source.").font(.caption)
                            }
                        }
                    }
                }
                Section("Plenty rules after cutover") {
                    Text("Current set counts, targets, loads and saved setups carry forward. Future progression uses Plenty's exact-rep rules, all-set effort reserve, and 2 minutes between sets / 3 minutes between movements. Source calibration and qualifying counters reset; old calendar and mesocycle decisions stay archived and no longer drive training.")
                    Text("Stricter source safeguards remain. Unknown recovery stays unknown; import does not confirm clearance to resume training.")
                    Toggle("I reviewed these changes and retained safeguards", isOn: Binding(get: { acknowledgement }, set: { acknowledgement = $0; invalidate() }))
                        .disabled(busy || receipt != nil).accessibilityIdentifier("migration.acknowledge")
                    Button("Review native preview") {
                        guard let selection else { return }
                        busy = true; message = nil
                        Task {
                            do { preview = try await composition.previewMigration(document: document, selection: selection) }
                            catch { message = "Could not preview. Original data is retained. \(error.localizedDescription)" }
                            busy = false
                        }
                    }.disabled(selection == nil || busy || composition.busy || receipt != nil || composition.workout?.canEditProgramSettings == false).accessibilityIdentifier("migration.preview")
                }
                if let preview {
                    if preview.existingRootHash != nil { Text("This exact migration is already retained. The current pending workout is shown; importing again preserves its original clock and native progress.") }
                    Section("First pending workout") {
                        Text("\(preview.state.activePrescription.date.iso8601) · \(preview.state.activePrescription.slotID)")
                        ForEach(preview.state.activePrescription.exercises, id: \.movementID) { row in
                            VStack(alignment: .leading) {
                                Text(preview.state.config.movements.first { $0.id == row.baseMovementID }?.name ?? row.baseMovementID ?? row.movementID)
                                Text("\(row.sets.compactMap(\.targetReps).map(String.init).joined(separator: "/")) · \(MigrationPresentation.load(row.load))").font(.caption)
                                Text("\(row.restSeconds) seconds rest · \(row.stopInstruction)").font(.caption)
                            }
                        }
                        Text("Actual reps remain blank until you record a native workout.")
                    }.accessibilityIdentifier("migration.pending")
                    Section("All current targets and range mapping") {
                        ForEach(document.checkpoint.baselines, id: \.variantID) { baseline in
                            if let state = preview.state.exercises[baseline.variantID] {
                                VStack(alignment: .leading) {
                                    Text(preview.state.config.movements.first { $0.id == baseline.baseMovementID }?.name ?? baseline.baseMovementID)
                                    Text("\(state.normalSets) sets · \(state.exactRepState?.normalTargets.map(String.init).joined(separator: "/") ?? "unrecorded") · \(MigrationPresentation.load(state.load))").font(.caption)
                                    Text("Source range \(baseline.sourceRepFloor)–\(baseline.sourceRepCeiling); native range \(state.repFloor)–\(state.repCeiling). Minimum \(baseline.minimumRir) good reps left.").font(.caption)
                                    Text(baseline.modifications).font(.caption)
                                    Text("Recovery: \(baseline.recoveryStatus). \(baseline.recoveryRequired ? "Review recovery before each native exposure." : "") \(baseline.safetyText)").font(.caption)
                                    if baseline.paused || baseline.reviewRequired { Text("Source protection retained; review required.").foregroundStyle(.orange) }
                                }
                            }
                        }
                        ForEach(Array(preview.preview.differences.enumerated()), id: \.offset) { _, value in Text(value).font(.caption) }
                    }
                    if receipt == nil {
                        Button("Import as a new local program") {
                            guard let selection else { return }
                            busy = true
                            Task {
                                do {
                                    receipt = try await composition.importMigration(document: document, selection: selection, preview: preview)
                                    message = "Program imported. Select Use migrated program to adopt it. Other programs remain retained."
                                } catch { message = "Import stopped; original data is retained. Review a fresh preview. \(error.localizedDescription)"; self.preview = nil }
                                busy = false
                            }
                        }.disabled(busy || composition.busy || composition.workout?.canEditProgramSettings == false).accessibilityIdentifier("migration.import")
                    }
                }
                if let receipt {
                    Button("Use migrated program") {
                        busy = true
                        Task {
                            do { try await composition.adoptMigration(receipt); message = "Migrated program selected. Native workouts begin at cutover." }
                            catch { message = "Imported program is retained; selection could not change. \(error.localizedDescription)" }
                            busy = false
                        }
                    }.disabled(busy || composition.busy || composition.workout?.canEditProgramSettings == false).accessibilityIdentifier("migration.adopt")
                }
            }
            if composition.workout?.canEditProgramSettings == false {
                Text("A saved workout or Finish retry is protected. Finish it safely before importing or selecting a new program.").accessibilityIdentifier("migration.draft-lock")
            }
            if let message { Text(message).textSelection(.enabled).accessibilityIdentifier("migration.result") }
        }.navigationTitle("Import program")
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
                switch result {
                case let .success(url): Task { await open(url) }
                case let .failure(error): message = "Could not open file. \(error.localizedDescription)"
                }
            }
    }
    private func supportedLoads(_ baseline: MigrationBaseline) -> [Load] {
        guard let goal, let amount = baseline.unresolvedLoadAmount,
              let config = try? selectFixedProgram(goal: goal, programID: UUID()),
              let movement = config.movements.first(where: { $0.id == baseline.baseMovementID }) else { return [] }
        return movement.availableLoads.filter { $0.amount == amount }
    }
    private func invalidate() { preview = nil; receipt = nil; message = nil }
    @MainActor private func open(_ url: URL) async {
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; busy = false }
        do {
            let loaded = try await composition.decodeMigrationData(Data(contentsOf: url))
            document = loaded; goal = nil; confirmedLoads = [:]; acknowledgement = false; invalidate()
        } catch { message = "Could not validate this program file. Original data is retained. \(error.localizedDescription)" }
    }
}

enum MigrationPresentation {
    static func load(_ load: Load?) -> String {
        guard let load else { return "Bodyweight or manual assistance; no external load" }
        return "\(load.amount) \(load.unit.rawValue) \(load.basis == .perImplement ? "per hand" : "total")"
    }
    static func raw(_ value: CanonicalValue) -> String {
        if case .null = value { return "Unrecorded (source null)" }
        if case .string(let token) = value { return token.isEmpty ? "Unrecorded (source blank)" : token }
        return (try? String(decoding: CanonicalJSON.encode(value), as: UTF8.self)) ?? "Unreadable original field"
    }
}

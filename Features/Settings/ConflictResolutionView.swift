import SwiftUI
import TrainingCore

struct ConflictResolutionView: View {
    let composition: AppComposition
    let programID: String
    @State private var proof: VerifiedCloudBatch?
    @State private var selectedHead: String?
    @State private var definitionChoices: [String: String] = [:]
    @State private var reviewed = Set<String>()
    @State private var requiredChecksums = Set<String>()
    @State private var confirmSelection = false
    @State private var message: String?
    private var heads: [String] { proof?.heads[programID] ?? [] }
    private var mixedPolicyConflict: Bool {
        guard let proof else { return false }
        return (try? RecoveryVerifier.hasMixedPolicyConflict(programID: programID, envelopes: proof.envelopes, heads: heads)) != false
    }
    var body: some View {
        List {
            if mixedPolicyConflict {
                Section { Text("Workouts use different prescription versions. Your records are preserved; resolve this version conflict before continuing.").accessibilityIdentifier("sync.mixed-policy-conflict")
                    NavigationLink("Export all preserved records") { BackupSettingsView(composition: composition) }
                }
            }
            Section("Compare before choosing") {
                Text("All original actuals, decisions and rules stay stored. Choose one whole progression and configuration path. Pain and control restrictions from every verified branch survive; choosing a branch cannot clear a pause. All unpaused setups require a new baseline.").accessibilityIdentifier("sync.safety-union")
                ForEach(heads, id: \.self) { hash in
                    if let envelope = proof?.envelopes[hash] {
                        NavigationLink("Branch \(hash.prefix(8)) · \(envelope.returnedState.config.goal.title) · revision \(envelope.returnedState.revision)") {
                            BranchComparisonView(proof: proof!, head: hash)
                        }.accessibilityIdentifier("sync.branch-details.\(hash)")
                        Button(selectedHead == hash ? "Selected path \(hash.prefix(8))" : "Choose path and configuration \(hash.prefix(8))") { selectedHead = hash; definitionChoices = [:] }.disabled(mixedPolicyConflict).accessibilityIdentifier("sync.choose-branch.\(hash)")
                    }
                }
            }
            if let proof {
                ForEach(conflictingVariantIDs(proof), id: \.self) { id in
                    Section("Conflicting saved setup · \(id)") {
                        Text("Choose the original definition to retain for this identity. The selected active configuration must remain compatible.")
                        ForEach(heads, id: \.self) { head in
                            if let variant = proof.envelopes[head]?.returnedState.config.variants?[id] {
                                Button("\(variant.modifications) · source \(head.prefix(8))\(definitionChoices[id] == head ? " · chosen" : "")") { definitionChoices[id] = head }
                            }
                        }
                    }
                }
                Section("Invalid originals remain retained") {
                    ForEach(requiredChecksums.sorted(), id: \.self) { hash in
                        Text("Invalid original checksum: \(hash)").textSelection(.enabled)
                        if let original = proof.quarantined.first(where: { BackupService.hash($0.record.bytes) == hash }) {
                            NavigationLink("View retained invalid original · \(original.reason)") { ScrollView { Text(String(data: original.record.bytes, encoding: .utf8) ?? original.record.bytes.map { String(format: "%02x", $0) }.joined()).font(.caption.monospaced()).textSelection(.enabled).padding() } }
                        }
                        Toggle("I reviewed this retained invalid original; it will not become accepted history", isOn: Binding(get: { reviewed.contains(hash) }, set: { if $0 { reviewed.insert(hash) } else { reviewed.remove(hash) } }))
                    }
                    Text("Unknown schema, command or rules versions cannot be waived. Export keeps the exact invalid bytes for review.")
                }
            }
            Button("Confirm selected progression and configuration") { confirmSelection = true }
                .disabled(mixedPolicyConflict || selectedHead == nil || reviewed != requiredChecksums || composition.busy || composition.workout?.snapshot.draft != nil || proof?.quarantined.contains(where: { $0.programID == programID && $0.reason == "unsupported_version" }) == true)
                .accessibilityIdentifier("sync.resolve-conflict")
            if let message { Text(message).accessibilityIdentifier("sync.resolution-result") }
        }.navigationTitle("Recovery branch review")
        .task {
            do {
                proof = try await composition.recoveryProof()
                if let repository = composition.repository {
                    let resolved = Set(try await repository.exportBackup().recovery?.resolvedQuarantineKeys ?? [])
                    requiredChecksums = Set(proof!.quarantined.filter { $0.programID == programID }.map { BackupService.hash($0.record.bytes) }).subtracting(resolved)
                }
            } catch { message = "Recovery data cannot yet be compared safely. Originals are retained." }
        }
        .confirmationDialog("Keep every original and select this entire path? Safety pauses remain in effect.", isPresented: $confirmSelection) {
            Button("Preserve originals and select path") {
                guard let selectedHead else { return }
                let selection = BranchSelection(selectedHeadHash: selectedHead, configurationHeadHash: selectedHead, variantDefinitionHeadHashes: definitionChoices, reviewedQuarantineChecksums: reviewed.sorted())
                let exactHeads = heads
                Task {
                    do { try await composition.resolveRecoveryConflict(programID: programID, heads: exactHeads, selection: selection); message = "Selection saved. Original actuals and safety restrictions are retained."; proof = try await composition.recoveryProof() }
                    catch { message = "Selection could not be saved. Data may have changed or needs further review. All originals are retained." }
                }
            }
        }
    }
    private func conflictingVariantIDs(_ proof: VerifiedCloudBatch) -> [String] {
        let variants = heads.compactMap { proof.envelopes[$0]?.returnedState.config.variants }
        return Set(variants.flatMap { $0.keys }).filter { id in
            Set(variants.compactMap { $0[id] }.compactMap { try? BackupService.bytes($0) }).count > 1
        }.sorted()
    }
}
private struct BranchComparisonView: View {
    let proof: VerifiedCloudBatch
    let head: String
    private var path: [JournalEnvelope] {
        let hashes = (try? RecoveryVerifier.ancestors(head, envelopes: proof.envelopes)) ?? []
        return hashes.compactMap { proof.envelopes[$0] }.sorted { ($0.returnedState.revision, $0.envelopeHash) < ($1.returnedState.revision, $1.envelopeHash) }
    }
    private func workoutEvent(_ envelope: JournalEnvelope) -> CompletedWorkout? {
        switch envelope.command { case let .workout(event, _): return event; default: return nil }
    }
    var body: some View {
        List {
            if let envelope = proof.envelopes[head] {
                Section("Stored configuration and safety") {
                    Text("Goal: \(envelope.returnedState.config.goal.title)")
                    Text("Original rules: \(envelope.rulesetHash)").textSelection(.enabled)
                    ForEach(envelope.returnedState.config.movements, id: \.id) { movement in
                        Text("\(movement.name ?? movement.id): \(envelope.returnedState.baseSafety?[movement.id]?.paused == true || envelope.returnedState.exercises[movement.id]?.mode == .paused ? "Paused" : "No stored pause") · minimum \(String(envelope.returnedState.baseSafety?[movement.id]?.minimumRir ?? movement.minimumRir)) RIR")
                    }
                    // Full immutable values remain inspectable, including opaque setups,
                    // loads, prescriptions, schedules and restrictions beyond summaries.
                    NavigationLink("View complete stored configuration, prescription and state") {
                        ScrollView { Text(String(data: (try? JSONEncoder.pretty.encode(envelope.returnedState)) ?? Data(), encoding: .utf8) ?? "Unavailable").font(.caption.monospaced()).textSelection(.enabled).padding() }
                    }
                }
            }
            Section("Every original workout and decision on this path") {
                ForEach(path, id: \.envelopeHash) { envelope in
                    if let event = workoutEvent(envelope) {
                        NavigationLink("\(event.date.iso8601) · \(WorkoutDetailView.coverage(event))") { WorkoutDetailView(envelope: envelope, variantID: nil) }
                    } else {
                        Text("Stored revision \(envelope.returnedState.revision)")
                        ForEach(Array(envelope.decisions.enumerated()), id: \.offset) { _, decision in
                            NavigationLink(DecisionExplanationView.copy(for: decision.explanationKey)) { DecisionExplanationView(decision: decision) }
                        }
                    }
                }
            }
        }.navigationTitle("Original branch")
    }
}
private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}

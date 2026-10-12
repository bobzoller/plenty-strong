import SwiftUI
import TrainingCore

/// Reads the immutable journal, never the resettable comparison window.
struct HistoryView: View {
    let snapshot: StoreSnapshot
    private var workouts: [JournalEnvelope] { snapshot.history.filter { if case .workout = $0.command { return true }; return false }.reversed() }
    private struct Entry: Identifiable {
        let id: String
        let date: String
        let native: JournalEnvelope?
        let external: ExternalWorkoutObservation?
    }
    private var entries: [Entry] {
        let native = workouts.compactMap { envelope -> Entry? in
            guard case let .workout(event, _) = envelope.command else { return nil }
            return Entry(id: "native:" + envelope.eventID, date: event.date.iso8601, native: envelope, external: nil)
        }
        let external = (snapshot.externalSource?.workouts ?? []).map { Entry(id: "source:" + $0.sourceKey, date: $0.date.iso8601, native: nil, external: $0) }
        return (native + external).sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }
    var body: some View {
        List {
            if snapshot.health != .ready { Text("Local store requires attention: \(snapshot.health.rawValue)").accessibilityIdentifier("history.health") }
            if snapshot.health == .mixedPolicyConflict { Text("All original legacy and exact-policy branches are retained. Work is blocked until cross-policy conflict resolution is available; no branch is selected or discarded automatically.") }
            Section("Workouts") {
                if entries.isEmpty { Text("Your recorded workouts will appear here.") }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if let envelope = entry.native, case let .workout(event, _) = envelope.command {
                        NavigationLink { WorkoutDetailView(envelope: envelope, variantID: nil, history: snapshot.history) } label: {
                            VStack(alignment: .leading) {
                                Text(event.date.iso8601)
                                if let planned = event.timing?.plannedDate, planned != event.date { Text("Originally planned: \(planned.iso8601)").font(.caption) }
                                Text(event.sessionMode == .easier ? "Easier workout" : "Recorded workout").font(.caption)
                            }
                        }.accessibilityIdentifier(index == 0 ? "history.first-workout" : "history.workout.\(envelope.eventID)")
                    } else if let external = entry.external {
                        NavigationLink { ExternalWorkoutDetailView(workout: external) } label: {
                            VStack(alignment: .leading) {
                                Text(external.date.iso8601)
                                Text("External source · \(external.rows.count) exercise rows").font(.caption)
                            }
                        }.accessibilityIdentifier("history.source.\(external.sourceKey)")
                    }
                }
            }
            if let source = snapshot.externalSource {
                Section("Original source") { NavigationLink("Source history, decisions and exact original files") { ExternalSourceArchiveView(source: source) } }
            }
            Section("Movement and saved setup histories") {
                ForEach(snapshot.state.config.movements, id: \.id) { movement in
                    DisclosureGroup(movement.name ?? movement.id) {
                        let variants = (snapshot.state.config.variants ?? [:]).values.filter { $0.baseMovementID == movement.id }.sorted { $0.id < $1.id }
                        ForEach(variants, id: \.id) { variant in
                            DisclosureGroup(variant.modifications.isEmpty ? "Default setup" : variant.modifications) {
                                Text("Setup identity: \(variant.id)").font(.caption).textSelection(.enabled)
                                let records = workouts.filter { if case let .workout(event, _) = $0.command { return event.exercises.contains { $0.movementID == variant.id } }; return false }
                                if records.isEmpty { Text("No recorded work for this setup.") }
                                ForEach(records, id: \.eventID) { envelope in
                                    if case let .workout(event, _) = envelope.command {
                                        NavigationLink(event.date.iso8601) { WorkoutDetailView(envelope: envelope, variantID: variant.id, history: snapshot.history) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("History")
    }
}

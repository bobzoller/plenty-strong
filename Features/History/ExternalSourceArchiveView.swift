import SwiftUI
import TrainingCore

struct ExternalWorkoutDetailView: View {
    let workout: ExternalWorkoutObservation
    var body: some View {
        List {
            Section("External source history") {
                Text(workout.date.iso8601)
                Text("Recorded in the source program. A source date is retained without inventing session timing, native prescriptions, effort or outcomes.")
                Text("Source identity: \(workout.sourceKey)").font(.caption).textSelection(.enabled)
            }
            ForEach(workout.rows, id: \.sourceKey) { row in
                Section(row.movementLabel) {
                    Text("Source row: \(row.sourceKey)").font(.caption).textSelection(.enabled)
                    ForEach(row.raw.keys.sorted(), id: \.self) { field in
                        VStack(alignment: .leading) {
                            Text(field).font(.caption).foregroundStyle(.secondary)
                            Text(MigrationPresentation.raw(row.raw[field]!)).textSelection(.enabled)
                        }
                    }
                }
            }
        }.navigationTitle("Source workout").accessibilityIdentifier("history.source-detail")
    }
}
struct ExternalSourceArchiveView: View {
    let source: ExternalSourceArchive
    @State private var exportURLs: [String: URL] = [:]
    @State private var error: String?
    var body: some View {
        List {
            Section("Original external program") {
                Text("\(source.workouts.count) source dates · \(source.workouts.reduce(0) { $0 + $1.rows.count }) exercise rows")
                Text("Original bytes, notes, no-exercise records and prior calendar/calibration decisions remain portable. Typed observations keep ambiguous and missing tokens as recorded.")
                Text("Archive: \(source.contentHash)").font(.caption).textSelection(.enabled)
            }
            Section("Source history") {
                ForEach(source.workouts.sorted { ($0.date.iso8601, $0.sourceKey) > ($1.date.iso8601, $1.sourceKey) }, id: \.sourceKey) { workout in
                    NavigationLink("\(workout.date.iso8601) · \(workout.rows.count) source exercise rows") { ExternalWorkoutDetailView(workout: workout) }
                }
            }
            Section("Source state and decisions") {
                ForEach(source.sourceState.keys.sorted(), id: \.self) { key in
                    DisclosureGroup(key) { Text(MigrationPresentation.raw(source.sourceState[key]!)).textSelection(.enabled) }
                }
            }
            Section("Exact original files") {
                ForEach(source.files, id: \.name) { file in
                    VStack(alignment: .leading) {
                        Text(file.name)
                        Text("\(file.bytes.count) bytes · SHA256 \(file.sha256)").font(.caption).textSelection(.enabled)
                        if let url = exportURLs[file.name] { ShareLink("Share original file", item: url) }
                        else {
                            Button("Prepare original file") {
                                do {
                                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PlentyStrong-Source-" + UUID().uuidString, isDirectory: true)
                                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                                    // Archive names are descriptive, never path authority.
                                    let basename = URL(fileURLWithPath: file.name).lastPathComponent
                                    guard !["", ".", "..", "/"].contains(basename) else { throw BackupService.invalid("source_export_file_name") }
                                    let url = directory.appendingPathComponent(basename)
                                    try file.bytes.write(to: url, options: .atomic)
                                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                                    exportURLs[file.name] = url
                                } catch { self.error = "Could not prepare original file. Stored bytes are retained. \(error.localizedDescription)" }
                            }
                        }
                    }
                }
                Text("Sharing sends the selected original training data to your chosen destination.").font(.footnote)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Source originals")
    }
}

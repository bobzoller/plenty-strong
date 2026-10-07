import Darwin
import Foundation
import TrainingCore
import SwiftData

enum TrainingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TrainingSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
    /// Opening is fail-closed. Never remove or recreate an existing unreadable store.
    static func open(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TrainingSchemaV1.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: self, configurations: [config])
    }
}

/// Cross-process lease prohibits a second writer, including another actor/container.
/// The lock file carries no training data and is never an authoritative store.
final class StoreLease: @unchecked Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        descriptor = Darwin.open(url.path + ".writer-lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw TrainingCore.EngineError(code: "writer_already_open", field: "store")
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

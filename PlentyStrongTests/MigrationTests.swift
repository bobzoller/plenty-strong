import Foundation
import Testing
@testable import PlentyStrong
struct MigrationTests {
    @Test func corruptStoreRemainsByteIdentical() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("unsupported or corrupt database".utf8)
        try original.write(to: url)
        #expect(throws: (any Error).self) { try TrainingMigrationPlan.open(at: url) }
        #expect(try Data(contentsOf: url) == original)
    }
}

import SwiftData
import TrainingCore
@Model final class MigrationSentinel { var value: String; init(value: String) { self.value = value } }
enum TrainingTestV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] { TrainingSchemaV1.models + [MigrationSentinel.self] }
}
final class MigrationProbe: @unchecked Sendable {
    static let shared = MigrationProbe()
    private let lock = NSLock()
    private var invoked = false
    func mark() { lock.lock(); invoked = true; lock.unlock() }
    func reset() { lock.lock(); invoked = false; lock.unlock() }
    var wasInvoked: Bool { lock.lock(); defer { lock.unlock() }; return invoked }
}
enum DeliberatelyFailingMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TrainingSchemaV1.self, TrainingTestV2.self] }
    static var stages: [MigrationStage] {
        [.custom(fromVersion: TrainingSchemaV1.self, toVersion: TrainingTestV2.self,
                 willMigrate: { _ in MigrationProbe.shared.mark(); throw EngineError(code: "injected_migration_failure", field: "migration") }, didMigrate: nil)]
    }
}
extension MigrationTests {
    @Test func failingRealMigrationPreservesOldStoreAndAcceptedState() async throws {
        let s = try await RepositoryTestHarness.make(goal: .size)
        let before = try await s.repository.snapshot(programID: s.programID)
        await s.repository.close()
        let bytes = try Data(contentsOf: s.storeURL)
        let config = ModelConfiguration(schema: Schema(versionedSchema: TrainingTestV2.self), url: s.storeURL, cloudKitDatabase: .none)
        MigrationProbe.shared.reset()
        #expect(throws: (any Error).self) {
            try ModelContainer(for: Schema(versionedSchema: TrainingTestV2.self), migrationPlan: DeliberatelyFailingMigration.self, configurations: [config])
        }
        #expect(MigrationProbe.shared.wasInvoked)
        #expect(try Data(contentsOf: s.storeURL) == bytes)
        let reopened = try TrainingRepository.open(at: s.storeURL)
        #expect(try await reopened.snapshot(programID: s.programID) == before)
    }
}

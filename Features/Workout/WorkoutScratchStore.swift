import Foundation

/// Local presentation identity, deliberately absent from repository/backup types.
struct WorkoutScratchKey: Codable, Equatable, Sendable {
    var storeID: String
    var datasetID: String
    var programID: String
    var draftID: UUID
    var prescriptionID: String
    var step: WorkoutStep
    var expectedObservationHash: String?
}

struct WorkoutScratch: Codable, Equatable, Sendable {
    var version: Int = 1
    var generation: UInt64
    var key: WorkoutScratchKey
    var entry: SetEntryDraft
}

/// Serial local atomic writes. Watermarks survive reopening; a removed draft is
/// terminal so a previously captured callback can never resurrect its input.
actor WorkoutScratchStore {
    private struct Record: Codable {
        var version = 1
        var generation: UInt64
        var removed = false
        var scratch: WorkoutScratch?
    }
    private let directory: URL
    private(set) var writeCount = 0
    init(directory: URL) { self.directory = directory.standardizedFileURL }

    #if DEBUG
    private var beforeSaveForTesting: (@Sendable () async -> Void)?
    private var beforeInvalidateForTesting: (@Sendable () async -> Void)?
    func setBeforeInvalidateForTesting(_ action: (@Sendable () async -> Void)?) { beforeInvalidateForTesting = action }
    private var beforeLoadForTesting: (@Sendable () async -> Void)?
    func setBeforeSaveForTesting(_ action: (@Sendable () async -> Void)?) { beforeSaveForTesting = action }
    func setBeforeLoadForTesting(_ action: (@Sendable () async -> Void)?) { beforeLoadForTesting = action }
    #endif
    func load(key: WorkoutScratchKey) async throws -> WorkoutScratch? {
        #if DEBUG
        await beforeLoadForTesting?()
        #endif
        guard let record = try read(key.draftID), !record.removed,
              let scratch = record.scratch, scratch.key == key else { return nil }
        return scratch
    }
    func save(_ scratch: WorkoutScratch) async throws {
        #if DEBUG
        await beforeSaveForTesting?()
        #endif
        guard scratch.version == 1, scratch.generation > 0 else { throw invalid() }
        if let old = try read(scratch.key.draftID) {
            guard !old.removed, scratch.generation > old.generation else { return }
        }
        try write(Record(generation: scratch.generation, scratch: scratch), id: scratch.key.draftID)
    }
    func invalidate(draftID: UUID, throughGeneration: UInt64) async throws {
        #if DEBUG
        await beforeInvalidateForTesting?()
        #endif
        let old = try read(draftID)
        guard old?.removed != true, old == nil || old!.generation <= throughGeneration else { return }
        try write(Record(generation: throughGeneration, scratch: nil), id: draftID)
    }
    func remove(draftID: UUID) async throws {
        let old = try read(draftID)
        guard old?.removed != true else { return }
        try write(Record(generation: old?.generation ?? 0, removed: true, scratch: nil), id: draftID)
    }
    func generation(draftID: UUID) async throws -> UInt64 { try read(draftID)?.generation ?? 0 }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    private func read(_ id: UUID) throws -> Record? {
        let url = file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1,
              record.scratch.map({ $0.version == 1 && $0.generation > 0 && $0.key.draftID == id && $0.generation == record.generation && !record.removed }) ?? true else { throw invalid() }
        return record
    }
    private func write(_ record: Record, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(id), options: .atomic)
        writeCount += 1
    }
    private func invalid() -> NSError { NSError(domain: "WorkoutScratchStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported or invalid workout input file."]) }
}

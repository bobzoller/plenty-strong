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
    var expectedOutcome: String? = nil
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
    private struct Retirement: Codable {
        var version = 1
        var generation: UInt64 = 0
        var keys: [WorkoutScratchKey] = []
        var resetPending = false
    }
    private var retirements: [UUID: Retirement] = [:]
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
        guard try !isRetired(key), let record = try read(key.draftID), !record.removed,
              let scratch = record.scratch, scratch.key == key else { return nil }
        return scratch
    }
    func save(_ scratch: WorkoutScratch) async throws {
        #if DEBUG
        await beforeSaveForTesting?()
        #endif
        guard scratch.version == 1, scratch.generation > 0 else { throw invalid() }
        guard try !isRetired(scratch.key) else { return }
        if let old = try read(scratch.key.draftID) {
            guard !old.removed, scratch.generation > old.generation else { return }
        }
        try write(Record(generation: scratch.generation, scratch: scratch), id: scratch.key.draftID)
    }
    func invalidate(draftID: UUID, throughGeneration: UInt64, expectedKey: WorkoutScratchKey? = nil) async throws {
        #if DEBUG
        await beforeInvalidateForTesting?()
        #endif
        let old = try read(draftID)
        if let expectedKey, let currentKey = old?.scratch?.key, currentKey != expectedKey { return }
        guard old?.removed != true, old == nil || old!.generation <= throughGeneration else { return }
        try write(Record(generation: throughGeneration, scratch: nil), id: draftID)
    }
    func remove(draftID: UUID) async throws {
        let old = try read(draftID)
        guard old?.removed != true else { return }
        try write(Record(generation: old?.generation ?? 0, removed: true, scratch: nil), id: draftID)
    }
    /// Retire only the failed page identity. Later movements in the same draft
    /// retain scratch support; delayed writes from this identity remain closed.
    @discardableResult func retire(key: WorkoutScratchKey, throughGeneration: UInt64) throws -> UInt64 {
        var retained = retirements[key.draftID] ?? Retirement()
        if !retained.keys.contains(key) { retained.keys.append(key) }
        retained.generation = max(retained.generation, throughGeneration)
        retained.resetPending = true
        retirements[key.draftID] = retained
        let metadata = try retirement(key.draftID)
        try resetRetiredRecord(id: key.draftID, metadata: metadata)
        return metadata.generation
    }
    private func retirementFile(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".retired") }
    private func retirement(_ id: UUID) throws -> Retirement {
        let url = retirementFile(id)
        var metadata = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(Retirement.self, from: Data(contentsOf: url)) : Retirement()
        guard metadata.version == 1, metadata.keys.allSatisfy({ $0.draftID == id }) else { throw invalid() }
        if let cached = retirements[id] {
            let resetAlreadyCommitted = !metadata.resetPending && metadata.generation >= cached.generation && cached.keys.allSatisfy { metadata.keys.contains($0) }
            for key in cached.keys where !metadata.keys.contains(key) { metadata.keys.append(key) }
            metadata.generation = max(metadata.generation, cached.generation)
            metadata.resetPending = metadata.resetPending || (cached.resetPending && !resetAlreadyCommitted)
        }
        retirements[id] = metadata
        return metadata
    }
    private func isRetired(_ key: WorkoutScratchKey) throws -> Bool {
        if retirements[key.draftID]?.keys.contains(key) == true { return true }
        return try retirement(key.draftID).keys.contains(key)
    }
    private func resetRetiredRecord(id: UUID, metadata: Retirement) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Persist the fence before preserving/resetting the unreadable record.
        // A failed cleanup can retry on the next ordinary scratch operation.
        try JSONEncoder().encode(metadata).write(to: retirementFile(id), options: .atomic)
        if let bytes = try? Data(contentsOf: file(id)),
           let current = try? JSONDecoder().decode(Record.self, from: bytes), supported(current, id: id),
           current.removed || current.scratch.map({ !metadata.keys.contains($0.key) }) == true ||
            (current.scratch == nil && current.generation >= metadata.generation) {
            // A reopened owner may already have saved another page or removed
            // the draft. An older cleanup cannot erase or reopen that record.
            var ready = metadata; ready.generation = max(ready.generation, current.generation); ready.resetPending = false
            try JSONEncoder().encode(ready).write(to: retirementFile(id), options: .atomic)
            retirements[id] = ready
            return
        }
        if FileManager.default.fileExists(atPath: file(id).path) {
            let rejected = directory.appendingPathComponent(id.uuidString.lowercased() + ".rejected." + UUID().uuidString.lowercased() + ".json")
            try FileManager.default.copyItem(at: file(id), to: rejected)
        }
        try write(Record(generation: metadata.generation, scratch: nil), id: id)
        var ready = metadata; ready.resetPending = false
        try JSONEncoder().encode(ready).write(to: retirementFile(id), options: .atomic)
        retirements[id] = ready
    }
    func generation(draftID: UUID) async throws -> UInt64 {
        let record = try read(draftID)
        return max(record?.generation ?? 0, try retirement(draftID).generation)
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    private func read(_ id: UUID) throws -> Record? {
        let metadata = try retirement(id)
        if metadata.resetPending { try resetRetiredRecord(id: id, metadata: metadata) }
        let url = file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard supported(record, id: id) else { throw invalid() }
        return record
    }
    private func supported(_ record: Record, id: UUID) -> Bool {
        record.version == 1 && (record.scratch.map {
            $0.version == 1 && $0.generation > 0 && $0.key.draftID == id && $0.generation == record.generation && !record.removed
        } ?? true)
    }
    private func write(_ record: Record, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(id), options: .atomic)
        writeCount += 1
    }
    private func invalid() -> NSError { NSError(domain: "WorkoutScratchStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported or invalid workout input file."]) }
}

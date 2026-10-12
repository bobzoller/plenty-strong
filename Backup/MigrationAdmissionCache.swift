import Foundation
import TrainingCore

/// Repository-owned, bounded immutable evidence cache. Every lookup fingerprints
/// actual supplied bytes, never just a claimed content hash or transport checksum.
/// Cold/changed inputs receive complete validation and pure replay before storage.
final class MigrationAdmissionCache {
    private var sources: [String: ExternalSourceArchive] = [:]
    private var roots: [String: ConfigurationResult] = [:]
    private var recordKeys: [String: String] = [:]
    func source(_ archive: ArchivedObject) -> ExternalSourceArchive? {
        let digest = BackupService.hash(archive.bytes)
        guard digest == archive.checksum, let value = sources[digest], value.contentHash == archive.id else { return nil }
        return value
    }
    func source(bytes: Data) -> ExternalSourceArchive? { sources[BackupService.hash(bytes)] }
    func remember(source: ExternalSourceArchive, bytes: Data) {
        if sources.count >= 4 { sources.removeAll(); roots.removeAll(); recordKeys.removeAll() }
        sources[BackupService.hash(bytes)] = source
    }
    func root(key: String) -> ConfigurationResult? { roots[key] }
    func remember(root: ConfigurationResult, key: String) {
        if roots.count >= 64 { roots.removeAll() }
        roots[key] = root
    }
    func recordKey(_ record: ArchivedRecord) throws -> String {
        let fingerprint = try CanonicalJSON.sha256(.array([.string(record.recordID), .string(record.zoneName), .string(record.recordType),
            record.claimedChecksum.map(CanonicalValue.string) ?? .null, .string(BackupService.hash(record.bytes))]))
        if let key = recordKeys[fingerprint] { return key }
        let key = try record.key
        if recordKeys.count >= 256 { recordKeys.removeAll() }
        recordKeys[fingerprint] = key
        return key
    }
    func canonicalBytes(_ bytes: Data) throws -> Data {
        if source(bytes: bytes) != nil { return bytes } // Stored only after canonical byte equality proved.
        return try CloudRecordCodec.canonicalBytes(bytes)
    }
}

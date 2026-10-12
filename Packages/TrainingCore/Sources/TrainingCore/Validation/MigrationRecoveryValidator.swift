import Foundation

public func requiresMigrationRecoveryReview(state: ProgramState, movementID: String) -> Bool {
    guard state.schemaVersion == 5, let base = state.config.variants?[movementID]?.baseMovementID else { return false }
    return state.migration?.baselines.first { $0.baseMovementID == base }?.recoveryRequired == true
}

/// Fresh user review is session metadata, never clinical clearance or capacity.
/// Unconfirmed partial/stopped raw observations remain recordable and cannot
/// qualify for native progression through the existing exact classifier.
func validateMigrationRecoveryAttestations(event: CompletedWorkout, state: ProgramState) throws {
    guard state.schemaVersion == 5 else {
        guard event.migrationRecoveryAttestations == nil else { throw EngineError(code: "unsupported_policy", field: "migrationRecoveryAttestations") }
        return
    }
    let supplied = event.migrationRecoveryAttestations ?? []
    guard let origin = state.migration, let timing = event.timing,
          Set(supplied.map(\.movementID)).count == supplied.count,
          supplied.allSatisfy({ attestation in
              event.exercises.contains { $0.movementID == attestation.movementID } &&
              requiresMigrationRecoveryReview(state: state, movementID: attestation.movementID) &&
              attestation.externalArchiveHash == origin.externalArchiveHash &&
              attestation.checkedAtMilliseconds >= timing.startedAtMilliseconds &&
              attestation.checkedAtMilliseconds <= timing.finishedAtMilliseconds
          }) else { throw EngineError(code: "invalid_migration", field: "recovery_attestation") }
    for log in event.exercises where log.status == .completed && requiresMigrationRecoveryReview(state: state, movementID: log.movementID) {
        guard supplied.contains(where: { $0.movementID == log.movementID }) else {
            throw EngineError(code: "migration_recovery_required", field: "exercises.\(log.movementID)")
        }
    }
}

#if DEBUG
import Foundation
import TrainingCore

/// Only synthetic design data. Used by native model/UI tests and the disposable
/// local proof harness; this has no installed-store or account access.
enum ProgramMigrationDesignFixture {
    static func make(unresolvedLoad: Bool = false, recoveryRequired: Bool = false, paddingByteCount: Int = 0) throws -> ProgramMigrationDocument {
        let config = try selectFixedProgram(goal: .size, programID: UUID())
        let baselines = config.movements.map { movement in
            var baseline = MigrationBaseline(baseMovementID: movement.id, variantID: movement.id + "-source-setup",
                modifications: movement.loadingMode == .userManagedAssistance ? "Synthetic manual setting 137" : "Synthetic source setup",
                load: movement.loadingMode == .externalLoad && !(unresolvedLoad && movement.id == "db_triceps_extension") ? movement.availableLoads[4] : nil,
                targets: movement.loadingMode == .userManagedAssistance ? [7, 5, 4] : [11, 10, 9],
                sourceRepFloor: movement.loadingMode == .userManagedAssistance ? 5 : 8, sourceRepCeiling: 12,
                minimumRir: movement.id == "bent_knee_hanging_leg_raise_ab_straps" ? 3 : 2,
                paused: false, reviewRequired: false, recoveryStatus: "unknown",
                safetyText: "Synthetic recovery status unknown; retained three-rep safeguard",
                sourceKeys: ["state:" + movement.id], unresolvedLoadAmount: unresolvedLoad && movement.id == "db_triceps_extension" ? "25" : nil)
            baseline.recoveryRequired = recoveryRequired && movement.id == "suitcase_db_squat"
            return baseline
        }
        let rows = [ExternalExerciseObservation(sourceKey: "history:1", movementLabel: "Synthetic assisted pull",
                       raw: ["reps": .string("5.5/BW"), "load": .string("137 manual setting"), "notes": .string("Synthetic ambiguous observation")]),
                    ExternalExerciseObservation(sourceKey: "history:2", movementLabel: "Synthetic row",
                       raw: ["reps": .string("10/9"), "load": .string("25"), "sourceTargets": .null])]
        let date = try LocalDate(iso8601: "2026-10-04")
        let workouts = [ExternalWorkoutObservation(date: date, sourceKey: "source-day:1", rows: rows)]
        let sourceState: [String: CanonicalValue] = ["qualifyingCounter": .integer(2), "phase": .string("Synthetic source deload"),
            "noExerciseRows": .array([.object(["sourceKey": .string("history:0"), "raw": .string("Synthetic no-exercise record")])])]
        struct Original: Codable { var baselines: [MigrationBaseline]; var workouts: [ExternalWorkoutObservation]; var sourceState: [String: CanonicalValue]; var syntheticPadding: String }
        let original = Original(baselines: baselines, workouts: workouts, sourceState: sourceState, syntheticPadding: String(repeating: "x", count: paddingByteCount))
        let file = try ExternalSourceFile(name: "synthetic-source.json", mediaType: "application/json", bytes: JSONEncoder().encode(original))
        var bindings: [MigrationSourceBinding] = []
        func bind(_ pointer: String) { bindings.append(MigrationSourceBinding(targetPointer: pointer, fileName: file.name, sourcePointer: pointer)) }
        for (index, baseline) in baselines.enumerated() {
            for key in ["baseMovementID", "variantID", "modifications", "targets", "sourceRepFloor", "sourceRepCeiling", "minimumRir", "paused", "reviewRequired", "recoveryStatus", "recoveryRequired", "safetyText", "sourceKeys"] { bind("/baselines/\(index)/\(key)") }
            if baseline.load != nil { for key in ["amount", "unit", "basis"] { bind("/baselines/\(index)/load/\(key)") } }
            if baseline.unresolvedLoadAmount != nil { bind("/baselines/\(index)/unresolvedLoadAmount") }
        }
        bind("/baselines"); bind("/workouts")
        bind("/workouts/0/date"); bind("/workouts/0/sourceKey")
        for index in rows.indices { bind("/workouts/0/rows/\(index)/raw"); bind("/workouts/0/rows/\(index)/movementLabel"); bind("/workouts/0/rows/\(index)/sourceKey") }
        bind("/sourceState")
        let archive = try ExternalSourceArchive(files: [file], baselines: baselines, workouts: workouts, sourceState: sourceState, sourceBindings: bindings)
        return ProgramMigrationDocument(source: archive, checkpoint: ProgramMigrationCheckpoint(externalArchiveHash: archive.contentHash,
            baselines: baselines, externalLastSessionDate: date, nextWorkout: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-06"), slotID: "TUE")))
    }
    static var acceptance: MigrationAcceptance {
        MigrationAcceptance(acceptedAtMilliseconds: 1_791_223_200_000, timeZoneID: "Pacific/Honolulu")
    }
    static var selection: MigrationSelection { MigrationSelection(goal: .fatLoss, acceptedNativePolicy: true) }
}
#endif

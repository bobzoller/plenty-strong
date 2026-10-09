import Foundation
import TrainingCore

struct StarterCoverageRow: Identifiable {
    let muscle: String
    let initialWork: String
    let establishedWork: String
    let days: String
    var id: String { muscle }
}
struct StarterProgramDetails {
    let title: String
    let description: String
    let duration: String
    let equipment: [String]
    let cuesByMovementID: [String: [String]]
    let coverageRows: [StarterCoverageRow]
    let limitations: [String]
}
extension StarterProgramChoice {
    var title: String { self == .upperBody ? "Upper-body emphasis" : "Whole-body, glute emphasis" }
    var description: String {
        self == .upperBody ? "Whole-body training with extra attention to your chest, back, shoulders, and arms." : "Whole-body training with extra attention to your glutes, while building your legs and upper body."
    }
}

/// Copy is bound to the immutable definition and Trainer source, never a user's
/// inferred sex, starting loads, active dose, or personal training records.
enum StarterProgramPresentation {
    private struct Consultation: Decodable {
        let essentialCues: [String: String]
        let muscleExposureTable: [[String]]
        let coverageCaveats: [String]
    }
    private static func verifiedConsultation() throws -> Consultation {
        guard let url = Bundle.main.url(forResource: "2026-10-08-glute-starter-profile", withExtension: "json") else {
            throw EngineError(code: "missing_profile", field: "preview")
        }
        let data = try Data(contentsOf: url)
        let hash = StarterProgramCatalog.gluteSourceProfileHash
        guard case .object(var fields) = try JSONDecoder().decode(CanonicalValue.self, from: data),
              fields.removeValue(forKey: "contentHash") == .string(hash),
              try CanonicalJSON.sha256(.object(fields)) == hash else {
            throw EngineError(code: "profile_hash_mismatch", field: "preview")
        }
        return try JSONDecoder().decode(Consultation.self, from: data)
    }
    static func details(choice: StarterProgramChoice, goal: Goal) throws -> StarterProgramDetails {
        let definition = try StarterProgramCatalog.definition(choice)
        let rules = try RulesetCatalog.starter(choice)
        let config = try selectStarterProgram(definition: definition, goal: goal, programID: UUID())
        let source = try verifiedConsultation()
        let movementIDs = Set(definition.movements.map(\.id))
        // Exact identity only: differing press/row angles cannot borrow cues.
        let cues = source.essentialCues.filter { movementIDs.contains($0.key) }.mapValues { [$0] }
        let equipment = definition.requiredEquipment.map {
            switch $0 {
            case "adjustable_dumbbells": "Dumbbells 5–80 lb in 5 lb steps"
            case "adjustable_bench": "Adjustable bench"
            case "pull_up_bar": "Pull-up bar"
            default: $0
            }
        }
        if choice == .wholeBodyGlutes {
            let rows = source.muscleExposureTable.map { StarterCoverageRow(muscle: $0[0], initialWork: $0[1], establishedWork: $0[2], days: $0[3]) }
            return StarterProgramDetails(title: choice.title, description: choice.description,
                duration: "Allow about 45–65 minutes; your time may vary.", equipment: equipment,
                cuesByMovementID: cues, coverageRows: rows,
                limitations: source.coverageCaveats + ["Exact exercise choices and doses are coaching and product defaults, not a research-validated complete routine.", "Strength uses a handling check for press, row, and suitcase squat at your chosen load. Choose standard 8–12 reps or confirm safe handling for 4–6 reps. RDL uses 6–10 reps."])
        }
        // The original profile's actual primary and secondary assignments remain
        // visible separately. A compound appears in each relevant muscle row.
        let muscles = Set(definition.movements.flatMap { $0.primaryMuscles + $0.secondaryMuscles }).sorted()
        var setsByBase: [String: Int] = [:]
        for movement in definition.movements {
            guard let variant = config.activeVariantIDs?[movement.id] else { continue }
            setsByBase[movement.id] = try resolveMovementDose(config: config, variantID: variant, exercise: nil, rules: rules).initialSets
        }
        let rows = muscles.map { muscle in
            var primary = 0, secondary = 0
            var days = Set<String>()
            for slot in definition.weeklySlots {
                for id in slot.movementIDs {
                    guard let movement = definition.movements.first(where: { $0.id == id }),
                          let sets = setsByBase[id] else { continue }
                    if movement.primaryMuscles.contains(muscle) { primary += sets; days.insert(slot.id) }
                    if movement.secondaryMuscles.contains(muscle) { secondary += sets; days.insert(slot.id) }
                }
            }
            let work = "\(primary) primary / compound sets + \(secondary) indirect sets"
            return StarterCoverageRow(muscle: muscle.replacingOccurrences(of: "_", with: " ").capitalized, initialWork: work, establishedWork: work, days: String(days.count))
        }
        return StarterProgramDetails(title: choice.title, description: choice.description, duration: "", equipment: equipment,
            cuesByMovementID: cues, coverageRows: rows, limitations: [
                "The original routine concentrates lower-body and direct trunk work once a week. It does not provide twice-weekly coverage of every muscle.",
                "Pull-ups and chin-ups need a setup you can perform comfortably. A bar alone may not be sufficient.",
                "Primary / compound and indirect work overlap. Do not add muscle rows together to calculate workout sets."
            ])
    }
}

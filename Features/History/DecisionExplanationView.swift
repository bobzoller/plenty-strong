import SwiftUI
import TrainingCore

struct DecisionExplanationView: View {
    let decision: Decision
    static func copy(for key: String) -> String {
        switch key {
        case "maintenance_success": "Stable work at the target effort is maintenance success. Keep this target."
        case "capacity_hold": "Keep the target. Good reps below the ceiling do not require a weekly increase."
        case "ceiling_confirmation": "Keep the target while another comparable workout confirms the ceiling."
        case "movement_paused": "Pain or loss of control paused this movement across every saved setup. Review before a safe return."
        case "paused_preserved": "The safety pause stays in place. Logging or changing setups cannot clear it."
        case "ineligible_observation": "Your actual work is retained. Partial or noncomparable observations do not qualify progression."
        case "rep_ceiling_exceeded": "Reps above the ceiling are retained as actual work and do not qualify progression."
        case "skip_recorded": "The skip is recorded without a performed set or progression credit."
        case "easier_session_recorded": "Easier work is retained without baseline, progression or recovery-return credit."
        case "baseline_established": "This setup's recorded work established its starting baseline."
        case "baseline_pending": "Keep the starting target while qualifying work establishes the baseline."
        case "actual_load_changed": "The actual load changed. This setup returns to baseline using the recorded load."
        case "strain_hold": "Keep the target after this setback. Another comparable setback is required before a reduction."
        case "load_reduced": "Repeated comparable setbacks reduced the load and restarted baseline."
        case "recovery_dose": "Repeated setbacks reduced the working-set dose for a return workout."
        case "load_increased": "Comparable confirmations allowed the next available load within the step limit."
        case "rep_ceiling_extended": "Comparable confirmations allowed a higher rep ceiling while retaining the load."
        case "equipment_limit", "manual_setup_limit": "The available equipment or manual setup limits automatic progression. Review the setup without inventing a load."
        case "progression_restricted": "This movement's restrictions prevent automatic increases. Keep the permitted target."
        case "plateau_check": "The comparable-work window suggests a review. No automatic increase is required."
        case "interruption_return", "interruption_return_pending": "After a long interruption, use the reduced return dose before normal work."
        case "interruption_return_complete", "recovery_return_complete": "Qualifying return work restored the normal dose."
        case "recovery_return_pending": "Continue the return dose until qualifying work is recorded."
        case "recovery_review_required": "Return work needs a safety review before resuming."
        case "goal_changed": "Changing the goal restarts baselines while retaining history, loads and safety restrictions."
        case "minimum_rir_changed": "A stricter effort reserve now applies across this base movement’s saved setups. Affected baselines restart without relaxing safety."
        case "setup_reset": "This setup's comparison window was reset. Original history and safety restrictions remain."
        case "safe_resume": "An explicitly confirmed safe return cleared the shared pause and restarted the affected baselines."
        case "variant_created": "A separate saved setup starts its own baseline without borrowing a load."
        case "variant_selected": "The selected setup restores its own saved state."
        case "variant_description_corrected": "Description corrected; setup identity and progress are retained. Earlier labels stay unchanged."
        case "workout_rescheduled": "A missed slot moved forward without recording a completed workout."
        default: "Stored decision: \(key.replacingOccurrences(of: "_", with: " "))."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.copy(for: decision.explanationKey)).accessibilityIdentifier("history.explanation.\(decision.explanationKey)")
            DisclosureGroup("Why this decision") {
                Text("Stored rule: \(decision.ruleIDs.joined(separator: ", "))")
                Text("Source: \(decision.sourceIDs.isEmpty ? "App adaptation" : decision.sourceIDs.joined(separator: ", "))")
                Text("Evidence class: \(decision.evidenceClass.rawValue)")
                Text("Decision key: \(decision.explanationKey)")
            }.font(.caption)
        }
    }
}

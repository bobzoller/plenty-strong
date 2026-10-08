import SwiftUI
import TrainingCore

struct PrescriptionComparisonView: View {
    let summary: MovementPrescriptionSummary
    let repCounting: RepCounting
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prior = summary.prior {
                Text("Last time").font(.headline).accessibilityAddTraits(.isHeader)
                Text(MovementPrescriptionSummary.reps(prior.actualSets, repCounting: repCounting))
                    .accessibilityHint("Last time actual performance for this setup")
                    .accessibilityIdentifier("movement.last-reps")
                Text(prior.date.iso8601).font(.caption)
                if let load = prior.actualLoad { Text("Last time load: \(MovementPrescriptionSummary.load(load))") }
                ForEach(prior.contextLabels, id: \.self) { Text($0).font(.caption) }
                if let skipped = prior.skippedSetIndices, !skipped.isEmpty { Text("Skipped sets: \(skipped.map { String($0 + 1) }.joined(separator: ", "))") }
            } else { Text("First workout for this setup").accessibilityIdentifier("movement.first-workout") }
            Text("Today's goal").font(.headline).accessibilityAddTraits(.isHeader)
            if summary.policy == nil { Text("Prescription unavailable — stored policy or targets require review").accessibilityIdentifier("movement.unavailable") }
            else if summary.row.kind == .paused { Text("Paused — no working sets") }
            else if summary.row.kind == .setupReview { Text("Setup review required — no working sets").accessibilityIdentifier("movement.setup-review") }
            else if let targets = summary.targetReps {
                Text(targets.map(String.init).joined(separator: " / ") + " reps" + (repCounting == .perSide ? " per side" : ""))
                    .accessibilityHint("Today's prescribed reps for this setup, independent of actual reps")
                    .accessibilityIdentifier("movement.goal-reps")
            } else if let set = summary.row.sets.first { Text("\(summary.row.sets.count) sets · Up to \(set.repCeiling) good reps\(repCounting == .perSide ? " per side" : "")").accessibilityIdentifier("movement.goal-reps") }
            if let load = summary.prescribedLoad { Text("Prescribed load: \(MovementPrescriptionSummary.load(load))") }
            if let instruction = summary.row.sets.first?.effortInstruction { Text(instruction).accessibilityIdentifier("movement.instruction") }
            Text("Actual").font(.headline)
            if summary.actualSets.isEmpty { Text("No performed reps recorded").accessibilityIdentifier("movement.actual-reps") }
            else { Text(MovementPrescriptionSummary.reps(summary.actualSets, repCounting: repCounting)).accessibilityLabel("Actual: \(MovementPrescriptionSummary.reps(summary.actualSets, repCounting: repCounting))").accessibilityIdentifier("movement.actual-reps") }
            if let load = summary.actualLoad { Text("Actual load: \(MovementPrescriptionSummary.load(load))") }
            if !summary.skippedSetIndices.isEmpty { Text("Skipped sets: \(summary.skippedSetIndices.map { String($0 + 1) }.joined(separator: ", "))") }
        }
    }
}

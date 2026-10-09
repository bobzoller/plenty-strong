import Foundation

/// Configuration is selected as a whole path. Definition choices identify the
/// verified source of an incompatible saved variant; none can waive safety.
public struct BranchSelection: Codable, Equatable, Sendable {
    public var selectedHeadHash: String
    public var configurationHeadHash: String?
    public var variantDefinitionHeadHashes: [String: String]
    public var reviewedQuarantineChecksums: [String]
    public init(selectedHeadHash: String, configurationHeadHash: String? = nil,
                variantDefinitionHeadHashes: [String: String] = [:], reviewedQuarantineChecksums: [String] = []) {
        self.selectedHeadHash = selectedHeadHash; self.configurationHeadHash = configurationHeadHash
        self.variantDefinitionHeadHashes = variantDefinitionHeadHashes
        self.reviewedQuarantineChecksums = reviewedQuarantineChecksums
    }
    enum CodingKeys: String, CodingKey { case selectedHeadHash, configurationHeadHash, variantDefinitionHeadHashes, reviewedQuarantineChecksums }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedHeadHash = try c.decode(String.self, forKey: .selectedHeadHash)
        configurationHeadHash = try c.decodeIfPresent(String.self, forKey: .configurationHeadHash)
        variantDefinitionHeadHashes = try c.decodeIfPresent([String: String].self, forKey: .variantDefinitionHeadHashes) ?? [:]
        reviewedQuarantineChecksums = try c.decodeIfPresent([String].self, forKey: .reviewedQuarantineChecksums) ?? []
    }
}
/// The adapter verifies these commands against immutable archives before using
/// this value. It retains the complete originals, not an invented merged log.
public struct VerifiedBranch: Codable, Equatable, Sendable {
    public var headHash: String
    public var state: ProgramState
    public var commands: [JournalCommand]
    public init(headHash: String, state: ProgramState, commands: [JournalCommand]) {
        self.headHash = headHash; self.state = state; self.commands = commands
    }
}
public struct BranchResolutionInput: Codable, Equatable, Sendable {
    public var commonAncestor: ProgramState
    public var competingHeadHashes: [String]
    public var branches: [VerifiedBranch]
    public var selection: BranchSelection
    public var safetyRestrictions: [String: MovementSafetyState]
    public var rules: Ruleset
    public var next: WorkoutSlot
    public init(commonAncestor: ProgramState, competingHeadHashes: [String], branches: [VerifiedBranch],
                selection: BranchSelection, safetyRestrictions: [String: MovementSafetyState] = [:],
                rules: Ruleset, next: WorkoutSlot) {
        self.commonAncestor = commonAncestor; self.competingHeadHashes = competingHeadHashes
        self.branches = branches; self.selection = selection; self.safetyRestrictions = safetyRestrictions
        self.rules = rules; self.next = next
    }
}
public struct BranchResolution: Codable, Equatable, Sendable {
    public var state: ProgramState
    public var workout: WorkoutPrescription
    public var decisions: [Decision]
    public var preservedHeadHashes: [String]
    public init(state: ProgramState, workout: WorkoutPrescription, decisions: [Decision], preservedHeadHashes: [String]) {
        self.state = state; self.workout = workout; self.decisions = decisions; self.preservedHeadHashes = preservedHeadHashes
    }
}
public func resolveCloudBranches(_ input: BranchResolutionInput) throws -> BranchResolution {
    func reject(_ field: String) throws -> Never { throw EngineError(code: "invalid_branch_selection", field: field) }
    func exact(_ value: some Encodable) throws -> Data {
        try CanonicalJSON.encode(JSONDecoder().decode(CanonicalValue.self, from: JSONEncoder().encode(value)))
    }
    let heads = input.competingHeadHashes.sorted()
    guard !heads.isEmpty, (heads.count >= 2 || !input.selection.reviewedQuarantineChecksums.isEmpty), Set(heads).count == heads.count,
          Set(input.branches.map(\.headHash)) == Set(heads), input.branches.count == heads.count,
          let selected = input.branches.first(where: { $0.headHash == input.selection.selectedHeadHash }) else { try reject("heads") }
    let original = selected.state
    guard input.commonAncestor.schemaVersion == original.schemaVersion,
          input.commonAncestor.rulesetHash == original.rulesetHash,
          input.branches.allSatisfy({ $0.state.schemaVersion == original.schemaVersion && $0.state.rulesetHash == original.rulesetHash }) else {
        throw EngineError(code: "mixed_policy_conflict", field: "branches")
    }
    let policy = try ProgramPolicy.resolve(schemaVersion: original.schemaVersion, rules: input.rules)
    try validateConfigurationInput(state: original, rules: input.rules, slot: input.next)
    guard input.commonAncestor.config.programID == original.config.programID, input.commonAncestor.schemaVersion == original.schemaVersion,
          input.commonAncestor.rulesetHash == original.rulesetHash else { try reject("commonAncestor") }
    try validateConfigurationState(state: input.commonAncestor, rules: input.rules)
    for branch in input.branches {
        guard branch.state.config.programID == original.config.programID,
              branch.state.schemaVersion == original.schemaVersion,
              branch.state.rulesetHash == original.rulesetHash,
              branch.state.revision >= input.commonAncestor.revision else { try reject("branch_state") }
        try validateConfigurationState(state: branch.state, rules: input.rules)
        if let last = branch.state.lastSessionDate, input.next.date <= last { try reject("next") }
    }
    // A whole-path configuration choice covers load/setup and active-selection
    // disagreements, without manufacturing a combination of configurations.
    var configurationDiffers = false
    for branch in input.branches {
        if try exact(branch.state.config) != exact(original.config) { configurationDiffers = true }
        for (id, state) in branch.state.exercises {
            if let chosen = original.exercises[id],
               try exact(state.load) != exact(chosen.load) || state.setupRevision != chosen.setupRevision {
                configurationDiffers = true
            }
        }
    }
    if configurationDiffers && input.selection.configurationHeadHash != selected.headHash { try reject("configurationHeadHash") }
    if let configuration = input.selection.configurationHeadHash, configuration != selected.headHash { try reject("configurationHeadHash") }
    var updated = original
    var safety = original.baseSafety ?? Dictionary(uniqueKeysWithValues: original.config.movements.map {
        ($0.id, MovementSafetyState(paused: original.exercises[$0.id]?.mode == .paused, minimumRir: $0.minimumRir, sourceEventIDs: []))
    })
    func union(_ base: String, _ restriction: MovementSafetyState) throws {
        guard var shared = safety[base] else { try reject("safety_base") }
        shared.paused = shared.paused || restriction.paused
        shared.minimumRir = max(shared.minimumRir, restriction.minimumRir)
        shared.sourceEventIDs = Array(Set(shared.sourceEventIDs + restriction.sourceEventIDs)).sorted()
        safety[base] = shared
    }
    for branch in input.branches {
        for movement in branch.state.config.movements {
            try union(movement.id, branch.state.baseSafety?[movement.id] ?? MovementSafetyState(
                paused: branch.state.exercises[movement.id]?.mode == .paused, minimumRir: movement.minimumRir, sourceEventIDs: []))
        }
        for (id, exercise) in branch.state.exercises where exercise.mode == .paused {
            let base = branch.state.config.variants?[id]?.baseMovementID ?? id
            try union(base, MovementSafetyState(paused: true, minimumRir: safety[base]!.minimumRir, sourceEventIDs: []))
        }
        // Starter snapshots carry replayed family restrictions and clearances.
        // The legacy command union remains unchanged for earlier policies.
        for command in branch.commands where !policy.usesStarterDoses {
            if case let .workout(event, _) = command {
                for log in event.exercises where log.problem != .none {
                    let base = log.baseMovementID ?? branch.state.config.variants?[log.movementID]?.baseMovementID ?? log.movementID
                    try union(base, MovementSafetyState(paused: true, minimumRir: safety[base]?.minimumRir ?? 0, sourceEventIDs: [event.eventID]))
                }
            }
        }
    }
    for (base, restriction) in input.safetyRestrictions { try union(base, restriction) }
    if policy.usesVariants {
        let ids = Set(input.branches.flatMap { $0.state.config.variants!.keys })
        for id in ids.sorted() {
            let definitions = input.branches.filter { $0.state.config.variants![id] != nil }.sorted { $0.headHash < $1.headHash }
            let first = definitions[0]
            let differs = try definitions.contains { try exact($0.state.config.variants![id]!) != exact(first.state.config.variants![id]!) }
            let source: VerifiedBranch
            if differs {
                guard let choice = input.selection.variantDefinitionHeadHashes[id],
                      let explicit = definitions.first(where: { $0.headHash == choice }) else { try reject("variantDefinitionHeadHashes.\(id)") }
                source = explicit
            } else { source = definitions.first(where: { $0.headHash == selected.headHash }) ?? first }
            // Choosing a different definition for an active ID cannot silently
            // replace the configuration the user explicitly selected.
            if original.config.activeVariantIDs!.values.contains(id),
               try exact(source.state.config.variants![id]!) != exact(original.config.variants![id]!) { try reject("active_variant_definition") }
            updated.config.variants![id] = source.state.config.variants![id]
            if differs || updated.exercises[id] == nil { updated.exercises[id] = source.state.exercises[id] }
        }
        guard Set(input.selection.variantDefinitionHeadHashes.keys).isSubset(of: ids) else { try reject("variant_choices") }
        updated.baseSafety = safety
    } else {
        guard input.selection.variantDefinitionHeadHashes.isEmpty else { try reject("variant_choices") }
        for index in updated.config.movements.indices {
            updated.config.movements[index].minimumRir = safety[updated.config.movements[index].id]!.minimumRir
        }
    }
    if policy.usesStarterDoses {
        var ledger = updated.retainedSafety!
        for branch in input.branches {
            for (family, restriction) in branch.state.retainedSafety! {
                ledger[family] = unionStarterSafety(ledger[family], restriction)
            }
        }
        for (base, restriction) in safety {
            let family = input.rules.safetyFamilies![base]!
            ledger[family] = unionStarterSafety(ledger[family], restriction)
        }
        updated.retainedSafety = ledger
        for movement in updated.config.movements {
            safety[movement.id] = ledger[input.rules.safetyFamilies![movement.id]!]!
        }
        updated.baseSafety = safety
    }
    let preset = policy.usesStarterDoses ? nil : try input.rules.preset(goal: updated.config.goal, daysPerWeek: updated.config.daysPerWeek)
    var decisions: [Decision] = []
    for id in updated.exercises.keys.sorted() {
        let before = updated.exercises[id]!
        let base = updated.config.variants?[id]?.baseMovementID ?? id
        guard let movement = updated.config.movements.first(where: { $0.id == base }) else { try reject("variant_base") }
        let paused = safety[base]!.paused
        if policy.usesStarterDoses {
            try rebaselineStarterExercise(state: &updated, id: id, rules: input.rules, restartDose: true, clearHandling: true)
        } else {
            rebaseline(&updated.exercises[id]!, movement: movement, config: updated.config, preset: preset!, paused: paused)
            if policy.usesExactTargets { seedExactBaseline(&updated.exercises[id]!) }
        }
        decisions.append(try configurationDecision(id: id, action: paused ? .pause : .baseline, ruleIDs: policy.usesExactTargets ? ["X13"] : ["CLOUD01"],
            key: paused ? "cloud_resolution_pause" : "cloud_resolution_baseline", before: before, after: updated.exercises[id]!, ruleset: policy.usesExactTargets ? input.rules : nil))
    }
    let result = try finishConfiguration(original: original, updated: updated, rules: input.rules, slot: input.next, decisions: decisions)
    return BranchResolution(state: result.state, workout: result.workout, decisions: result.decisions, preservedHeadHashes: heads)
}

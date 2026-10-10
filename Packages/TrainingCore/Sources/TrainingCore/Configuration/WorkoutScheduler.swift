import Foundation

/// Converts caller-supplied instants only. Historical local dates/timezone labels
/// are immutable records; changing this context never rewrites them.
public struct CalendarContext: Equatable, Sendable {
    public let timeZoneID: String

    public init(timeZoneID: String) throws {
        guard TimeZone(identifier: timeZoneID) != nil else { throw EngineError(code: "invalid_timezone", field: "timeZoneId") }
        self.timeZoneID = timeZoneID
    }

    public func localDate(at instant: Date) throws -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return try LocalDate(iso8601: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!))
    }
}

public enum WorkoutScheduler {
    /// Exact scheduled-day starts are legal; after a completion use this strictly
    /// future boundary to prevent a second applied workout on the same local day.
    public static func nextSlot(after date: LocalDate, config: ProgramConfig) throws -> WorkoutSlot {
        try nextSlot(onOrAfter: date.adding(days: 1), config: config)
    }

    public static func validate(slot: WorkoutSlot, config: ProgramConfig, schedulingPolicy: SchedulingPolicy? = nil) throws {
        if schedulingPolicy == .flexibleV1 {
            guard config.weeklySlots.contains(where: { $0.id == slot.slotID }),
                  config.weeklySlots.contains(where: { $0.weekday == (try? weekday(on: slot.date)) }) else {
                throw EngineError(code: "invalid_slot_date", field: "slot.date")
            }
            return
        }
        guard let weekly = config.weeklySlots.first(where: { $0.id == slot.slotID }),
              let weekday = weekly.weekday, (0...6).contains(weekday),
              try self.weekday(on: slot.date) == weekday else {
            throw EngineError(code: "invalid_slot_date", field: "slot.date")
        }
    }

    /// Cadence provides the date; program order provides the rotation identity.
    public static func nextRotation(after date: LocalDate, consumedSlotID: String, config: ProgramConfig) throws -> WorkoutSlot {
        let cadence = try nextSlot(after: date, config: config)
        guard let index = config.weeklySlots.firstIndex(where: { $0.id == consumedSlotID }) else {
            throw EngineError(code: "invalid_slot", field: "slotId")
        }
        return WorkoutSlot(date: cadence.date, slotID: config.weeklySlots[(index + 1) % config.weeklySlots.count].id)
    }

    /// Recovery retains the selected pending group. Only merged actual-history
    /// ordering may move its suggestion forward; opening/reviewing has no clock.
    public static func pendingAfterRecovery(state: ProgramState, latestSessionDate: LocalDate?) throws -> WorkoutSlot {
        let pending = WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID)
        guard state.schedulingPolicy == .flexibleV1 else {
            throw EngineError(code: "unsupported_scheduling", field: "schedulingPolicy")
        }
        try validate(slot: pending, config: state.config, schedulingPolicy: state.schedulingPolicy)
        if let last = latestSessionDate, pending.date <= last {
            let cadence = try nextSlot(after: last, config: state.config)
            return WorkoutSlot(date: cadence.date, slotID: pending.slotID)
        }
        return pending
    }

    static func validateExposure(slot: WorkoutSlot, state: ProgramState) throws {
        if state.schedulingPolicy == .flexibleV1 {
            guard state.config.weeklySlots.contains(where: { $0.id == slot.slotID }) else {
                throw EngineError(code: "invalid_slot", field: "slotId")
            }
        } else { try validate(slot: slot, config: state.config) }
    }

    private static func weekday(on date: LocalDate) throws -> Int {
        let sunday = try LocalDate(iso8601: "2026-10-04")
        return ((sunday.days(until: date) % 7) + 7) % 7
    }

    public static func nextSlot(onOrAfter date: LocalDate, config: ProgramConfig) throws -> WorkoutSlot {
        guard config.weeklySlots.count == config.daysPerWeek,
              Set(config.weeklySlots.map(\.id)).count == config.daysPerWeek,
              config.weeklySlots.allSatisfy({ (0...6).contains($0.weekday ?? -1) }),
              Set(config.weeklySlots.compactMap(\.weekday)).count == config.daysPerWeek else {
            throw EngineError(code: "invalid_schedule", field: "weeklySlots")
        }
        // Registered starter metadata stays frozen even if coveragePolicy is altered.
        if config.profileID == "starter-upper-v1" || config.profileID == "starter-glute-v1" {
            try StarterProgramCatalog.validateProjection(config)
        } else if config.coveragePolicy == "fixed_profile" {
            if config.profileID == "fixed-home-gym-v0.2" {
                guard try CanonicalJSON.sha256(fixedMetadataContent(config: config)) == RulesetCatalog.fixedMetadataProjectionHash else {
                    throw EngineError(code: "fixed_profile_mismatch", field: "weeklySlots")
                }
            } else {
                try StarterProgramCatalog.validateProjection(config)
            }
        }
        for offset in 0...6 {
            let candidate = try date.adding(days: offset)
            let weekday = try weekday(on: candidate)
            if let slot = config.weeklySlots.first(where: { $0.weekday == weekday }) {
                return WorkoutSlot(date: candidate, slotID: slot.id)
            }
        }
        throw EngineError(code: "invalid_schedule", field: "weeklySlots")
    }
}

/// Caller journals .reschedule; O6 must invalidate the old empty draft and reject
/// drafts with working sets, actuals or problems. This core has no draft storage.
public func reschedulePendingWorkout(state: ProgramState, slot: WorkoutSlot, rules: Ruleset) throws -> ConfigurationResult {
    try validateConfigurationInput(state: state, rules: rules, slot: slot)
    guard slot.date != state.activePrescription.date || slot.slotID != state.activePrescription.slotID else {
        return unchangedConfiguration(state)
    }
    let policy = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
    let decision = try configurationDecision(id: nil, action: .notice, ruleIDs: policy.usesExactTargets ? ["X12"] : [], key: "workout_rescheduled",
        before: state.activePrescription, after: slot, ruleset: policy.usesExactTargets ? rules : nil)
    return try finishConfiguration(original: state, updated: state, rules: rules, slot: slot, decisions: [decision])
}

/// Explicit .interruption(asOf:) adapter command. No hidden current-date lookup in
/// preparation or progression, and no invented completed workout/event.
public func prepareInterruptedReturn(state: ProgramState, asOf: LocalDate, rules: Ruleset) throws -> ConfigurationResult {
    try validateConfigurationState(state: state, rules: rules)
    if let last = state.lastSessionDate, asOf < last { throw EngineError(code: "backdated_date", field: "asOf") }
    var updated = state
    var decisions: [Decision] = []
    let ids = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules).usesVariants ? state.config.activeVariantIDs!.values.sorted() : state.exercises.keys.sorted()
    for id in ids {
        if let decision = try markInterruptedReturn(state: &updated, id: id, asOf: asOf, rules: rules) { decisions.append(decision) }
    }
    guard !decisions.isEmpty else { return unchangedConfiguration(state) }
    return try finishConfiguration(original: state, updated: updated, rules: rules,
        slot: WorkoutSlot(date: state.activePrescription.date, slotID: state.activePrescription.slotID), decisions: decisions)
}

func markInterruptedReturn(state: inout ProgramState, id: String, asOf: LocalDate, rules: Ruleset) throws -> Decision? {
    if state.schemaVersion == 4 {
        return try markStarterInterruptedReturn(state: &state, variantID: id, asOf: asOf, rules: rules)
    }
    let before = state.exercises[id]!
    let policy = try ProgramPolicy.resolve(schemaVersion: state.schemaVersion, rules: rules)
    if policy.usesExactTargets {
        let base = state.config.variants![id]!.baseMovementID
        guard before.mode != .paused, state.baseSafety![base]!.paused != true,
              before.exactRepState?.setupReviewRequired != true else { return nil }
        var after = before
        guard let last = before.exactRepState!.lastSuitableNormalDate else {
            guard before.mode != .baseline else { return nil }
            seedExactBaseline(&after)
            state.exercises[id] = after
            return try exactDecision(id: id, action: .baseline, rule: "X03", key: "no_capacity_evidence",
                before: before, after: after, rules: rules)
        }
        guard asOf >= last else { throw EngineError(code: "backdated_date", field: "asOf") }
        guard !before.interruptedReturn, last.days(until: asOf) >= (try rules.resolvedParameters.interruptionDays) else { return nil }
        let movement = state.config.movements.first { $0.id == base }!
        try beginExactInterruptedReturn(&after, movement: movement, rules: rules)
        state.exercises[id] = after
        return try exactDecision(id: id, action: .recover, rule: "X08", key: "interruption_return",
            before: before, after: after, rules: rules)
    }
    guard let last = before.lastCompletedDate else { return nil }
    guard asOf >= last else { throw EngineError(code: "backdated_date", field: "asOf") }
    guard !before.interruptedReturn, last.days(until: asOf) >= (try rules.resolvedParameters.interruptionDays) else { return nil }
    let base = state.config.variants?[id]?.baseMovementID ?? id
    // Safety is checked before interruption policy, as it is during advancement.
    guard before.mode != .paused, state.baseSafety?[base]?.paused != true else { return nil }
    var after = before
    beginInterruptedReturn(&after)
    state.exercises[id] = after
    return try configurationDecision(id: id, action: .recover, ruleIDs: ["R05"], key: "interruption_return", before: before, after: after)
}

/// Journaled activation changes scheduling only. Never reconstruct missed slots
/// or replace the pending issued prescription; the repository disallows drafts.
public func activateFlexibleScheduling(state: ProgramState, rules: Ruleset) throws -> ConfigurationResult {
    try validateConfigurationState(state: state, rules: rules)
    guard [2, 3, 4].contains(state.schemaVersion) else {
        throw EngineError(code: "unsupported_scheduling", field: "schemaVersion")
    }
    guard state.schedulingPolicy == nil else { return unchangedConfiguration(state) }
    var updated = state
    updated.schedulingPolicy = .flexibleV1
    let (revision, overflow) = state.revision.addingReportingOverflow(1)
    guard !overflow else { throw EngineError(code: "invalid_state", field: "revision") }
    updated.revision = revision
    return ConfigurationResult(state: updated, workout: updated.activePrescription, decisions: [])
}


/// Shared scheduling admission preserves archived date guards verbatim. Flexible
/// inputs must bind real timing and the exact next cadence/rotation deterministically.
func validateCompletionDates(_ input: AdvanceInput) throws {
    let state = input.state, event = input.event, planned = state.activePrescription
    guard !event.eventID.isEmpty,
          state.lastSessionDate == nil || event.date > state.lastSessionDate!,
          input.nextWorkoutDate > event.date else { throw EngineError(code: "invalid_date", field: "date") }
    if state.schedulingPolicy == .flexibleV1 {
        guard let timing = event.timing else { throw EngineError(code: "invalid_session_timing", field: "timing") }
        let finishedDate = try timing.validate(sessionDate: event.date, plannedDate: planned.date)
        let next = try WorkoutScheduler.nextRotation(after: max(planned.date, finishedDate), consumedSlotID: planned.slotID, config: state.config)
        guard next.date == input.nextWorkoutDate, next.slotID == input.nextSlotID else {
            throw EngineError(code: "invalid_rotation", field: "next")
        }
    } else {
        guard event.date == planned.date, event.timing == nil else { throw EngineError(code: "invalid_date", field: "date") }
    }
}

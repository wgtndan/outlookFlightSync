import CalendarSyncCore
import Foundation

enum RuleSummaryStatus: Equatable {
    case automatic, manual, needsReview, setupNeeded, calendarUnavailable
    case accessNeeded, recoveryPaused, storageUnavailable

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .manual: "Manual"
        case .needsReview: "Needs review"
        case .setupNeeded: "Setup needed"
        case .calendarUnavailable: "Calendar unavailable"
        case .accessNeeded: "Access needed"
        case .recoveryPaused: "Recovery paused"
        case .storageUnavailable: "History unavailable"
        }
    }

    var needsAttention: Bool { self != .automatic && self != .manual }
}

/// A read-only view of saved settings and the app's already-loaded calendar list.
/// Counts describe local mappings, not a fresh inventory of provider events.
struct RuleSummary: Identifiable {
    var id: UUID
    var name: String
    var preset: RulePreset
    var presetTitle: String { preset.title }
    var sourceLabel: String
    var destinationLabel: String
    var sourceAvailable: Bool
    var destinationAvailable: Bool
    var conditions: [String]
    var matchDescription: String
    var copyDescription: String
    var coverageDescription: String
    var status: RuleSummaryStatus
    var statusDetail: String
    var automaticConfigured: Bool
    var trackedCopyCount: Int
    var lastRun: RunRecord?

    static func make(
        rule: SyncRule, calendars: [CalendarDescriptor], mappings: [SyncMapping],
        runs: [RunRecord], hasAccess: Bool, isDemo: Bool = false,
        storageAvailable: Bool = true, configurationApproved: Bool = false,
        pendingRecovery: Bool = false, previewChanges: [PlannedChange]? = nil
    ) -> RuleSummary {
        let canSeeCalendars = hasAccess || isDemo
        let source = canSeeCalendars ? calendars.first { $0.id == rule.sourceCalendarID } : nil
        let destination = canSeeCalendars ? calendars.first { $0.id == rule.destinationCalendarID } : nil
        // Older runs contain only a name, which can be renamed or reused. Keep
        // those in global activity rather than attributing them to a rule.
        let lastRun = isDemo ? nil : runs.filter { $0.ruleID == rule.id }.max { $0.date < $1.date }
        let reviewedChanges = previewChanges?.filter { $0.ruleID == rule.id }
        let validation = RuleEngine.validationErrors(for: rule)
        let status: RuleSummaryStatus
        let detail: String

        if !validation.isEmpty {
            status = .setupNeeded
            detail = validation.joined(separator: " ")
        } else if !canSeeCalendars {
            status = .accessNeeded
            detail = "Allow Calendar access to check these calendars and sync events."
        } else if source == nil || destination == nil {
            status = .calendarUnavailable
            detail = "A selected calendar is unavailable. Open the rule to choose an available calendar."
        } else if destination?.writable != true {
            status = .setupNeeded
            detail = "The destination is read-only. Choose a writable destination calendar."
        } else if !isDemo && !storageAvailable {
            status = .storageUnavailable
            detail = "Local sync history is unavailable. Syncing is paused to prevent duplicate copies."
        } else if !isDemo && pendingRecovery {
            status = .recoveryPaused
            detail = "An interrupted run pauses automatic syncing for all rules. Review a fresh preview to recover safely."
        } else if let conflict = reviewedChanges?.first(where: { $0.kind == .conflict }) {
            status = .needsReview
            detail = "The last preview needs attention: \(conflict.reason)"
        } else if reviewedChanges?.contains(where: { $0.kind == .remove && $0.requiresReview }) == true {
            status = .needsReview
            detail = "The last preview contains removals that need manual review."
        } else if lastRun?.succeeded == false {
            status = .needsReview
            detail = "The last sync attempt reported a problem. Open the rule and test again to check its current state."
        } else if !isDemo && !configurationApproved {
            status = .needsReview
            detail = "Manual syncing is available. Review and apply or confirm a full preview before enabling automatic syncing."
        } else if rule.automatic && !isDemo {
            status = .automatic
            detail = "Checks every 5 minutes while the app runs, and after your Mac wakes. Removals need manual review."
        } else {
            status = .manual
            detail = isDemo ? "Sample rule. Test a preview without changing real calendars."
                : "Syncs when you review and apply a preview. Automatic syncing is off."
        }

        return RuleSummary(
            id: rule.id, name: rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled rule" : rule.name,
            preset: rule.preset,
            sourceLabel: calendarLabel(source, selectedID: rule.sourceCalendarID, hasAccess: canSeeCalendars),
            destinationLabel: calendarLabel(destination, selectedID: rule.destinationCalendarID, hasAccess: canSeeCalendars),
            sourceAvailable: source != nil, destinationAvailable: destination != nil,
            conditions: rule.conditions.map { "\($0.field.rawValue.capitalized) \($0.operation.title) “\($0.value)”" },
            matchDescription: rule.conditions.isEmpty ? "All eligible events"
                : "Match \(rule.matchMode == .all ? "all" : "any") conditions · case-insensitive",
            copyDescription: rule.preset == .family
                ? "Copies as “Family Commitment”, marked busy. Original title, location and notes are omitted."
                : "Copies title, time, location and notes. Attendees and reminders are omitted.",
            coverageDescription: "Past \(rule.pastDays) days · next \(rule.futureDays) days",
            status: status, statusDetail: detail, automaticConfigured: rule.automatic,
            trackedCopyCount: isDemo ? 0 : mappings.filter { $0.ruleID == rule.id }.count,
            lastRun: isDemo ? nil : lastRun
        )
    }

    private static func calendarLabel(_ calendar: CalendarDescriptor?, selectedID: String, hasAccess: Bool) -> String {
        if let calendar { return calendar.label }
        if selectedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Not selected" }
        return hasAccess ? "Calendar unavailable" : "Calendar access needed"
    }
}

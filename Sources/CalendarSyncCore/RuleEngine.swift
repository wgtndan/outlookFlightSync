import Foundation

public extension SyncRule {
    static func makePreset(_ preset: RulePreset) -> SyncRule {
        switch preset {
        case .flights:
            SyncRule(name: preset.title, preset: preset, conditions: [
                RuleCondition(field: .title, operation: .startsWith, value: "Flight for "),
                RuleCondition(field: .title, operation: .contains, value: "Airline Confirmation Code:")
            ], matchMode: .all)
        case .family:
            SyncRule(name: preset.title, preset: preset)
        case .custom:
            SyncRule(name: preset.title, preset: preset, conditions: [RuleCondition()])
        }
    }
}

public enum RuleEngine {
    /// Keep source records visible for testing, but mark known destination copies as ineligible.
    /// The persisted mapping still proves ownership when a user removes the URL marker.
    public static func excludeManagedCopies(_ events: [EventSnapshot], mappings: [SyncMapping]) -> [EventSnapshot] {
        var knownCopies: [CalendarEventIdentity: OwnershipMarker] = [:]
        for mapping in mappings {
            let identity = CalendarEventIdentity(calendarID: mapping.destinationCalendarID, eventID: mapping.destinationEventID)
            if knownCopies[identity] == nil {
                knownCopies[identity] = OwnershipMarker(ruleID: mapping.ruleID, sourceKey: mapping.sourceKey)
            }
        }
        return events.map { event in
            guard event.ownership == nil,
                  let marker = knownCopies[CalendarEventIdentity(calendarID: event.calendarID, eventID: event.id)] else { return event }
            var excluded = event
            excluded.ownership = marker
            return excluded
        }
    }

    /// Configuration errors that should prevent enabling or applying a rule.
    public static func validationErrors(for rule: SyncRule) -> [String] {
        var errors = conditionErrors(for: rule)
        if rule.sourceCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Choose a source calendar.")
        }
        if rule.destinationCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Choose a destination calendar.")
        }
        if !rule.sourceCalendarID.isEmpty, rule.sourceCalendarID == rule.destinationCalendarID {
            errors.append("Source and destination calendars must be different.")
        }
        if !(0...365).contains(rule.pastDays) || !(1...730).contains(rule.futureDays) {
            errors.append("Choose 0–365 past days and 1–730 future days.")
        }
        return errors
    }

    public static func evaluate(event: EventSnapshot, rule: SyncRule) -> MatchResult {
        // A copy made by any rule is ineligible, preventing loops between calendar pairs.
        if event.ownership != nil {
            return MatchResult(matches: false, reason: "Excluded: this event is already a managed copy.")
        }
        if event.isCancelled {
            return MatchResult(matches: false, reason: "Excluded: this event is cancelled.")
        }
        let errors = conditionErrors(for: rule)
        if !errors.isEmpty {
            return MatchResult(matches: false, reason: errors.joined(separator: " "))
        }
        if rule.conditions.isEmpty {
            return MatchResult(matches: true, reason: "Matches all eligible events.")
        }

        let results = rule.conditions.map { condition in
            let value: String
            switch condition.field {
            case .title: value = event.title
            case .location: value = event.location ?? ""
            case .notes: value = event.notes ?? ""
            }
            let locale = Locale(identifier: "en_US_POSIX")
            switch condition.operation {
            case .contains:
                return value.range(of: condition.value, options: .caseInsensitive, locale: locale) != nil
            case .startsWith:
                return value.range(of: condition.value, options: [.caseInsensitive, .anchored], locale: locale) != nil
            case .equals:
                return value.compare(condition.value, options: .caseInsensitive, locale: locale) == .orderedSame
            case .doesNotContain:
                return value.range(of: condition.value, options: .caseInsensitive, locale: locale) == nil
            }
        }
        let matches = rule.matchMode == .all ? results.allSatisfy { $0 } : results.contains(true)
        let count = results.filter { $0 }.count
        return MatchResult(matches: matches, reason: "\(count) of \(results.count) conditions matched (\(rule.matchMode.rawValue)).")
    }

    public static func payload(event: EventSnapshot, rule: SyncRule) -> CopyPayload {
        let family = rule.preset == .family
        return CopyPayload(
            title: family ? "Family Commitment" : event.title,
            start: event.start, end: event.end,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZoneIdentifier,
            location: family ? nil : event.location,
            busy: family || event.busy,
            notes: family ? nil : event.notes
        )
    }

    private static func conditionErrors(for rule: SyncRule) -> [String] {
        rule.conditions.enumerated().compactMap { index, condition in
            condition.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Condition \(index + 1) needs a nonempty value." : nil
        }
    }

    private struct CalendarEventIdentity: Hashable {
        var calendarID: String
        var eventID: String
    }
}

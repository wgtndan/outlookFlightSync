import Foundation
import CalendarSyncCore

enum Fixtures {
    static let start = date("2026-10-03T22:30:00Z")
    static let end = date("2026-10-04T02:30:00Z")
    static let window = DateInterval(start: date("2026-10-01T00:00:00Z"), end: date("2026-11-01T00:00:00Z"))
    static let flightTitle = "Flight for Alex Example — VX123 — Airline Confirmation Code: ZX9Q2"

    static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    static func rule(_ preset: RulePreset = .flights) -> SyncRule {
        var rule = SyncRule.makePreset(preset)
        rule.sourceCalendarID = "source-calendar"
        rule.destinationCalendarID = "destination-calendar"
        return rule
    }

    static func source(key: String = "occurrence-1", id: String = "source-event-1", title: String = flightTitle) -> EventSnapshot {
        EventSnapshot(id: id, sourceKey: key, calendarID: "source-calendar", title: title,
                      start: start, end: end, timeZoneIdentifier: "Australia/Melbourne",
                      location: "Example Airport", notes: "Private booking information")
    }

    static func destination(source: EventSnapshot, rule: SyncRule, id: String = "destination-event-1") -> EventSnapshot {
        let payload = RuleEngine.payload(event: source, rule: rule)
        return EventSnapshot(id: id, sourceKey: "destination-\(id)", calendarID: rule.destinationCalendarID,
                             title: payload.title, start: payload.start, end: payload.end,
                             isAllDay: payload.isAllDay, timeZoneIdentifier: payload.timeZoneIdentifier,
                             location: payload.location, notes: payload.notes,
                             ownership: OwnershipMarker(ruleID: rule.id, sourceKey: source.sourceKey), busy: payload.busy)
    }

    static func mapping(source: EventSnapshot, destination: EventSnapshot, rule: SyncRule) -> SyncMapping {
        SyncMapping(ruleID: rule.id, sourceKey: source.sourceKey, sourceEventID: source.id,
                    destinationEventID: destination.id, sourceCalendarID: rule.sourceCalendarID,
                    destinationCalendarID: rule.destinationCalendarID,
                    lastPayload: RuleEngine.payload(event: source, rule: rule), sourceIdentityHint: source.identityHint)
    }
}

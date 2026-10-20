import Foundation

public struct CalendarDescriptor: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var sourceTitle: String
    public var writable: Bool
    public var label: String { "\(sourceTitle) — \(title)" }
    public init(id: String, title: String, sourceTitle: String, writable: Bool) {
        self.id = id; self.title = title; self.sourceTitle = sourceTitle; self.writable = writable
    }
}

public enum RulePreset: String, Codable, CaseIterable, Sendable {
    case flights, family, custom
    public var title: String {
        switch self { case .flights: "Flights"; case .family: "Family commitments"; case .custom: "Custom rule" }
    }
}
public enum MatchMode: String, Codable, CaseIterable, Sendable { case all, any }
public enum MatchField: String, Codable, CaseIterable, Sendable { case title, location, notes }
public enum MatchOperator: String, Codable, CaseIterable, Sendable {
    case contains, startsWith, equals, doesNotContain
    public var title: String {
        switch self { case .contains: "contains"; case .startsWith: "starts with"; case .equals: "equals"; case .doesNotContain: "does not contain" }
    }
}
public struct RuleCondition: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var field: MatchField
    public var operation: MatchOperator
    public var value: String
    public init(id: UUID = UUID(), field: MatchField = .title, operation: MatchOperator = .contains, value: String = "") {
        self.id = id; self.field = field; self.operation = operation; self.value = value
    }
}
public struct SyncRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var preset: RulePreset
    public var sourceCalendarID: String
    public var destinationCalendarID: String
    public var conditions: [RuleCondition]
    public var matchMode: MatchMode
    public var automatic: Bool
    /// Nil preserves manual removal review for rules saved before this option existed.
    public var syncDeletions: Bool?
    public var pastDays: Int
    public var futureDays: Int
    public init(id: UUID = UUID(), name: String, preset: RulePreset, sourceCalendarID: String = "", destinationCalendarID: String = "", conditions: [RuleCondition] = [], matchMode: MatchMode = .all, automatic: Bool = false, pastDays: Int = 7, futureDays: Int = 180) {
        self.id = id; self.name = name; self.preset = preset
        self.sourceCalendarID = sourceCalendarID; self.destinationCalendarID = destinationCalendarID
        self.conditions = conditions; self.matchMode = matchMode; self.automatic = automatic
        self.pastDays = pastDays; self.futureDays = futureDays
    }
}

public struct OwnershipMarker: Codable, Equatable, Hashable, Sendable {
    public var ruleID: UUID
    public var sourceKey: String
    public init(ruleID: UUID, sourceKey: String) { self.ruleID = ruleID; self.sourceKey = sourceKey }
}
public struct EventSnapshot: Equatable, Sendable, Identifiable {
    public var id: String
    public var sourceKey: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZoneIdentifier: String?
    public var location: String?
    public var notes: String?
    public var ownership: OwnershipMarker?
    public var isCancelled: Bool
    public var busy: Bool
    /// A provider identity independent of sourceKey, scoped to this occurrence when recurring.
    public var identityHint: String?
    public var canManageAsCopy: Bool
    public init(id: String, sourceKey: String, calendarID: String, title: String, start: Date, end: Date, isAllDay: Bool = false, timeZoneIdentifier: String? = nil, location: String? = nil, notes: String? = nil, ownership: OwnershipMarker? = nil, isCancelled: Bool = false, busy: Bool = true, identityHint: String? = nil, canManageAsCopy: Bool = true) {
        self.id = id; self.sourceKey = sourceKey; self.calendarID = calendarID; self.title = title
        self.start = start; self.end = end; self.isAllDay = isAllDay; self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location; self.notes = notes; self.ownership = ownership; self.isCancelled = isCancelled; self.busy = busy
        self.identityHint = identityHint
        self.canManageAsCopy = canManageAsCopy
    }
}
public struct CopyPayload: Codable, Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZoneIdentifier: String?
    public var location: String?
    public var busy: Bool
    public var notes: String?
    public init(title: String, start: Date, end: Date, isAllDay: Bool, timeZoneIdentifier: String?, location: String?, busy: Bool, notes: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier; self.location = location; self.busy = busy
        self.notes = notes?.isEmpty == true ? nil : notes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: try values.decode(String.self, forKey: .title),
                  start: try values.decode(Date.self, forKey: .start),
                  end: try values.decode(Date.self, forKey: .end),
                  isAllDay: try values.decode(Bool.self, forKey: .isAllDay),
                  timeZoneIdentifier: try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier),
                  location: try values.decodeIfPresent(String.self, forKey: .location),
                  busy: try values.decode(Bool.self, forKey: .busy),
                  notes: try values.decodeIfPresent(String.self, forKey: .notes))
    }
}
public struct SyncMapping: Codable, Equatable, Sendable {
    public var ruleID: UUID
    public var sourceKey: String
    public var sourceEventID: String
    public var destinationEventID: String
    public var sourceCalendarID: String
    public var destinationCalendarID: String
    public var lastPayload: CopyPayload
    public var sourceIdentityHint: String?
    public init(ruleID: UUID, sourceKey: String, sourceEventID: String, destinationEventID: String, sourceCalendarID: String, destinationCalendarID: String, lastPayload: CopyPayload, sourceIdentityHint: String? = nil) {
        self.ruleID = ruleID; self.sourceKey = sourceKey; self.sourceEventID = sourceEventID
        self.destinationEventID = destinationEventID; self.sourceCalendarID = sourceCalendarID
        self.destinationCalendarID = destinationCalendarID; self.lastPayload = lastPayload
        self.sourceIdentityHint = sourceIdentityHint
    }
}
public enum ChangeKind: String, Codable, Sendable { case create, update, remove, unchanged, conflict }
public struct PlannedChange: Identifiable, Equatable, Sendable {
    public var id: String { "\(ruleID.uuidString):\(sourceKey):\(kind.rawValue)" }
    public var ruleID: UUID
    public var sourceKey: String
    public var sourceEventID: String
    public var destinationEventID: String?
    public var kind: ChangeKind
    public var payload: CopyPayload?
    public var reason: String
    public var requiresReview: Bool
    public init(ruleID: UUID, sourceKey: String, sourceEventID: String, destinationEventID: String? = nil, kind: ChangeKind, payload: CopyPayload?, reason: String, requiresReview: Bool = false) {
        self.ruleID = ruleID; self.sourceKey = sourceKey; self.sourceEventID = sourceEventID
        self.destinationEventID = destinationEventID; self.kind = kind; self.payload = payload
        self.reason = reason; self.requiresReview = requiresReview
    }
}
public struct MatchResult: Sendable, Equatable {
    public var matches: Bool
    public var reason: String
    public init(matches: Bool, reason: String) { self.matches = matches; self.reason = reason }
}
public struct TestedEvent: Identifiable, Sendable {
    public var id: String { event.sourceKey }
    public var event: EventSnapshot
    public var result: MatchResult
    public init(event: EventSnapshot, result: MatchResult) { self.event = event; self.result = result }
}

import CalendarSyncCore
import CryptoKit
import EventKit
import Foundation

/// Access to the system Calendar store, not Outlook's private account store.
/// Constructing this object never requests permission. Full access is needed to
/// select calendars and reconcile copies; write-only access is insufficient.
@MainActor
final class CalendarAccess {
    private let store = EKEventStore()
    private static let occurrencePrefix = "ek-occurrence-v1:"
    private static let unresolvablePrefix = "ek-occurrence-v1:unresolvable:"

    var authorizationGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async throws -> Bool {
        // Start the request on the main actor. Older SDK async overlays send
        // the non-Sendable event store across an isolation boundary.
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func calendars() -> [CalendarDescriptor] {
        guard authorizationGranted else { return [] }
        return store.calendars(for: .event).map {
            CalendarDescriptor(id: $0.calendarIdentifier, title: $0.title,
                               sourceTitle: $0.source?.title ?? "Calendar account",
                               writable: $0.allowsContentModifications)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func events(calendarID: String, window: DateInterval) throws -> [EventSnapshot] {
        try requireAccess()
        let calendar = try calendar(withID: calendarID)
        return try fetchedEvents(in: calendar, window: window).map(snapshot)
    }

    func event(id: String) -> EventSnapshot? {
        guard authorizationGranted, let value = resolve(id: id) else { return nil }
        return snapshot(value)
    }

    /// Inspection only: a previously standalone copy may have been changed
    /// into a meeting or recurring series. Surface that object to the planner
    /// as unmanageable, instead of treating its rejected shape as deletion.
    func trackedDestination(id: String) -> EventSnapshot? {
        guard authorizationGranted, !Self.isUnresolvableReference(id) else { return nil }
        if let value = resolve(id: id) { return snapshot(value) }
        guard !Self.isRecurringReference(id),
              let value = store.event(withIdentifier: id)
                ?? (store.calendarItem(withIdentifier: id) as? EKEvent) else { return nil }
        return snapshot(value)
    }

    func diagnosticReport(rule: SyncRule, window: DateInterval, pendingKeys: Set<String>) throws -> [String] {
        try requireAccess()
        let sourceCalendar = try calendar(withID: rule.sourceCalendarID)
        let destinationCalendar = try calendar(withID: rule.destinationCalendarID)
        let sources = try fetchedEvents(in: sourceCalendar, window: window).map(snapshot)
        let destinations = try fetchedEvents(in: destinationCalendar, window: window)
        var lines: [String] = []
        for (index, key) in pendingKeys.sorted().enumerated() {
            let matchingSources = sources.filter { $0.sourceKey == key }
            let marker = OwnershipMarker(ruleID: rule.id, sourceKey: key)
            let copies = destinations.filter { Self.parseMarker($0.url) == marker }
            lines.append("Pending item \(index + 1): sources=\(matchingSources.count), marked copies=\(copies.count)")
            guard let source = matchingSources.first else { continue }
            let payload = RuleEngine.payload(event: source, rule: rule)
            for copy in copies {
                lines += [
                    "  identifier present: \(copy.eventIdentifier != nil)",
                    "  raw identifier resolves: \(copy.eventIdentifier.flatMap { store.event(withIdentifier: $0) } != nil)",
                    "  adapter resolves: \(copy.eventIdentifier.flatMap { resolve(id: $0) } != nil)",
                    "  recurrence rules: \(copy.hasRecurrenceRules), detached: \(copy.isDetached), occurrence date: \(copy.occurrenceDate != nil)",
                    "  title agrees: \((copy.title ?? "") == payload.title)",
                    "  start agrees: \(copy.startDate == payload.start), end agrees: \(copy.endDate == payload.end), all-day agrees: \(copy.isAllDay == payload.isAllDay)",
                    "  time zone: source=\(payload.timeZoneIdentifier ?? "floating"), copy=\(copy.timeZone?.identifier ?? "floating")",
                    "  location agrees: \(nonempty(copy.location) == nonempty(payload.location)), notes agree: \(nonempty(copy.notes) == nonempty(payload.notes))",
                    "  alarms: \(copy.hasAlarms), attendees: \(copy.hasAttendees)",
                    "  requested busy: \(payload.busy), availability: \(copy.availability.rawValue), supported: \(destinationCalendar.supportedEventAvailabilities.rawValue)",
                    "  strict payload agrees: \(agrees(copy, with: payload, calendar: destinationCalendar))"
                ]
            }
            if copies.isEmpty {
                let unmarked = destinations.filter { $0.url == nil && ($0.title ?? "") == payload.title && $0.startDate == payload.start && $0.endDate == payload.end }
                lines.append("  unmarked events with same title and time: \(unmarked.count) (not adopted)")
            }
        }
        return lines
    }

    /// The only mutation entry point. The coordinator must obtain a fresh plan
    /// and any required review before calling it. All mutations remain scoped to
    /// a uniquely identified, marked copy in the rule's destination calendar.
    func apply(change: PlannedChange, rule: SyncRule, window: DateInterval) throws -> SyncMapping? {
        try requireAccess()
        let validation = RuleEngine.validationErrors(for: rule)
        guard validation.isEmpty else { throw AccessError.invalidPlan(validation.joined(separator: " ")) }
        guard change.ruleID == rule.id, Self.isSourceKey(change.sourceKey) else {
            throw AccessError.invalidPlan("The preview belongs to a different rule or has an invalid event identity. Test the rule again.")
        }
        guard rule.sourceCalendarID != rule.destinationCalendarID else {
            throw AccessError.invalidPlan("Choose different source and destination calendars.")
        }
        let sourceCalendar = try calendar(withID: rule.sourceCalendarID)
        let destinationCalendar = try calendar(withID: rule.destinationCalendarID)
        guard destinationCalendar.allowsContentModifications else { throw AccessError.readOnly }

        let currentSources = try fetchedEvents(in: sourceCalendar, window: window)
            .map(snapshot).filter { $0.sourceKey == change.sourceKey }
        guard currentSources.count <= 1 else { throw AccessError.ambiguousSource }
        let marker = OwnershipMarker(ruleID: rule.id, sourceKey: change.sourceKey)

        switch change.kind {
        case .create, .update:
            guard let source = currentSources.first,
                  source.id == change.sourceEventID,
                  !Self.isUnresolvableReference(source.id),
                  source.calendarID == rule.sourceCalendarID,
                  source.ownership == nil,
                  !source.isCancelled,
                  RuleEngine.evaluate(event: source, rule: rule).matches else {
                throw AccessError.staleSource
            }
            let intended = RuleEngine.payload(event: source, rule: rule)
            guard let payload = change.payload, payload == intended else { throw AccessError.stalePayload }
            try validate(payload: payload, calendar: destinationCalendar)

            // Read the destination again, even for a create. A prior save may
            // have succeeded before the journal was written or the app exited.
            let copies = try ownedCopies(marker: marker, calendar: destinationCalendar,
                                         window: window, destinationID: change.destinationEventID)
            guard copies.count <= 1 else { throw AccessError.duplicateCopies }
            let target: EKEvent
            if let existing = copies.first {
                try validateTarget(existing, marker: marker, calendarID: rule.destinationCalendarID)
                target = existing
                if change.kind == .create {
                    // Recover a completed, unjournaled write without overwriting
                    // a copy that has subsequently been edited by the person.
                    guard agrees(existing, with: payload, calendar: destinationCalendar) else {
                        throw AccessError.recoveryConflict
                    }
                    return mapping(for: existing, source: source, payload: payload, rule: rule)
                }
            } else {
                guard change.kind == .create, change.destinationEventID == nil else {
                    throw AccessError.destinationMissing
                }
                target = EKEvent(eventStore: store)
                target.calendar = destinationCalendar
            }

            // EventKit has no public setter for Outlook's Private/sensitivity
            // flag. A redacted family copy must never be advertised as Private.
            target.title = payload.title
            target.startDate = payload.start
            target.endDate = payload.end
            target.isAllDay = payload.isAllDay
            target.timeZone = payload.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            target.structuredLocation = nil
            target.location = payload.location
            target.notes = payload.notes
            target.alarms = []
            target.recurrenceRules = nil
            target.url = Self.markerURL(marker)
            let supported = destinationCalendar.supportedEventAvailabilities
            if payload.busy, supported.contains(.busy) { target.availability = .busy }
            if !payload.busy, supported.contains(.free) { target.availability = .free }
            // New EKEvents have no attendees. Existing copies with attendees are
            // rejected by validateTarget, so this cannot send meeting updates.
            do {
                try store.save(target, span: .thisEvent, commit: true)
            } catch {
                throw AccessError.writeFailed(error.localizedDescription)
            }
            guard let savedID = target.eventIdentifier else {
                throw AccessError.verificationFailed(["event identifier"])
            }
            guard let saved = resolve(id: savedID) else {
                throw AccessError.verificationFailed(["saved event lookup"])
            }
            var mismatches = Self.copiedDetailMismatches(saved, with: payload,
                supportedAvailabilities: destinationCalendar.supportedEventAvailabilities)
            if saved.calendar.calendarIdentifier != rule.destinationCalendarID { mismatches.append("destination calendar") }
            if Self.parseMarker(saved.url) != marker { mismatches.append("ownership marker") }
            guard mismatches.isEmpty else { throw AccessError.verificationFailed(mismatches) }
            return mapping(for: saved, source: source, payload: payload, rule: rule)

        case .remove:
            // An unresolved recurring reference is not evidence of deletion:
            // EventKit's identifier lookup can return another occurrence, and
            // a moved occurrence may lie outside all bounded lookup hints.
            let source = currentSources.first ?? resolve(id: change.sourceEventID).map(snapshot)
            if source == nil, Self.isRecurringReference(change.sourceEventID) {
                throw AccessError.unresolvedSource
            }
            if let source {
                guard source.calendarID == rule.sourceCalendarID,
                      source.sourceKey == change.sourceKey else { throw AccessError.staleSource }
                // Preserve history outside the active window, including a
                // source that has since been cancelled or stopped matching.
                let overlapsWindow = source.start == source.end
                    ? source.start >= window.start && source.start < window.end
                    : source.start < window.end && source.end > window.start
                guard overlapsWindow else {
                    throw AccessError.sourceOutsideWindow
                }
                if RuleEngine.evaluate(event: source, rule: rule).matches {
                    throw AccessError.staleSource
                }
            }
            guard change.destinationEventID != nil else {
                throw AccessError.invalidPlan("This deletion has no destination identity. Test the rule again.")
            }
            let copies = try ownedCopies(marker: marker, calendar: destinationCalendar,
                                         window: window, destinationID: change.destinationEventID)
            guard copies.count <= 1 else { throw AccessError.duplicateCopies }
            guard let target = copies.first else { throw AccessError.destinationMissing }
            try validateTarget(target, marker: marker, calendarID: rule.destinationCalendarID)
            do {
                try store.remove(target, span: .thisEvent, commit: true)
            } catch {
                throw AccessError.writeFailed(error.localizedDescription)
            }
            return nil

        case .unchanged, .conflict:
            throw AccessError.invalidPlan("This preview entry is not an approved calendar change. Test the rule again.")
        }
    }

    static func markerURL(_ marker: OwnershipMarker) -> URL? {
        guard isSourceKey(marker.sourceKey) else { return nil }
        return URL(string: "calendarsync://copy/v1/\(marker.ruleID.uuidString.lowercased())/\(marker.sourceKey)")
    }

    static func parseMarker(_ url: URL?) -> OwnershipMarker? {
        guard let url, url.scheme?.lowercased() == "calendarsync",
              url.host?.lowercased() == "copy", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let pieces = url.pathComponents.filter { $0 != "/" }
        guard pieces.count == 3, pieces[0] == "v1",
              let ruleID = UUID(uuidString: pieces[1]), isSourceKey(pieces[2]) else { return nil }
        return OwnershipMarker(ruleID: ruleID, sourceKey: pieces[2])
    }

    static func isRecurringReference(_ id: String) -> Bool {
        // Recognize the legacy error sentinel as uncertain as well. Never
        // convert an unresolvable occurrence into an apparent source deletion.
        id.hasPrefix(occurrencePrefix) || id == "unresolvable-occurrence"
    }

    private static func isUnresolvableReference(_ id: String) -> Bool {
        id.isEmpty || id.hasPrefix(unresolvablePrefix) || id == "unresolvable-occurrence"
    }

    private static func isSourceKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func requireAccess() throws {
        guard authorizationGranted else { throw AccessError.permissionRequired }
    }

    private func calendar(withID id: String) throws -> EKCalendar {
        guard !id.isEmpty, let calendar = store.calendar(withIdentifier: id) else {
            throw AccessError.calendarMissing
        }
        return calendar
    }

    private func fetchedEvents(in calendar: EKCalendar, window: DateInterval) throws -> [EKEvent] {
        // EventKit limits a single date predicate to four years. Never accept an
        // accidentally unbounded query or silently truncated reconciliation.
        guard window.duration > 0, window.duration <= 4 * 365 * 24 * 60 * 60,
              window.start.timeIntervalSince1970.isFinite,
              window.end.timeIntervalSince1970.isFinite else { throw AccessError.invalidWindow }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end,
                                                calendars: [calendar])
        return store.events(matching: predicate).filter { $0.calendar.calendarIdentifier == calendar.calendarIdentifier }
    }

    private func snapshot(_ event: EKEvent) -> EventSnapshot {
        EventSnapshot(id: reference(for: event), sourceKey: sourceKey(for: event),
                      calendarID: event.calendar.calendarIdentifier, title: event.title ?? "",
                      start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                      timeZoneIdentifier: event.timeZone?.identifier,
                      location: nonempty(event.location), notes: nonempty(event.notes),
                      ownership: Self.parseMarker(event.url), isCancelled: event.status == .canceled,
                      busy: event.availability != .free, identityHint: identityHint(for: event),
                      canManageAsCopy: Self.canManageAsCopy(event))
    }

    private func sourceKey(for event: EKEvent) -> String {
        let external = nonempty(event.calendarItemExternalIdentifier)
        let identity = external ?? event.calendarItemIdentifier
        let parts = ["v1", event.calendar.calendarIdentifier, external == nil ? "local" : "external",
                     identity, occurrenceIdentity(for: event)]
        return identityHash(parts)
    }

    private func identityHint(for event: EKEvent) -> String? {
        guard !event.calendarItemIdentifier.isEmpty else { return nil }
        // Deliberately independent of external identifier availability and the
        // editable all-day flag. This is a migration warning, not a substitute
        // for the externally stable source key after an EventKit store reset.
        return identityHash(["hint-v1", event.calendar.calendarIdentifier,
                             event.calendarItemIdentifier, Self.identityHintOccurrence(event)])
    }

    private func identityHash(_ parts: [String]) -> String {
        let input = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func occurrenceIdentity(for event: EKEvent) -> String {
        guard let original = event.occurrenceDate else { return "single" }
        if event.isAllDay || event.timeZone == nil {
            // EventKit represents floating occurrence dates in the system zone.
            // Hash their civil date so travelling does not rename an occurrence.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: original)
            let date = "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
            if event.isAllDay { return "date:\(date)" }
            return "floating:\(date)T\(components.hour ?? 0):\(components.minute ?? 0):\(components.second ?? 0)"
        }
        return "instant:\(original.timeIntervalSince1970.bitPattern)"
    }

    private struct OccurrenceReference: Codable {
        var calendarID: String
        var eventID: String
        var itemID: String
        var sourceKey: String
        var start: Date
        var end: Date
        var originalDate: Date
    }

    private func reference(for event: EKEvent) -> String {
        if !Self.isRecurring(event) {
            return nonempty(event.eventIdentifier) ?? nonempty(event.calendarItemIdentifier)
                ?? (Self.unresolvablePrefix + sourceKey(for: event))
        }
        guard let originalDate = event.occurrenceDate else {
            return Self.unresolvablePrefix + sourceKey(for: event)
        }
        let value = OccurrenceReference(calendarID: event.calendar.calendarIdentifier,
                                        eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
                                        itemID: event.calendarItemIdentifier, sourceKey: sourceKey(for: event),
                                        start: event.startDate, end: event.endDate, originalDate: originalDate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(value) else {
            return Self.unresolvablePrefix + sourceKey(for: event)
        }
        return Self.occurrencePrefix + data.base64EncodedString()
    }

    private func resolve(id: String) -> EKEvent? {
        guard !Self.isUnresolvableReference(id) else { return nil }
        if id.hasPrefix(Self.occurrencePrefix) {
            guard let data = Data(base64Encoded: String(id.dropFirst(Self.occurrencePrefix.count))),
                  let value = try? JSONDecoder().decode(OccurrenceReference.self, from: data),
                  let calendar = store.calendar(withIdentifier: value.calendarID) else { return nil }
            // An ID-only EventKit lookup can return a series' first occurrence.
            // Enumerate bounded hints and require the exact original occurrence
            // identity; returning nil is safer than returning the series master.
            // Earlier app versions also encoded standalone events because they
            // have occurrenceDate too. Retain exact-key recovery for those IDs.
            let windows = [DateInterval(start: value.start.addingTimeInterval(-86_400),
                                        end: max(value.end, value.start).addingTimeInterval(86_400)),
                           DateInterval(start: value.originalDate.addingTimeInterval(-86_400),
                                        end: value.originalDate.addingTimeInterval(86_400))]
            var found: [String: EKEvent] = [:]
            let direct = store.event(withIdentifier: value.eventID)
                ?? (store.calendarItem(withIdentifier: value.itemID) as? EKEvent)
            if let direct, direct.calendar.calendarIdentifier == value.calendarID,
               direct.occurrenceDate != nil, sourceKey(for: direct) == value.sourceKey {
                found[reference(for: direct)] = direct
            }
            for window in windows {
                for candidate in (try? fetchedEvents(in: calendar, window: window)) ?? []
                    where candidate.occurrenceDate != nil && sourceKey(for: candidate) == value.sourceKey {
                    found[reference(for: candidate)] = candidate
                }
            }
            return found.count == 1 ? found.values.first : nil
        }
        let candidate = store.event(withIdentifier: id) ?? (store.calendarItem(withIdentifier: id) as? EKEvent)
        guard let candidate, !Self.isRecurring(candidate) else { return nil }
        return candidate
    }

    private func ownedCopies(marker: OwnershipMarker, calendar: EKCalendar, window: DateInterval,
                             destinationID: String?) throws -> [EKEvent] {
        var candidates = try fetchedEvents(in: calendar, window: window)
            .filter { Self.parseMarker($0.url) == marker }
        if let destinationID, let identified = resolve(id: destinationID) {
            // Never follow a stale identifier into an unowned event, a different
            // rule, or a different calendar, even if another marked copy exists.
            try validateTarget(identified, marker: marker, calendarID: calendar.calendarIdentifier)
            if !candidates.contains(where: { reference(for: $0) == reference(for: identified) }) {
                candidates.append(identified)
            }
        }
        return candidates
    }

    private func validateTarget(_ event: EKEvent, marker: OwnershipMarker, calendarID: String) throws {
        guard event.refresh(), event.calendar.calendarIdentifier == calendarID,
              Self.parseMarker(event.url) == marker else { throw AccessError.ownershipChanged }
        guard event.calendar.allowsContentModifications else { throw AccessError.readOnly }
        guard Self.canManageAsCopy(event) else { throw AccessError.changedDestination }
    }

    private func validate(payload: CopyPayload, calendar: EKCalendar) throws {
        guard payload.end >= payload.start, payload.start.timeIntervalSince1970.isFinite,
              payload.end.timeIntervalSince1970.isFinite else { throw AccessError.stalePayload }
        if let identifier = payload.timeZoneIdentifier, TimeZone(identifier: identifier) == nil {
            throw AccessError.invalidPlan("The source event has an unsupported time zone. Review it before syncing.")
        }
        if !payload.busy, !calendar.supportedEventAvailabilities.contains(.free) {
            throw AccessError.invalidPlan("The destination calendar cannot preserve this event's Free availability. Choose a compatible calendar.")
        }
    }

    /// EventKit supplies occurrenceDate for ordinary events once startDate is
    /// set. Recurrence rules and detached status describe recurrence explicitly.
    static func isRecurring(hasRecurrenceRules: Bool, isDetached: Bool) -> Bool {
        hasRecurrenceRules || isDetached
    }

    static func isRecurring(_ event: EKEvent) -> Bool {
        isRecurring(hasRecurrenceRules: event.hasRecurrenceRules, isDetached: event.isDetached)
    }

    static func canManageAsCopy(_ event: EKEvent) -> Bool {
        !isRecurring(event) && !event.hasAttendees
    }

    static func identityHintOccurrence(_ event: EKEvent) -> String {
        // A standalone event's occurrenceDate follows startDate. Excluding it
        // keeps the migration warning stable after a schedule change, without
        // changing the source keys already embedded in ownership markers.
        guard isRecurring(event) else { return "single" }
        return event.occurrenceDate.map { "instant:\($0.timeIntervalSince1970.bitPattern)" } ?? "single"
    }

    /// Return field labels only: error history must not contain event details.
    static func copiedDetailMismatches(_ event: EKEvent, with payload: CopyPayload,
                                      supportedAvailabilities: EKCalendarEventAvailabilityMask) -> [String] {
        func nonempty(_ value: String?) -> String? { value?.isEmpty == true ? nil : value }
        var mismatches: [String] = []
        if (event.title ?? "") != payload.title { mismatches.append("title") }
        if event.startDate != payload.start { mismatches.append("start time") }
        if event.endDate != payload.end { mismatches.append("end time") }
        if event.isAllDay != payload.isAllDay { mismatches.append("all-day setting") }
        if event.timeZone?.identifier != payload.timeZoneIdentifier { mismatches.append("time zone") }
        if nonempty(event.location) != nonempty(payload.location) { mismatches.append("location") }
        if nonempty(event.notes) != nonempty(payload.notes) {
            mismatches.append(nonempty(payload.notes) == nil ? "notes were not cleared" : "notes")
        }
        if event.hasAlarms { mismatches.append("alarms were not cleared") }
        if event.hasAttendees { mismatches.append("attendees") }
        if isRecurring(event) { mismatches.append("recurrence") }
        let availabilityAgrees = payload.busy
            ? (!supportedAvailabilities.contains(.busy) || event.availability == .busy)
            : (supportedAvailabilities.contains(.free) && event.availability == .free)
        if !availabilityAgrees { mismatches.append("availability") }
        return mismatches
    }

    private func agrees(_ event: EKEvent, with payload: CopyPayload, calendar: EKCalendar) -> Bool {
        Self.copiedDetailMismatches(event, with: payload,
            supportedAvailabilities: calendar.supportedEventAvailabilities).isEmpty
    }

    private func mapping(for event: EKEvent, source: EventSnapshot, payload: CopyPayload, rule: SyncRule) -> SyncMapping {
        SyncMapping(ruleID: rule.id, sourceKey: source.sourceKey, sourceEventID: source.id,
                    destinationEventID: reference(for: event), sourceCalendarID: rule.sourceCalendarID,
                    destinationCalendarID: rule.destinationCalendarID, lastPayload: payload,
                    sourceIdentityHint: source.identityHint)
    }

    private func nonempty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    enum AccessError: LocalizedError {
        case permissionRequired, calendarMissing, readOnly, invalidWindow, ambiguousSource
        case staleSource, stalePayload, duplicateCopies, recoveryConflict, destinationMissing
        case unresolvedSource, sourceOutsideWindow
        case ownershipChanged, changedDestination
        case verificationFailed([String])
        case invalidPlan(String), writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionRequired: "Allow full Calendar access in System Settings → Privacy & Security → Calendars, then try again."
            case .calendarMissing: "A selected calendar is unavailable or its identifier changed. Re-select both calendars and test the rule again."
            case .readOnly: "The destination calendar is read-only. Choose a writable calendar."
            case .invalidWindow: "The sync date range must be positive and shorter than four years. Adjust the rule's date range."
            case .ambiguousSource: "Several source events share this identity. No change was made; resolve the duplicates before syncing."
            case .staleSource: "The source event or rule result changed since the preview. Test the rule again before applying changes."
            case .unresolvedSource: "The original recurring occurrence could not be identified safely. Its copy was preserved; find the source occurrence and test again."
            case .sourceOutsideWindow: "The source event moved outside the sync date range. Its existing copy was preserved."
            case .stalePayload: "The source event's details changed since the preview. Test the rule again."
            case .duplicateCopies: "More than one destination event has this copy's ownership marker. Review the duplicate copies before syncing."
            case .recoveryConflict: "A previously saved copy was found, but its details differ. Review that destination event before syncing again."
            case .destinationMissing: "The expected destination copy could not be found. Test the rule again; do not recreate it until its ownership is resolved."
            case .ownershipChanged: "The destination event's calendar or ownership changed. It was left untouched; test the rule again."
            case .changedDestination: "The destination copy now repeats or has attendees. It was left untouched; review it before syncing."
            case .verificationFailed(let fields): "Calendar saved the event, but verification failed for: \(fields.joined(separator: ", ")). Inspect the destination calendar before retrying; the app will attempt to recover a marked copy."
            case .invalidPlan(let explanation): explanation
            case .writeFailed(let explanation): "Calendar could not save the change: \(explanation) Test the rule again before retrying."
            }
        }
    }
}

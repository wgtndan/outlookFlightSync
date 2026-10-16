import CalendarSyncCore
import EventKit
import Foundation
import XCTest
@testable import CalendarSyncApp

final class CalendarAccessClassificationTests: XCTestCase {
    @MainActor
    func testStandaloneOccurrenceDateDoesNotMakeEventRecurringOrUnmanageable() async throws {
        let event = makeEvent()
        // EventKit populates this even without recurrence. The former nil check
        // rejected every normal saved copy in verification and recovery.
        XCTAssertEqual(event.occurrenceDate, event.startDate)
        XCTAssertFalse(event.hasRecurrenceRules)
        XCTAssertFalse(event.isDetached)
        XCTAssertFalse(CalendarAccess.isRecurring(event))
        XCTAssertTrue(CalendarAccess.canManageAsCopy(event))
        XCTAssertEqual(CalendarAccess.copiedDetailMismatches(event, with: payload(),
            supportedAvailabilities: []), [])
    }

    @MainActor
    func testStandaloneIdentityHintRemainsStableWhenOccurrenceDateMovesWithStart() async {
        let event = makeEvent()
        let originalOccurrence = event.occurrenceDate
        let originalHint = CalendarAccess.identityHintOccurrence(event)
        event.startDate = event.startDate.addingTimeInterval(3_600)
        event.endDate = event.endDate.addingTimeInterval(3_600)
        XCTAssertNotEqual(event.occurrenceDate, originalOccurrence)
        XCTAssertEqual(CalendarAccess.identityHintOccurrence(event), originalHint)
        XCTAssertEqual(originalHint, "single")
    }

    @MainActor
    func testRealRecurrenceStillBlocksCopyManagementAndVerification() async {
        let event = makeEvent()
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)]
        XCTAssertTrue(event.hasRecurrenceRules)
        XCTAssertTrue(CalendarAccess.isRecurring(event))
        XCTAssertFalse(CalendarAccess.canManageAsCopy(event))
        XCTAssertEqual(CalendarAccess.copiedDetailMismatches(event, with: payload(),
            supportedAvailabilities: []), ["recurrence"])
    }

    @MainActor
    func testDetachedOccurrenceRemainsRecurringEvenWithoutRecurrenceRules() async {
        // isDetached is read-only. Exercise the classification explicitly
        // without creating or modifying a real recurring calendar event.
        XCTAssertTrue(CalendarAccess.isRecurring(hasRecurrenceRules: false, isDetached: true))
        XCTAssertTrue(CalendarAccess.isRecurring(hasRecurrenceRules: true, isDetached: true))
        XCTAssertFalse(CalendarAccess.isRecurring(hasRecurrenceRules: false, isDetached: false))
    }

    @MainActor
    func testVerificationRetainsContentPrivacyTimingAndAvailabilityChecks() async {
        let event = makeEvent()
        event.title = "Synthetic confidential title"
        event.startDate = event.startDate.addingTimeInterval(60)
        event.endDate = event.endDate.addingTimeInterval(120)
        event.timeZone = TimeZone(identifier: "Europe/London")
        event.location = "Synthetic confidential address"
        event.notes = "Synthetic confidential note"
        event.alarms = [EKAlarm(relativeOffset: -300)]
        event.availability = .free
        let mismatches = CalendarAccess.copiedDetailMismatches(event, with: payload(),
            supportedAvailabilities: [.busy, .free])
        XCTAssertEqual(mismatches, ["title", "start time", "end time", "time zone", "location",
            "notes were not cleared", "alarms were not cleared", "availability"])
        let error = CalendarAccess.AccessError.verificationFailed(mismatches).localizedDescription
        XCTAssertTrue(error.contains("start time"))
        XCTAssertFalse(error.contains("Synthetic confidential"))
    }

    @MainActor
    func testFloatingAndAllDayChangesRemainVerificationFailures() async {
        let event = makeEvent()
        event.timeZone = nil
        event.isAllDay = true
        let mismatches = CalendarAccess.copiedDetailMismatches(event, with: payload(),
            supportedAvailabilities: [.busy, .free])
        XCTAssertTrue(mismatches.contains("time zone"))
        XCTAssertTrue(mismatches.contains("all-day setting"))
    }

    @MainActor
    func testVerificationAcceptsExactMultilineNotes() async {
        let event = makeEvent()
        var intended = payload()
        intended.notes = "Flight itinerary\n\nDepart: Melbourne\nArrive: Sydney\nBooking: SYNTHETIC"
        event.notes = intended.notes

        XCTAssertEqual(event.notes, intended.notes)
        XCTAssertEqual(CalendarAccess.copiedDetailMismatches(event, with: intended,
            supportedAvailabilities: []), [])
    }

    @MainActor
    func testVerificationDetectsChangedOrMissingNotesWithoutLeakingContents() async {
        let event = makeEvent()
        var intended = payload()
        intended.notes = "Synthetic private booking details\nSecond line"
        for observed: String? in [nil, "Different synthetic booking", "Synthetic private booking details Second line"] {
            event.notes = observed
            let mismatches = CalendarAccess.copiedDetailMismatches(event, with: intended,
                supportedAvailabilities: [])
            XCTAssertEqual(mismatches, ["notes"])
            let error = CalendarAccess.AccessError.verificationFailed(mismatches).localizedDescription
            XCTAssertFalse(error.contains("Synthetic"))
            XCTAssertFalse(error.contains("booking"))
        }
    }

    @MainActor
    func testRedactedFamilyPayloadRequiresNotesCleared() async {
        let event = makeEvent()
        event.notes = "Synthetic family details"
        let redacted = payload()
        XCTAssertNil(redacted.notes)
        XCTAssertEqual(CalendarAccess.copiedDetailMismatches(event, with: redacted,
            supportedAvailabilities: []), ["notes were not cleared"])

        event.notes = redacted.notes
        XCTAssertEqual(CalendarAccess.copiedDetailMismatches(event, with: redacted,
            supportedAvailabilities: []), [])
        event.notes = ""
        XCTAssertEqual(CalendarAccess.copiedDetailMismatches(event, with: redacted,
            supportedAvailabilities: []), [])
    }

    @MainActor
    func testVerificationTreatsEmptyIntendedNotesAsAbsent() async {
        let event = makeEvent()
        var intended = payload()
        intended.notes = ""
        XCTAssertEqual(CalendarAccess.copiedDetailMismatches(event, with: intended,
            supportedAvailabilities: []), [])
    }

    @MainActor
    private func makeEvent() -> EKEvent {
        // Constructing these objects never requests access or reads/writes any
        // calendars. All fields below exist only on this unsaved object.
        let event = EKEvent(eventStore: EKEventStore())
        let payload = payload()
        event.title = payload.title
        event.startDate = payload.start
        event.endDate = payload.end
        event.timeZone = TimeZone(identifier: "Australia/Melbourne")
        event.isAllDay = false
        // Availability is unsupported without a real calendar, which these
        // tests deliberately never load or attach.
        return event
    }

    private func payload() -> CopyPayload {
        CopyPayload(title: "Family Commitment", start: Date(timeIntervalSince1970: 1_800_000_000),
            end: Date(timeIntervalSince1970: 1_800_003_600), isAllDay: false,
            timeZoneIdentifier: "Australia/Melbourne", location: nil, busy: true)
    }
}

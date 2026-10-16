import Foundation
import XCTest
@testable import CalendarSyncCore

final class RuleEngineTests: XCTestCase {
    func testFlightPresetMatchesDifferentNamesCarriersAndConfirmationCodes() {
        let rule = SyncRule.makePreset(.flights)
        XCTAssertEqual(rule.matchMode, .all)
        XCTAssertEqual(rule.conditions.count, 2)
        let titles = [
            Fixtures.flightTitle,
            "flight for Sam Sample - AB456 - airline confirmation code: 987XYZ",
            "FLIGHT FOR Jamie Test • Example Air • AIRLINE CONFIRMATION CODE: 123456"
        ]
        for title in titles {
            XCTAssertTrue(RuleEngine.evaluate(event: Fixtures.source(title: title), rule: rule).matches, title)
        }
    }

    func testFlightPresetRequiresBothPhrasesInTitleAndARealPrefix() {
        let rule = SyncRule.makePreset(.flights)
        for title in ["Flight for Alex Example", "Airline Confirmation Code: ZX9Q2",
                      "Reminder: \(Fixtures.flightTitle)", "Flight form Airline Confirmation Code: X",
                      "Flight for Alex Example Airline Confirmation Code X"] {
            var event = Fixtures.source(title: title)
            event.notes = Fixtures.flightTitle
            XCTAssertFalse(RuleEngine.evaluate(event: event, rule: rule).matches, title)
        }
    }

    func testFamilyPresetMatchesAllEligibleEventsAndRedactsDetails() throws {
        let rule = SyncRule.makePreset(.family)
        var event = Fixtures.source(title: "Sensitive appointment")
        event.busy = false
        XCTAssertTrue(rule.conditions.isEmpty)
        XCTAssertTrue(RuleEngine.evaluate(event: event, rule: rule).matches)
        let payload = RuleEngine.payload(event: event, rule: rule)
        XCTAssertEqual(payload.title, "Family Commitment")
        XCTAssertNil(payload.location)
        XCTAssertNil(payload.notes)
        XCTAssertTrue(payload.busy)
        XCTAssertEqual(payload.start, event.start)
        XCTAssertEqual(payload.end, event.end)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        XCTAssertFalse(encoded.contains("Sensitive appointment"))
        XCTAssertFalse(encoded.contains("Private booking information"))
        XCTAssertFalse(encoded.contains("Example Airport"))
        XCTAssertFalse(encoded.contains("notes"))
    }

    func testEveryPresetExcludesCancelledAndAnyOwnedCopy() {
        for preset in RulePreset.allCases {
            var rule = SyncRule.makePreset(preset)
            rule.conditions = []
            var event = Fixtures.source()
            event.ownership = OwnershipMarker(ruleID: UUID(), sourceKey: "another-rule-source")
            XCTAssertFalse(RuleEngine.evaluate(event: event, rule: rule).matches)
            event.ownership = nil
            event.isCancelled = true
            XCTAssertFalse(RuleEngine.evaluate(event: event, rule: rule).matches)
        }
    }

    func testFamilyOptionalConditionsUseAllAndAnyWhileRetainingPrivacy() {
        var rule = Fixtures.rule(.family)
        let event = Fixtures.source(title: "School appointment")
        XCTAssertTrue(RuleEngine.evaluate(event: event, rule: rule).matches)
        rule.conditions = [RuleCondition(value: "school"), RuleCondition(value: "dentist")]
        XCTAssertFalse(RuleEngine.evaluate(event: event, rule: rule).matches)
        rule.matchMode = .any
        XCTAssertTrue(RuleEngine.evaluate(event: event, rule: rule).matches)
        XCTAssertFalse(RuleEngine.evaluate(event: Fixtures.source(title: "Unrelated event"), rule: rule).matches)
        let payload = RuleEngine.payload(event: event, rule: rule)
        XCTAssertEqual(payload.title, "Family Commitment")
        XCTAssertNil(payload.location)
        XCTAssertNil(payload.notes)
        XCTAssertTrue(payload.busy)
    }

    func testDayRangeValidationMatchesSupportedUIBounds() {
        var rule = Fixtures.rule(.family)
        for (past, future) in [(0, 1), (365, 730), (0, 730), (365, 1)] {
            rule.pastDays = past; rule.futureDays = future
            XCTAssertTrue(RuleEngine.validationErrors(for: rule).isEmpty)
        }
        for (past, future) in [(-1, 1), (366, 1), (0, 0), (365, 0), (0, 731), (Int.max, Int.max)] {
            rule.pastDays = past; rule.futureDays = future
            XCTAssertFalse(RuleEngine.validationErrors(for: rule).isEmpty)
        }
    }

    func testCustomConditionsSupportAllAnyAndEachField() {
        var rule = Fixtures.rule(.custom)
        rule.conditions = [
            RuleCondition(field: .title, operation: .startsWith, value: "flight for "),
            RuleCondition(field: .location, operation: .equals, value: "EXAMPLE AIRPORT"),
            RuleCondition(field: .notes, operation: .contains, value: "booking"),
            RuleCondition(field: .notes, operation: .doesNotContain, value: "cancelled")
        ]
        XCTAssertTrue(RuleEngine.evaluate(event: Fixtures.source(), rule: rule).matches)
        rule.conditions.append(RuleCondition(field: .title, operation: .equals, value: "Unrelated"))
        XCTAssertFalse(RuleEngine.evaluate(event: Fixtures.source(), rule: rule).matches)
        rule.matchMode = .any
        XCTAssertTrue(RuleEngine.evaluate(event: Fixtures.source(), rule: rule).matches)
    }

    func testEmptyConditionIsInvalidEvenIfAnotherAnyConditionMatches() {
        var rule = Fixtures.rule(.custom)
        rule.matchMode = .any
        rule.conditions = [RuleCondition(value: "Flight"), RuleCondition(operation: .doesNotContain, value: " \n\t")]
        XCTAssertFalse(RuleEngine.validationErrors(for: rule).isEmpty)
        XCTAssertFalse(RuleEngine.evaluate(event: Fixtures.source(), rule: rule).matches)
    }

    func testFullValidationRejectsMissingIdenticalCalendarsAndInvalidRanges() {
        XCTAssertEqual(RuleEngine.validationErrors(for: .makePreset(.family)).count, 2)
        var rule = Fixtures.rule(.family)
        XCTAssertTrue(RuleEngine.validationErrors(for: rule).isEmpty)
        rule.destinationCalendarID = rule.sourceCalendarID
        rule.pastDays = -1
        XCTAssertEqual(RuleEngine.validationErrors(for: rule).count, 2)
        rule.destinationCalendarID = "destination-calendar"
        rule.pastDays = 0
        rule.futureDays = 0
        XCTAssertEqual(RuleEngine.validationErrors(for: rule).count, 1)
    }

    func testFlightPayloadPreservesInstantsTimeZoneAllDayStateAndAvailability() {
        var event = Fixtures.source()
        event.isAllDay = true
        event.busy = false
        let payload = RuleEngine.payload(event: event, rule: .makePreset(.flights))
        XCTAssertEqual(payload.start, event.start)
        XCTAssertEqual(payload.end, event.end)
        XCTAssertEqual(payload.end.timeIntervalSince(payload.start), 4 * 60 * 60)
        XCTAssertEqual(payload.timeZoneIdentifier, "Australia/Melbourne")
        XCTAssertTrue(payload.isAllDay)
        XCTAssertFalse(payload.busy)
        XCTAssertEqual(payload.location, event.location)
        XCTAssertEqual(payload.notes, event.notes)
    }

    func testFlightAndCustomPayloadPreserveNotesExactly() throws {
        for preset in [RulePreset.flights, .custom] {
            for notes in ["  Terminal 2\nGate 7\n\nBooking details: DEMO12\n", " \n\t "] {
                var source = Fixtures.source()
                source.notes = notes
                let payload = RuleEngine.payload(event: source, rule: .makePreset(preset))
                XCTAssertEqual(payload.notes, notes)
                XCTAssertEqual(try JSONDecoder().decode(CopyPayload.self, from: JSONEncoder().encode(payload)), payload)
            }
        }
    }

    func testEmptyNotesNormalizeToNilWithoutTrimmingMeaningfulContent() throws {
        for preset in RulePreset.allCases {
            for notes in [nil, ""] as [String?] {
                var source = Fixtures.source()
                source.notes = notes
                XCTAssertNil(RuleEngine.payload(event: source, rule: .makePreset(preset)).notes)
            }
        }
        let payload = RuleEngine.payload(event: Fixtures.source(), rule: .makePreset(.flights))
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        encoded["notes"] = ""
        let decoded = try JSONDecoder().decode(CopyPayload.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNil(decoded.notes)
    }

    func testKnownMappedCopiesRemainExcludedWhenOwnershipMarkerIsRemoved() {
        let rule = Fixtures.rule(.family)
        let original = Fixtures.source()
        var markerlessCopy = Fixtures.destination(source: original, rule: rule)
        let mapping = Fixtures.mapping(source: original, destination: markerlessCopy, rule: rule)
        markerlessCopy.ownership = nil
        var unrelated = markerlessCopy; unrelated.id = "unrelated-event"
        var differentCalendar = markerlessCopy; differentCalendar.calendarID = "another-calendar"
        var alreadyOwned = markerlessCopy
        let existingMarker = OwnershipMarker(ruleID: UUID(), sourceKey: "existing-owner")
        alreadyOwned.ownership = existingMarker

        let prepared = RuleEngine.excludeManagedCopies([markerlessCopy, unrelated, differentCalendar, alreadyOwned], mappings: [mapping])
        XCTAssertEqual(prepared.count, 4)
        XCTAssertEqual(prepared[0].ownership, OwnershipMarker(ruleID: mapping.ruleID, sourceKey: mapping.sourceKey))
        XCTAssertFalse(RuleEngine.evaluate(event: prepared[0], rule: rule).matches)
        XCTAssertNil(prepared[1].ownership)
        XCTAssertTrue(RuleEngine.evaluate(event: prepared[1], rule: rule).matches)
        XCTAssertNil(prepared[2].ownership)
        XCTAssertTrue(RuleEngine.evaluate(event: prepared[2], rule: rule).matches)
        XCTAssertEqual(prepared[3].ownership, existingMarker)
        XCTAssertNil(markerlessCopy.ownership)
    }
}

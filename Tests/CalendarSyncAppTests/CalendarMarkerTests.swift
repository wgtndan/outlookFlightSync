import CalendarSyncCore
import Foundation
import XCTest
@testable import CalendarSyncApp

final class CalendarMarkerTests: XCTestCase {
    @MainActor
    func testOwnershipMarkerRoundTripPreservesRuleAndSourceIdentity() async throws {
        let ruleID = try XCTUnwrap(UUID(uuidString: "12345678-ABCD-4321-ABCD-1234567890AB"))
        let key = String(repeating: "0123456789abcdef", count: 4)
        let marker = OwnershipMarker(ruleID: ruleID, sourceKey: key)
        let url = try XCTUnwrap(CalendarAccess.markerURL(marker))
        XCTAssertEqual(url.absoluteString, "calendarsync://copy/v1/12345678-abcd-4321-abcd-1234567890ab/\(key)")
        XCTAssertEqual(CalendarAccess.parseMarker(url), marker)
    }

    @MainActor
    func testMarkerEncodingRejectsMalformedSourceKeys() async {
        for key in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                    String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                    String(repeating: "é", count: 32), String(repeating: "0", count: 63) + "/"] {
            XCTAssertNil(CalendarAccess.markerURL(OwnershipMarker(ruleID: UUID(), sourceKey: key)), key)
        }
    }

    @MainActor
    func testMarkerParserRejectsUnrelatedOrAmbiguousURLs() async throws {
        let ruleID = UUID().uuidString.lowercased()
        let key = String(repeating: "a", count: 64)
        let path = "v1/\(ruleID)/\(key)"
        XCTAssertNil(CalendarAccess.parseMarker(nil))
        for value in [
            "https://copy/\(path)", "calendarsync://other/\(path)",
            "calendarsync://user@copy/\(path)", "calendarsync://user:password@copy/\(path)",
            "calendarsync://copy:443/\(path)", "calendarsync://copy/\(path)?extra=value",
            "calendarsync://copy/\(path)#fragment", "calendarsync://copy/v2/\(ruleID)/\(key)",
            "calendarsync://copy/v1/not-a-uuid/\(key)", "calendarsync://copy/v1/\(ruleID)",
            "calendarsync://copy/\(path)/extra", "calendarsync://copy/v1/\(ruleID)/\(key.uppercased())",
            "calendarsync://copy/v1/\(ruleID)/short"
        ] {
            let url = try XCTUnwrap(URL(string: value), value)
            XCTAssertNil(CalendarAccess.parseMarker(url), value)
        }
    }

    @MainActor
    func testRecurringReferencesIncludeUnresolvedSentinelsForSafeRecovery() async {
        for reference in ["ek-occurrence-v1:sample-encoded-reference", "ek-occurrence-v1:unresolvable:sample",
                          "unresolvable-occurrence"] {
            XCTAssertTrue(CalendarAccess.isRecurringReference(reference), reference)
        }
        for reference in ["", "ordinary-provider-event-id", "prefix-ek-occurrence-v1:sample",
                          "ek-occurrence-v2:sample", "unresolvable-occurrence-suffix"] {
            XCTAssertFalse(CalendarAccess.isRecurringReference(reference), reference)
        }
    }
}

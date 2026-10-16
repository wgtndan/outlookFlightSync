import CalendarSyncCore
import Foundation
import XCTest
@testable import CalendarSyncApp

final class RuleSummaryTests: XCTestCase {
    private let calendars = [
        CalendarDescriptor(id: "work", title: "Calendar", sourceTitle: "Work account", writable: true),
        CalendarDescriptor(id: "travel", title: "Travel", sourceTitle: "iCloud", writable: true)
    ]

    func testSummaryDescribesCalendarAccountsConditionsAndCopyBehavior() {
        let summary = makeSummary(rule())
        XCTAssertEqual(summary.sourceLabel, "Work account — Calendar")
        XCTAssertEqual(summary.destinationLabel, "iCloud — Travel")
        XCTAssertTrue(summary.sourceAvailable)
        XCTAssertTrue(summary.destinationAvailable)
        XCTAssertEqual(summary.conditions, [
            "Title starts with “Flight for ”", "Title contains “Airline Confirmation Code:”"
        ])
        XCTAssertEqual(summary.matchDescription, "Match all conditions · case-insensitive")
        XCTAssertEqual(summary.coverageDescription, "Past 7 days · next 180 days")
        XCTAssertTrue(summary.copyDescription.contains("notes"))
        XCTAssertEqual(summary.preset, .flights)
    }

    func testManualAndAutomaticRequireTheCurrentConfigurationToBeApproved() {
        var configured = rule()
        XCTAssertEqual(makeSummary(configured).status, .manual)
        configured.automatic = true
        let automatic = makeSummary(configured)
        XCTAssertEqual(automatic.status, .automatic)
        XCTAssertTrue(automatic.automaticConfigured)
        XCTAssertFalse(automatic.status.needsAttention)

        let unapproved = makeSummary(configured, approved: false)
        XCTAssertEqual(unapproved.status, .needsReview)
        XCTAssertTrue(unapproved.statusDetail.contains("Manual syncing is available"))
        XCTAssertTrue(unapproved.automaticConfigured)
        configured.automatic = false
        XCTAssertEqual(makeSummary(configured, approved: false).status, .needsReview)
    }

    func testBlankNamesHaveAReadableFallbackWithoutChangingTheRule() {
        var configured = rule()
        configured.name = " \n "
        XCTAssertEqual(makeSummary(configured).name, "Untitled rule")
        XCTAssertEqual(configured.name, " \n ")
        configured.name = "Upcoming travel"
        XCTAssertEqual(makeSummary(configured).name, "Upcoming travel")
    }

    func testMissingOrInvalidConfigurationNeedsSetup() {
        let valid = rule()
        var invalidRules: [SyncRule] = []
        var invalid = valid
        invalid.sourceCalendarID = ""
        invalidRules.append(invalid)
        invalid = valid
        invalid.destinationCalendarID = "  "
        invalidRules.append(invalid)
        invalid = valid
        invalid.destinationCalendarID = invalid.sourceCalendarID
        invalidRules.append(invalid)
        invalid = valid
        invalid.conditions[0].value = " \n "
        invalidRules.append(invalid)
        invalid = valid
        invalid.pastDays = -1
        invalidRules.append(invalid)
        invalid = valid
        invalid.futureDays = 731
        invalidRules.append(invalid)
        for candidate in invalidRules {
            let summary = makeSummary(candidate)
            XCTAssertEqual(summary.status, .setupNeeded)
            XCTAssertTrue(summary.status.needsAttention)
            XCTAssertFalse(summary.statusDetail.isEmpty)
        }
        XCTAssertEqual(makeSummary(invalidRules[0]).sourceLabel, "Not selected")
    }

    func testReadOnlyDestinationNeedsSetupButReadOnlySourceIsAllowed() {
        var readOnlySource = calendars
        readOnlySource[0].writable = false
        XCTAssertEqual(makeSummary(rule(), calendars: readOnlySource).status, .manual)
        var readOnlyDestination = calendars
        readOnlyDestination[1].writable = false
        let summary = makeSummary(rule(), calendars: readOnlyDestination)
        XCTAssertEqual(summary.status, .setupNeeded)
        XCTAssertTrue(summary.statusDetail.contains("read-only"))
    }

    func testUnavailableCalendarsAreDistinctFromMissingPermission() {
        let unavailable = makeSummary(rule(), calendars: [])
        XCTAssertEqual(unavailable.status, .calendarUnavailable)
        XCTAssertEqual(unavailable.destinationLabel, "Calendar unavailable")
        XCTAssertFalse(unavailable.destinationAvailable)

        // Even a stale loaded list must not imply the calendars remain accessible.
        let denied = makeSummary(rule(), hasAccess: false)
        XCTAssertEqual(denied.status, .accessNeeded)
        XCTAssertEqual(denied.sourceLabel, "Calendar access needed")
        XCTAssertFalse(denied.sourceAvailable)
    }

    func testInterruptedRecoveryAndMissingHistoryBlockAutomaticStatus() {
        var configured = rule()
        configured.automatic = true
        let recovering = makeSummary(configured, pendingRecovery: true)
        XCTAssertEqual(recovering.status, .recoveryPaused)
        XCTAssertTrue(recovering.automaticConfigured)
        XCTAssertTrue(recovering.statusDetail.contains("all rules"))
        XCTAssertEqual(makeSummary(configured, storageAvailable: false).status, .storageUnavailable)
    }

    func testLatestOperationUsesRuleIdentityAndDateEvenAfterRename() {
        var configured = rule()
        let oldName = configured.name
        configured.name = "Upcoming travel"
        let latest = RunRecord(date: Date(timeIntervalSince1970: 200), ruleName: oldName,
                               summary: "1 change synced.", succeeded: true, ruleID: configured.id)
        let earlier = RunRecord(date: Date(timeIntervalSince1970: 100), ruleName: oldName,
                                summary: "A past failure.", succeeded: false, ruleID: configured.id)
        let unrelated = RunRecord(date: Date(timeIntervalSince1970: 300), ruleName: configured.name,
                                  summary: "A different rule.", succeeded: false, ruleID: UUID())
        let summary = makeSummary(configured, runs: [earlier, unrelated, latest])
        XCTAssertEqual(summary.lastRun?.id, latest.id)
        XCTAssertEqual(summary.lastRun?.date, latest.date)
        XCTAssertEqual(summary.lastRun?.summary, "1 change synced.")
        XCTAssertEqual(summary.status, .manual)
    }

    func testLegacyNameOnlyRunsAreNeverAttributedToAReusedRuleName() throws {
        let configured = rule()
        let legacy = RunRecord(ruleName: configured.name, summary: "Old result", succeeded: false)
        let json = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("ruleID"))
        let decoded = try JSONDecoder().decode(RunRecord.self, from: json)
        XCTAssertNil(decoded.ruleID)
        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.summary, legacy.summary)
        XCTAssertNil(makeSummary(configured, runs: [decoded]).lastRun)
        XCTAssertEqual(makeSummary(configured, runs: [decoded]).status, .manual)
        var sameName = configured
        sameName.id = UUID()
        XCTAssertNil(makeSummary(sameName, runs: [decoded]).lastRun)
    }

    func testModernRunIdentitySurvivesCodableRoundTrip() throws {
        let run = RunRecord(ruleName: "Flights", summary: "1 change synced.", succeeded: true, ruleID: UUID())
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(decoded.ruleID, run.ruleID)
        XCTAssertEqual(decoded.id, run.id)
        XCTAssertEqual(decoded.date, run.date)
    }

    func testLatestFailureRequestsReviewWithoutClaimingTheRuleIsStillBroken() {
        let configured = rule()
        let failure = RunRecord(ruleName: configured.name, summary: "A provider problem.", succeeded: false, ruleID: configured.id)
        let summary = makeSummary(configured, runs: [failure])
        XCTAssertEqual(summary.status, .needsReview)
        XCTAssertTrue(summary.statusDetail.contains("last sync attempt"))
        XCTAssertTrue(summary.statusDetail.contains("check its current state"))
    }

    func testTrackedCopiesCountOnlyMappingsForThisRuleWithoutClaimingCurrentInventory() {
        let configured = rule()
        let mappings = [mapping(configured.id, key: "one"), mapping(configured.id, key: "two"), mapping(UUID(), key: "retired-rule")]
        XCTAssertEqual(makeSummary(configured, mappings: mappings).trackedCopyCount, 2)
        XCTAssertEqual(makeSummary(configured).trackedCopyCount, 0)
    }

    func testFamilySummaryDescribesRedactionWithoutPromisingAnOutlookPrivateFlag() {
        var configured = rule()
        configured.preset = .family
        configured.conditions = []
        let summary = makeSummary(configured)
        XCTAssertEqual(summary.matchDescription, "All eligible events")
        XCTAssertTrue(summary.conditions.isEmpty)
        XCTAssertEqual(summary.copyDescription, "Copies as “Family Commitment”, marked busy. Original title, location and notes are omitted.")
    }

    func testKnownConflictsAndRemovalsNeedReviewButOtherRulesDoNotAffectStatus() {
        let configured = rule()
        let conflict = PlannedChange(ruleID: configured.id, sourceKey: "sample", sourceEventID: "sample", kind: .conflict,
                                     payload: nil, reason: "A destination copy changed.", requiresReview: true)
        let summary = makeSummary(configured, previewChanges: [conflict])
        XCTAssertEqual(summary.status, .needsReview)
        XCTAssertTrue(summary.statusDetail.hasPrefix("The last preview"))
        var removal = conflict
        removal.kind = .remove
        XCTAssertEqual(makeSummary(configured, previewChanges: [removal]).status, .needsReview)
        removal.ruleID = UUID()
        XCTAssertEqual(makeSummary(configured, previewChanges: [removal]).status, .manual)
    }

    func testDemoDoesNotLeakSavedCountsHistoryOrPermissionProblems() {
        let configured = rule()
        let failure = RunRecord(ruleName: configured.name, summary: "Real activity", succeeded: false, ruleID: configured.id)
        let summary = makeSummary(configured, mappings: [mapping(configured.id, key: "real")], runs: [failure],
                                  hasAccess: false, isDemo: true, storageAvailable: false,
                                  approved: false, pendingRecovery: true)
        XCTAssertEqual(summary.status, .manual)
        XCTAssertEqual(summary.trackedCopyCount, 0)
        XCTAssertNil(summary.lastRun)
        XCTAssertEqual(summary.sourceLabel, "Work account — Calendar")
    }

    private func rule() -> SyncRule {
        var rule = SyncRule.makePreset(.flights)
        rule.sourceCalendarID = "work"
        rule.destinationCalendarID = "travel"
        return rule
    }

    private func makeSummary(
        _ rule: SyncRule, calendars: [CalendarDescriptor]? = nil, mappings: [SyncMapping] = [],
        runs: [RunRecord] = [], hasAccess: Bool = true, isDemo: Bool = false,
        storageAvailable: Bool = true, approved: Bool = true, pendingRecovery: Bool = false,
        previewChanges: [PlannedChange]? = nil
    ) -> RuleSummary {
        RuleSummary.make(rule: rule, calendars: calendars ?? self.calendars, mappings: mappings, runs: runs,
                         hasAccess: hasAccess, isDemo: isDemo, storageAvailable: storageAvailable,
                         configurationApproved: approved, pendingRecovery: pendingRecovery, previewChanges: previewChanges)
    }

    private func mapping(_ ruleID: UUID, key: String) -> SyncMapping {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return SyncMapping(ruleID: ruleID, sourceKey: key, sourceEventID: "source-\(key)",
                           destinationEventID: "copy-\(key)", sourceCalendarID: "work", destinationCalendarID: "travel",
                           lastPayload: CopyPayload(title: "Sample flight", start: start, end: start.addingTimeInterval(3600),
                                                    isAllDay: false, timeZoneIdentifier: nil, location: nil, busy: true))
    }
}

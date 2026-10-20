import Foundation
import XCTest
@testable import CalendarSyncCore

final class SyncPlannerTests: XCTestCase {
    func testDeletionOptInHandlesRebookingAndCancellation() throws {
        var rule = Fixtures.rule()
        let old = Fixtures.source()
        let copy = Fixtures.destination(source: old, rule: rule)
        let mapping = Fixtures.mapping(source: old, destination: copy, rule: rule)
        func plan(_ events: [EventSnapshot]) -> [PlannedChange] {
            SyncPlanner.plan(rule: rule, sourceEvents: events, destinationEvents: [copy], mappings: [mapping], window: Fixtures.window)
        }
        XCTAssertTrue(try XCTUnwrap(plan([]).first).requiresReview)
        rule.syncDeletions = true
        let replacement = Fixtures.source(key: "replacement", id: "replacement-id")
        let rebooked = plan([replacement])
        XCTAssertEqual(Set(rebooked.map(\.kind)), Set([.remove, .create]))
        XCTAssertFalse(try XCTUnwrap(rebooked.first { $0.kind == .remove }).requiresReview)
        var cancelled = old
        cancelled.isCancelled = true
        XCTAssertEqual(plan([cancelled]).first?.kind, .remove)
        XCTAssertFalse(try XCTUnwrap(plan([cancelled]).first).requiresReview)
        var renamed = old
        renamed.title = "No longer matches"
        XCTAssertTrue(try XCTUnwrap(plan([renamed]).first).requiresReview)
        let unowned = Fixtures.source(key: "unrelated", id: "unrelated")
        XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [], destinationEvents: [unowned], mappings: [], window: Fixtures.window).isEmpty)
    }

    func testLegacyRulesDecodeWithManualDeletionReview() throws {
        let data = try JSONEncoder().encode(Fixtures.rule())
        let restored = try JSONDecoder().decode(SyncRule.self, from: data)
        XCTAssertNil(restored.syncDeletions)
    }

    func testFirstSyncCreatesAndRepeatedSyncIsIdempotent() throws {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        let first = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [], mappings: [], window: Fixtures.window)
        XCTAssertEqual(first.map(\.kind), [.create])
        XCTAssertEqual(first.first?.payload, RuleEngine.payload(event: source, rule: rule))
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        let repeated = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(repeated.map(\.kind), [.unchanged])
        XCTAssertFalse(try XCTUnwrap(repeated.first).requiresReview)
    }

    func testOwnershipMarkerRecoversCopyAfterMappingWriteWasInterrupted() {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        let destination = Fixtures.destination(source: source, rule: rule)
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.unchanged])
        XCTAssertEqual(changes.first?.destinationEventID, destination.id)
        XCTAssertEqual(changes.first?.sourceEventID, source.id)
    }

    func testChangedProviderDestinationIDRecoversByOwnershipMarker() {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        var destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        destination.id = "new-provider-id"
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.unchanged])
        XCTAssertEqual(changes.first?.destinationEventID, "new-provider-id")
    }

    func testManualOwnedDestinationEditsAreRestoredIncludingPrivateNotesAndBusy() {
        let rule = Fixtures.rule(.family)
        let source = Fixtures.source(title: "Confidential appointment")
        let clean = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: clean, rule: rule)
        var variants: [EventSnapshot] = []
        var changed = clean; changed.title = "Edited title"; variants.append(changed)
        changed = clean; changed.notes = "Private destination note"; variants.append(changed)
        changed = clean; changed.location = "Private address"; variants.append(changed)
        changed = clean; changed.busy = false; variants.append(changed)
        changed = clean; changed.start = clean.start.addingTimeInterval(60); variants.append(changed)
        changed = clean; changed.timeZoneIdentifier = "Europe/London"; variants.append(changed)
        for destination in variants {
            let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
            XCTAssertEqual(changes.map(\.kind), [.update])
            XCTAssertEqual(changes.first?.payload?.title, "Family Commitment")
            XCTAssertNil(changes.first?.payload?.location)
            XCTAssertNil(changes.first?.payload?.notes)
        }
    }

    func testNotesAdditionEditAndRemovalUpdateExistingCopyThenBecomeUnchanged() throws {
        let cases: [(String?, String?)] = [
            (nil, "Terminal 2\nGate 7"),
            ("Original gate", "  Revised gate\n\nCheck in at 09:00\n"),
            ("Remove this note", nil),
            ("Remove this note", "")
        ]
        for preset in [RulePreset.flights, .custom] {
            var rule = Fixtures.rule(preset)
            if preset == .custom { rule.conditions = [RuleCondition(value: "Flight")] }
            for (oldNotes, newNotes) in cases {
                var original = Fixtures.source()
                original.notes = oldNotes
                let destination = Fixtures.destination(source: original, rule: rule)
                let mapping = Fixtures.mapping(source: original, destination: destination, rule: rule)
                var changed = original
                changed.notes = newNotes

                let changes = SyncPlanner.plan(rule: rule, sourceEvents: [changed], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
                XCTAssertEqual(changes.map(\.kind), [.update])
                XCTAssertEqual(changes.first?.destinationEventID, destination.id)
                let payload = try XCTUnwrap(changes.first?.payload)
                XCTAssertEqual(payload.notes, newNotes?.isEmpty == true ? nil : newNotes)

                let syncedDestination = Fixtures.destination(source: changed, rule: rule)
                let syncedMapping = Fixtures.mapping(source: changed, destination: syncedDestination, rule: rule)
                let repeated = SyncPlanner.plan(rule: rule, sourceEvents: [changed], destinationEvents: [syncedDestination], mappings: [syncedMapping], window: Fixtures.window)
                XCTAssertEqual(repeated.map(\.kind), [.unchanged])
            }
        }
    }

    func testEmptyAndAbsentDestinationNotesAreEquivalent() {
        let rule = Fixtures.rule()
        for sourceNotes in [nil, ""] as [String?] {
            for destinationNotes in [nil, ""] as [String?] {
                var source = Fixtures.source()
                source.notes = sourceNotes
                var destination = Fixtures.destination(source: source, rule: rule)
                destination.notes = destinationNotes
                let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
                XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).map(\.kind), [.unchanged])
            }
        }
    }

    func testFamilySourceNoteChangesNeverAddNotesToCopy() {
        let rule = Fixtures.rule(.family)
        var source = Fixtures.source(title: "School meeting")
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        source.notes = "New confidential family details"
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.unchanged])
        XCTAssertNil(changes.first?.payload?.notes)
    }

    func testLegacyMappingWithoutNotesDecodesAndPlansNotesUpdate() throws {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        var destination = Fixtures.destination(source: source, rule: rule)
        destination.notes = nil
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mapping)) as? [String: Any])
        var payload = try XCTUnwrap(legacy["lastPayload"] as? [String: Any])
        payload.removeValue(forKey: "notes")
        legacy["lastPayload"] = payload

        let decoded = try JSONDecoder().decode(SyncMapping.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.lastPayload.notes)
        XCTAssertEqual(decoded.sourceKey, mapping.sourceKey)
        XCTAssertEqual(decoded.destinationEventID, mapping.destinationEventID)
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [decoded], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.update])
        XCTAssertEqual(changes.first?.payload?.notes, source.notes)
        XCTAssertEqual(changes.first?.destinationEventID, destination.id)
    }

    func testMatchingTitleNeverClaimsAnUnownedEvent() {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        var destination = Fixtures.destination(source: source, rule: rule)
        destination.ownership = nil
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.create])
        XCTAssertNil(changes.first?.destinationEventID)
    }

    func testMappingCannotAuthorizeOverwritingAnUnownedOrOtherRuleEvent() {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        var destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        destination.ownership = nil
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).map(\.kind), [.conflict])
        destination.ownership = OwnershipMarker(ruleID: UUID(), sourceKey: source.sourceKey)
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).map(\.kind), [.conflict])
    }

    func testCancelledAndNoLongerMatchingSourcesRequireReviewedRemovalWithLastPayload() {
        let rule = Fixtures.rule()
        let original = Fixtures.source()
        let destination = Fixtures.destination(source: original, rule: rule)
        let mapping = Fixtures.mapping(source: original, destination: destination, rule: rule)
        var cancelled = original; cancelled.isCancelled = true
        var unmatched = original; unmatched.title = "No longer a flight"
        var owned = original; owned.ownership = OwnershipMarker(ruleID: UUID(), sourceKey: "another-source")
        for source in [cancelled, unmatched, owned] {
            let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
            XCTAssertEqual(changes.map(\.kind), [.remove])
            XCTAssertEqual(changes.first?.requiresReview, true)
            XCTAssertEqual(changes.first?.payload, mapping.lastPayload)
        }
    }

    func testMissingSourceInsidePreviousWindowRequiresReviewButHistoryIsPreserved() {
        let rule = Fixtures.rule()
        var source = Fixtures.source()
        let destination = Fixtures.destination(source: source, rule: rule)
        var mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.remove])
        XCTAssertEqual(changes.first?.requiresReview, true)
        source.start = Fixtures.date("2026-09-01T00:00:00Z")
        source.end = Fixtures.date("2026-09-01T01:00:00Z")
        mapping.lastPayload = RuleEngine.payload(event: source, rule: rule)
        // A manual move of the copy into the window must not make old source history look deleted.
        XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).isEmpty)
    }

    func testTrackedSourceMovedOutsideWindowIsNeitherDeletedNorUpdated() {
        let rule = Fixtures.rule()
        var source = Fixtures.source()
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        source.start = Fixtures.date("2027-01-01T00:00:00Z")
        source.end = Fixtures.date("2027-01-01T01:00:00Z")
        XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).isEmpty)
    }

    func testOutOfWindowCopiesArePreservedDespiteCancellationOrRuleChanges() {
        var rule = Fixtures.rule(.family)
        for start in [Fixtures.date("2026-09-01T00:00:00Z"), Fixtures.date("2027-01-01T00:00:00Z")] {
            var source = Fixtures.source(title: "School appointment")
            source.start = start; source.end = start.addingTimeInterval(3600)
            let destination = Fixtures.destination(source: source, rule: rule)
            let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
            rule.conditions = [RuleCondition(value: "dentist")]
            XCTAssertFalse(RuleEngine.evaluate(event: source, rule: rule).matches)
            XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).isEmpty)
            source.isCancelled = true
            XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).isEmpty)
        }
    }

    func testRecurringOccurrencesUseStableSourceKeysEvenWhenProviderIDsAreShared() {
        let rule = Fixtures.rule()
        let first = Fixtures.source(key: "series:slot-1", id: "shared-series-id")
        var second = Fixtures.source(key: "series:slot-2", id: "shared-series-id")
        second.start = first.start.addingTimeInterval(7 * 86400)
        second.end = first.end.addingTimeInterval(7 * 86400)
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [second, first], destinationEvents: [], mappings: [], window: Fixtures.window).map(\.kind), [.create, .create])
        let destination = Fixtures.destination(source: first, rule: rule)
        let mapping = Fixtures.mapping(source: first, destination: destination, rule: rule)
        var moved = first; moved.start = first.start.addingTimeInterval(3600); moved.end = first.end.addingTimeInterval(3600)
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [moved], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.update])
        XCTAssertEqual(changes.first?.destinationEventID, destination.id)
    }

    func testWindowIsHalfOpenAndIncludesSpanningEvents() {
        let rule = Fixtures.rule()
        var event = Fixtures.source()
        event.start = Fixtures.window.end
        event.end = event.start.addingTimeInterval(3600)
        XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [event], destinationEvents: [], mappings: [], window: Fixtures.window).isEmpty)
        event.end = Fixtures.window.start
        event.start = event.end.addingTimeInterval(-3600)
        XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [event], destinationEvents: [], mappings: [], window: Fixtures.window).isEmpty)
        event.start = Fixtures.window.start.addingTimeInterval(-3600)
        event.end = Fixtures.window.start.addingTimeInterval(3600)
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [event], destinationEvents: [], mappings: [], window: Fixtures.window).map(\.kind), [.create])
    }

    func testDuplicateSourceKeysMarkersMappingsAndDestinationIDsAreConflicts() {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source, source], destinationEvents: [], mappings: [], window: Fixtures.window).map(\.kind), [.conflict])
        var duplicate = destination; duplicate.id = "other-id"
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination, duplicate], mappings: [], window: Fixtures.window).map(\.kind), [.conflict])
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping, mapping], window: Fixtures.window).map(\.kind), [.conflict])
        var unownedDuplicate = destination; unownedDuplicate.ownership = nil
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination, unownedDuplicate], mappings: [mapping], window: Fixtures.window).map(\.kind), [.conflict])
    }

    func testChangingConfiguredCalendarsCannotOrphanExistingCopies() {
        var rule = Fixtures.rule()
        let source = Fixtures.source()
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        rule.destinationCalendarID = "another-destination"
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [], mappings: [mapping], window: Fixtures.window).map(\.kind), [.conflict])
        rule.destinationCalendarID = mapping.destinationCalendarID
        rule.sourceCalendarID = "another-source"
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).map(\.kind), [.conflict])
        var newSource = Fixtures.source(key: "entirely-new-source", id: "new-event")
        newSource.calendarID = rule.sourceCalendarID
        XCTAssertEqual(SyncPlanner.plan(rule: rule, sourceEvents: [newSource], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window).map(\.kind), [.conflict])
    }

    func testInvalidRuleDoesNotTurnExistingCopiesIntoRemovals() {
        var rule = Fixtures.rule(.custom)
        rule.conditions = [RuleCondition(value: " ")]
        let source = Fixtures.source()
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.conflict])
    }

    func testUnmatchedSourcesAndCopiesFromOtherRulesDoNotCreateLoops() {
        let rule = Fixtures.rule()
        var source = Fixtures.source()
        source.ownership = OwnershipMarker(ruleID: UUID(), sourceKey: "external-source")
        let destination = Fixtures.destination(source: source, rule: Fixtures.rule())
        XCTAssertTrue(SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [], window: Fixtures.window).isEmpty)
    }

    func testUnresolvedRecurringSourceCannotBeRemovedWithOrWithoutMapping() {
        let rule = Fixtures.rule()
        let source = Fixtures.source()
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        for mappings in [[mapping], []] {
            let changes = SyncPlanner.plan(rule: rule, sourceEvents: [], destinationEvents: [destination], mappings: mappings,
                                           window: Fixtures.window, unresolvedSourceKeys: [source.sourceKey])
            XCTAssertEqual(changes.map(\.kind), [.conflict])
            XCTAssertEqual(changes.first?.destinationEventID, destination.id)
            XCTAssertEqual(changes.first?.requiresReview, true)
            XCTAssertTrue(changes.first?.reason.contains("may have moved") == true)
        }
    }

    func testUnresolvedOccurrenceDoesNotBlockIndependentNewSource() {
        let rule = Fixtures.rule()
        let oldSource = Fixtures.source()
        let destination = Fixtures.destination(source: oldSource, rule: rule)
        let mapping = Fixtures.mapping(source: oldSource, destination: destination, rule: rule)
        let newSource = Fixtures.source(key: "independent-new-source", id: "independent-event")
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [newSource], destinationEvents: [destination], mappings: [mapping],
                                       window: Fixtures.window, unresolvedSourceKeys: [oldSource.sourceKey, "untracked-missing-key"])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first(where: { $0.sourceKey == oldSource.sourceKey })?.kind, .conflict)
        XCTAssertEqual(changes.first(where: { $0.sourceKey == newSource.sourceKey })?.kind, .create)
    }

    func testIdentityHintMigrationBlocksCreatingDuplicateAndRemovingOldCopy() {
        let rule = Fixtures.rule()
        var source = Fixtures.source()
        source.identityHint = "provider-stable-occurrence"
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        source.sourceKey = "new-source-key"
        source.id = "new-provider-id"
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.conflict])
        XCTAssertEqual(changes.first?.requiresReview, true)
        XCTAssertTrue(changes.first?.reason.contains("different source key") == true)
    }

    func testSameSourceIDWithChangedKeyAndHintBlocksTheWholeRule() {
        let rule = Fixtures.rule()
        var source = Fixtures.source()
        source.identityHint = "old-derived-identity"
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        source.sourceKey = "changed-derived-source-key"
        source.identityHint = "changed-derived-identity"
        source.start = source.start.addingTimeInterval(3600)
        source.end = source.end.addingTimeInterval(3600)
        let independent = Fixtures.source(key: "independent-source", id: "independent-event")

        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [source, independent], destinationEvents: [destination],
                                       mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.conflict])
        XCTAssertEqual(changes.first?.requiresReview, true)
        XCTAssertTrue(changes.first?.reason.contains("different source key") == true)
    }

    func testUnrelatedSourceIDsAndHintsDoNotTriggerIdentityConflict() {
        let rule = Fixtures.rule()
        var previous = Fixtures.source()
        previous.identityHint = "previous-event-identity"
        let destination = Fixtures.destination(source: previous, rule: rule)
        let mapping = Fixtures.mapping(source: previous, destination: destination, rule: rule)
        var independent = Fixtures.source(key: "independent-source", id: "independent-event")
        independent.identityHint = "independent-event-identity"

        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [independent], destinationEvents: [destination],
                                       mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first(where: { $0.sourceKey == previous.sourceKey })?.kind, .remove)
        XCTAssertEqual(changes.first(where: { $0.sourceKey == independent.sourceKey })?.kind, .create)
    }

    func testStableIdentityHintAndDistinctOccurrenceHintsDoNotConflict() {
        let rule = Fixtures.rule()
        var first = Fixtures.source(key: "series:slot-1", id: "series-occurrence-reference-1")
        first.identityHint = "stable-series:original-slot-1"
        var second = Fixtures.source(key: "series:slot-2", id: "series-occurrence-reference-2")
        second.identityHint = "stable-series:original-slot-2"
        let destination = Fixtures.destination(source: first, rule: rule)
        let mapping = Fixtures.mapping(source: first, destination: destination, rule: rule)
        let changes = SyncPlanner.plan(rule: rule, sourceEvents: [first, second], destinationEvents: [destination], mappings: [mapping], window: Fixtures.window)
        XCTAssertEqual(changes.map(\.kind), [.unchanged, .create])
    }

    func testMappingsDecodeBeforeIdentityHintWasAddedAndNewHintsRoundTrip() throws {
        let rule = Fixtures.rule()
        var source = Fixtures.source()
        source.identityHint = "stable-provider-identity"
        let destination = Fixtures.destination(source: source, rule: rule)
        let mapping = Fixtures.mapping(source: source, destination: destination, rule: rule)
        let encoded = try JSONEncoder().encode(mapping)
        XCTAssertEqual(try JSONDecoder().decode(SyncMapping.self, from: encoded), mapping)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "sourceIdentityHint")
        let decoded = try JSONDecoder().decode(SyncMapping.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.sourceIdentityHint)
        XCTAssertEqual(decoded.sourceKey, mapping.sourceKey)
        XCTAssertEqual(decoded.lastPayload, mapping.lastPayload)
    }

    func testOwnedCopyConvertedToRecurrenceOrMeetingAlwaysConflicts() {
        let rule = Fixtures.rule()
        let original = Fixtures.source()
        var destination = Fixtures.destination(source: original, rule: rule)
        let mapping = Fixtures.mapping(source: original, destination: destination, rule: rule)
        destination.canManageAsCopy = false
        var updated = original; updated.location = "Updated airport"
        var unmatched = original; unmatched.title = "No longer a flight"
        var cancelled = original; cancelled.isCancelled = true
        for sourceEvents in [[original], [updated], [unmatched], [cancelled], []] {
            for mappings in [[mapping], []] {
                let changes = SyncPlanner.plan(rule: rule, sourceEvents: sourceEvents, destinationEvents: [destination], mappings: mappings, window: Fixtures.window)
                XCTAssertEqual(changes.map(\.kind), [.conflict])
                XCTAssertEqual(changes.first?.destinationEventID, destination.id)
                XCTAssertEqual(changes.first?.requiresReview, true)
            }
        }
    }
}

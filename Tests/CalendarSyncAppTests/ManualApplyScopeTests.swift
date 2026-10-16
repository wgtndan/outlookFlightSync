import CalendarSyncCore
import Foundation
import XCTest
@testable import CalendarSyncApp

final class ManualApplyScopeTests: XCTestCase {
    private let ruleID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    func testSingleActionIncludesOnlySelectedCreateUpdateOrRemoval() throws {
        let changes = [change("create", .create), change("update", .update),
                       change("remove", .remove), change("existing", .unchanged)]
        for selected in changes.prefix(3) {
            let scope = try ManualApplyScope.validate(previewed: changes, fresh: changes, changeID: selected.id)
            XCTAssertEqual(scope.changes, [selected])
            XCTAssertEqual(scope.sourceKeysToAcknowledge, [selected.sourceKey])
            XCTAssertFalse(scope.approvesConfiguration, "Even a single remaining event cannot approve automatic syncing.")
        }
    }

    func testSingleRemainingChangeStillRequiresFullConfirmationForAutomaticApproval() throws {
        let selected = change("only", .create)
        let scope = try ManualApplyScope.validate(previewed: [selected], fresh: [selected], changeID: selected.id)
        XCTAssertFalse(scope.approvesConfiguration)
    }

    func testFullApplyRetainsUnchangedRecoveryAndConfigurationApproval() throws {
        let changes = [change("new", .create), change("existing", .unchanged)]
        let scope = try ManualApplyScope.validate(previewed: changes, fresh: changes, changeID: nil)
        XCTAssertEqual(scope.changes, changes)
        XCTAssertEqual(scope.sourceKeysToAcknowledge, ["new", "existing"])
        XCTAssertTrue(scope.approvesConfiguration)
    }

    func testEmptyFullPreviewCanConfirmRuleWithoutAnyAcknowledgements() throws {
        let scope = try ManualApplyScope.validate(previewed: [], fresh: [], changeID: nil)
        XCTAssertTrue(scope.changes.isEmpty)
        XCTAssertTrue(scope.sourceKeysToAcknowledge.isEmpty)
        XCTAssertTrue(scope.approvesConfiguration)
    }

    func testChangedUnselectedEventStillInvalidatesSingleApply() {
        let selected = change("selected", .create)
        let other = change("other", .update)
        var refreshed = other
        refreshed.payload?.title = "Changed after preview"
        assertValidationError(.stalePreview, previewed: [selected, other], fresh: [selected, refreshed], id: selected.id)
    }

    func testChangedOperationKindInvalidatesSingleApply() {
        let selected = change("selected", .create)
        var refreshed = selected
        refreshed.kind = .unchanged
        assertValidationError(.stalePreview, previewed: [selected], fresh: [refreshed], id: selected.id)
    }

    func testUnrelatedConflictPreventsBothSingleAndFullApply() {
        let selected = change("selected", .create)
        let changes = [selected, change("other", .conflict)]
        assertValidationError(.conflicts, previewed: changes, fresh: changes, id: selected.id)
        assertValidationError(.conflicts, previewed: changes, fresh: changes, id: nil)
    }

    func testMissingOrAmbiguousSelectionCannotFallBackToFullApply() {
        let selected = change("selected", .create)
        assertValidationError(.invalidSelection, previewed: [selected], fresh: [selected], id: "missing")
        assertValidationError(.invalidSelection, previewed: [selected, selected], fresh: [selected, selected], id: selected.id)
    }

    func testUnchangedRowCannotBeAppliedAsSingleMutation() {
        let selected = change("existing", .unchanged)
        assertValidationError(.notApplicable, previewed: [selected], fresh: [selected], id: selected.id)
    }

    func testSingleApplyAcknowledgesOnlyItsPendingOperation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StateStore(directory: directory)
        let selected = change("selected", .create)
        let other = change("other", .create)
        let recovered = change("existing", .unchanged)
        let changes = [selected, other, recovered]
        _ = try store.begin(selected)
        _ = try store.begin(other)
        _ = try store.begin(recovered)
        let scope = try ManualApplyScope.validate(previewed: changes, fresh: changes, changeID: selected.id)
        try store.acknowledgeRecoveredOperations(ruleID: ruleID, sourceKeys: scope.sourceKeysToAcknowledge)
        XCTAssertEqual(try store.pendingSourceKeys(ruleID: ruleID), ["other", "existing"])
        XCTAssertEqual(try store.pendingCount(), 2)
    }

    private func assertValidationError(_ expected: ManualApplyScope.ValidationError, previewed: [PlannedChange],
                                       fresh: [PlannedChange], id: String?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ManualApplyScope.validate(previewed: previewed, fresh: fresh, changeID: id), file: file, line: line) { error in
            XCTAssertEqual(error as? ManualApplyScope.ValidationError, expected, file: file, line: line)
        }
    }

    private func change(_ key: String, _ kind: ChangeKind) -> PlannedChange {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return PlannedChange(ruleID: ruleID, sourceKey: key, sourceEventID: "source-\(key)",
            destinationEventID: kind == .create ? nil : "destination-\(key)", kind: kind,
            payload: CopyPayload(title: "Sample event", start: start, end: start.addingTimeInterval(3_600),
                isAllDay: false, timeZoneIdentifier: "Australia/Melbourne", location: nil, busy: true),
            reason: "Synthetic test", requiresReview: kind == .remove)
    }
}

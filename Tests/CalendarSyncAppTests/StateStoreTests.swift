import CalendarSyncCore
import CSQLite
import Foundation
import XCTest
@testable import CalendarSyncApp

final class StateStoreTests: XCTestCase {
    func testReadOnlyStoreAllowsInspectionAndRejectsEveryWriteWithoutChangingFiles() throws {
        try withTemporaryDirectory { directory in
            let rule = SyncRule.makePreset(.flights)
            var original = SavedState()
            original.rules = [rule]
            let operationID: String
            do {
                let store = try StateStore(directory: directory)
                try store.save(original)
                operationID = try store.begin(change(ruleID: rule.id, key: "pending-source"))
            }
            let path = directory.appendingPathComponent("state.sqlite")
            // Use deliberately different permissions to catch a diagnostic
            // connection accidentally running normal store initialization.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
            let originalBytes = try Data(contentsOf: path)
            let originalFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

            do {
                let diagnostic = try StateStore(directory: directory, readOnly: true)
                XCTAssertEqual(try diagnostic.load().rules, original.rules)
                XCTAssertEqual(try diagnostic.pendingCount(), 1)
                XCTAssertEqual(try diagnostic.pendingSourceKeys(ruleID: rule.id), ["pending-source"])
                XCTAssertThrowsError(try diagnostic.save(SavedState()))
                XCTAssertThrowsError(try diagnostic.begin(change(ruleID: rule.id, key: "new-source")))
                XCTAssertThrowsError(try diagnostic.finish(operationID))
                XCTAssertThrowsError(try diagnostic.acknowledgeRecoveredOperations(
                    ruleID: rule.id, sourceKeys: ["pending-source"]
                ))
                XCTAssertEqual(try diagnostic.load().rules, original.rules)
                XCTAssertEqual(try diagnostic.pendingCount(), 1)
                XCTAssertEqual(try diagnostic.pendingSourceKeys(ruleID: rule.id), ["pending-source"])
            }

            XCTAssertEqual(try Data(contentsOf: path), originalBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), originalFiles)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o755)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o644)
        }
    }

    func testReadOnlyStoreDoesNotCreateMissingDirectoryOrDatabase() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing", isDirectory: true)
            XCTAssertThrowsError(try StateStore(directory: missing, readOnly: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            XCTAssertThrowsError(try StateStore(directory: directory, readOnly: true))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testReadOnlyStoreDoesNotCreateMissingTables() throws {
        try withTemporaryDirectory { directory in
            do { _ = try StateStore(directory: directory) }
            try execute("DROP TABLE state; DROP TABLE operations", in: directory)
            let path = directory.appendingPathComponent("state.sqlite")
            let originalBytes = try Data(contentsOf: path)
            do {
                let diagnostic = try StateStore(directory: directory, readOnly: true)
                XCTAssertThrowsError(try diagnostic.load())
                XCTAssertThrowsError(try diagnostic.pendingCount())
            }
            XCTAssertEqual(try Data(contentsOf: path), originalBytes)
        }
    }

    func testNewStoreStartsEmptyWithoutPendingOperations() throws {
        try withTemporaryDirectory { directory in
            let store = try StateStore(directory: directory)
            let state = try store.load()
            XCTAssertEqual(state.schemaVersion, 1)
            XCTAssertTrue(state.rules.isEmpty)
            XCTAssertTrue(state.mappings.isEmpty)
            XCTAssertTrue(state.approvedConfigurations.isEmpty)
            XCTAssertTrue(state.runs.isEmpty)
            XCTAssertEqual(try store.pendingCount(), 0)
        }
    }

    func testFamilyStateRoundTripPersistsRedactedPayloadAndApproval() throws {
        try withTemporaryDirectory { directory in
            var rule = SyncRule.makePreset(.family)
            rule.sourceCalendarID = "sample-family-calendar"
            rule.destinationCalendarID = "sample-work-calendar"
            rule.automatic = true
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let source = EventSnapshot(
                id: "sample-source-event", sourceKey: String(repeating: "a", count: 64),
                calendarID: rule.sourceCalendarID, title: "Fictional confidential appointment",
                start: start, end: start.addingTimeInterval(3_600),
                timeZoneIdentifier: "Australia/Melbourne", location: "Fictional private address",
                notes: "Fictional confidential notes", busy: false, identityHint: "sample-provider-identity"
            )
            let mapping = SyncMapping(
                ruleID: rule.id, sourceKey: source.sourceKey, sourceEventID: source.id,
                destinationEventID: "sample-copy-event", sourceCalendarID: rule.sourceCalendarID,
                destinationCalendarID: rule.destinationCalendarID,
                lastPayload: RuleEngine.payload(event: source, rule: rule),
                sourceIdentityHint: source.identityHint
            )
            let run = RunRecord(ruleName: rule.name, summary: "1 copy created", succeeded: true, ruleID: rule.id)
            var state = SavedState()
            state.rules = [rule]
            state.mappings = [mapping]
            state.approvedConfigurations = [rule.id.uuidString: "approved-configuration-digest"]
            state.runs = [run]
            do {
                let store = try StateStore(directory: directory)
                try store.save(state)
            }

            let reopened = try StateStore(directory: directory)
            let loaded = try reopened.load()
            XCTAssertEqual(loaded.rules, state.rules)
            XCTAssertEqual(loaded.mappings, state.mappings)
            XCTAssertEqual(loaded.approvedConfigurations, state.approvedConfigurations)
            XCTAssertEqual(loaded.runs.count, 1)
            XCTAssertEqual(loaded.runs.first?.id, run.id)
            XCTAssertEqual(loaded.runs.first?.date, run.date)
            XCTAssertEqual(loaded.runs.first?.ruleName, run.ruleName)
            XCTAssertEqual(loaded.runs.first?.ruleID, rule.id)
            XCTAssertEqual(loaded.runs.first?.summary, run.summary)
            XCTAssertEqual(loaded.runs.first?.succeeded, true)
            let payload = try XCTUnwrap(loaded.mappings.first?.lastPayload)
            XCTAssertEqual(payload.title, "Family Commitment")
            XCTAssertNil(payload.location)
            XCTAssertTrue(payload.busy)
            XCTAssertEqual(payload.start, source.start)
            XCTAssertEqual(payload.end, source.end)

            // Inspect the actual SQLite payload, not only a second JSON encoding.
            let persistedJSON = try persistedStateJSON(in: directory)
            XCTAssertFalse(persistedJSON.contains(source.title))
            XCTAssertFalse(persistedJSON.contains(try XCTUnwrap(source.location)))
            XCTAssertFalse(persistedJSON.contains(try XCTUnwrap(source.notes)))
            XCTAssertFalse(persistedJSON.contains("\"notes\""))
        }
    }

    func testPendingOperationsSurviveReopeningAndRemainSeparateFromSavedState() throws {
        try withTemporaryDirectory { directory in
            let ruleID = UUID()
            let change = change(ruleID: ruleID, key: "pending-source")
            let operationID: String
            do {
                let store = try StateStore(directory: directory)
                operationID = try store.begin(change)
                var state = SavedState()
                state.approvedConfigurations = [ruleID.uuidString: "sample-approval"]
                try store.save(state)
            }
            do {
                let reopened = try StateStore(directory: directory)
                XCTAssertEqual(try reopened.pendingCount(), 1)
                XCTAssertEqual(try reopened.pendingSourceKeys(ruleID: ruleID), [change.sourceKey])
                try reopened.finish(operationID)
            }
            let finished = try StateStore(directory: directory)
            XCTAssertEqual(try finished.pendingCount(), 0)
            XCTAssertTrue(try finished.pendingSourceKeys(ruleID: ruleID).isEmpty)
            XCTAssertEqual(try finished.load().approvedConfigurations[ruleID.uuidString], "sample-approval")
        }
    }

    func testSelectiveRecoveryOnlyAcknowledgesProvidedKeysForSpecifiedRule() throws {
        try withTemporaryDirectory { directory in
            let store = try StateStore(directory: directory)
            let firstRule = UUID()
            let secondRule = UUID()
            _ = try store.begin(change(ruleID: firstRule, key: "reconciled-source"))
            _ = try store.begin(change(ruleID: firstRule, key: "reconciled-source", kind: .update))
            _ = try store.begin(change(ruleID: firstRule, key: "unresolved-source"))
            _ = try store.begin(change(ruleID: secondRule, key: "reconciled-source"))

            XCTAssertEqual(try store.pendingCount(), 4)
            XCTAssertEqual(try store.pendingSourceKeys(ruleID: firstRule), ["reconciled-source", "unresolved-source"])
            XCTAssertEqual(try store.pendingSourceKeys(ruleID: secondRule), ["reconciled-source"])
            XCTAssertTrue(try store.pendingSourceKeys(ruleID: UUID()).isEmpty)

            try store.acknowledgeRecoveredOperations(ruleID: firstRule, sourceKeys: ["reconciled-source"])
            XCTAssertEqual(try store.pendingCount(), 2)
            XCTAssertEqual(try store.pendingSourceKeys(ruleID: firstRule), ["unresolved-source"])
            XCTAssertEqual(try store.pendingSourceKeys(ruleID: secondRule), ["reconciled-source"])

            try store.acknowledgeRecoveredOperations(ruleID: firstRule, sourceKeys: [])
            try store.acknowledgeRecoveredOperations(ruleID: firstRule, sourceKeys: ["unknown-source"])
            try store.acknowledgeRecoveredOperations(ruleID: firstRule, sourceKeys: ["reconciled-source"])
            XCTAssertEqual(try store.pendingCount(), 2)
        }
    }

    func testFinishAcknowledgesOnlyOneOperationEvenWhenSourceKeyIsShared() throws {
        try withTemporaryDirectory { directory in
            let store = try StateStore(directory: directory)
            let ruleID = UUID()
            let first = try store.begin(change(ruleID: ruleID, key: "shared-source"))
            let second = try store.begin(change(ruleID: ruleID, key: "shared-source", kind: .update))
            try store.finish(first)
            try store.finish(first)
            XCTAssertEqual(try store.pendingCount(), 1)
            XCTAssertEqual(try store.pendingSourceKeys(ruleID: ruleID), ["shared-source"])
            try store.finish(second)
            XCTAssertEqual(try store.pendingCount(), 0)
        }
    }

    func testNewerSchemaFailsWithoutReplacingSavedState() throws {
        try withTemporaryDirectory { directory in
            let store = try StateStore(directory: directory)
            var state = SavedState()
            state.schemaVersion = 2
            state.approvedConfigurations = ["future-rule": "future-approval"]
            try store.save(state)
            let before = try persistedStateJSON(in: directory)

            XCTAssertThrowsError(try store.load()) { error in
                guard case StateStoreError.newerVersion = error else {
                    return XCTFail("Expected newerVersion, got \(error)")
                }
            }
            let reopened = try StateStore(directory: directory)
            XCTAssertThrowsError(try reopened.load())
            XCTAssertEqual(try persistedStateJSON(in: directory), before)
        }
    }

    func testCorruptSavedJSONFailsWithoutResettingStateOrJournal() throws {
        try withTemporaryDirectory { directory in
            let store = try StateStore(directory: directory)
            try store.save(SavedState())
            let ruleID = UUID()
            _ = try store.begin(change(ruleID: ruleID, key: "unresolved-source"))
            try execute("UPDATE state SET data = X'7B' WHERE id = 1", in: directory)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try persistedStateJSON(in: directory), "{")
            XCTAssertEqual(try store.pendingSourceKeys(ruleID: ruleID), ["unresolved-source"])
            let reopened = try StateStore(directory: directory)
            XCTAssertThrowsError(try reopened.load())
            XCTAssertEqual(try reopened.pendingCount(), 1)
        }
    }

    func testEmptySavedBlobFailsInsteadOfLookingLikeANewStore() throws {
        try withTemporaryDirectory { directory in
            let store = try StateStore(directory: directory)
            try store.save(SavedState())
            try execute("UPDATE state SET data = X'' WHERE id = 1", in: directory)
            XCTAssertThrowsError(try store.load()) { error in
                guard case StateStoreError.database = error else {
                    return XCTFail("Expected a database error, got \(error)")
                }
            }
        }
    }

    private func change(ruleID: UUID, key: String, kind: ChangeKind = .create) -> PlannedChange {
        PlannedChange(ruleID: ruleID, sourceKey: key, sourceEventID: "sample-source-event",
                      kind: kind, payload: nil, reason: "Synthetic persistence test")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarSyncAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withDatabase<T>(in directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let path = directory.appendingPathComponent("state.sqlite").path
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(handle) }
        guard result == SQLITE_OK, let handle else {
            throw NSError(domain: "StateStoreTests.SQLite", code: Int(result))
        }
        return try body(handle)
    }

    private func execute(_ sql: String, in directory: URL) throws {
        try withDatabase(in: directory) { handle in
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw NSError(domain: "StateStoreTests.SQLite", code: Int(result))
            }
        }
    }

    private func persistedStateJSON(in directory: URL) throws -> String {
        try withDatabase(in: directory) { handle in
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(handle, "SELECT data FROM state WHERE id = 1", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0) else {
                throw NSError(domain: "StateStoreTests.SQLite", code: Int(sqlite3_errcode(handle)))
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }
    }
}

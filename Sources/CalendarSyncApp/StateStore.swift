import Foundation
import CalendarSyncCore
import CSQLite

struct RunRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var ruleName: String
    var summary: String
    var succeeded: Bool
}

struct SavedState: Codable {
    var schemaVersion = 1
    var rules: [SyncRule] = []
    var mappings: [SyncMapping] = []
    var approvedConfigurations: [String: String] = [:]
    var runs: [RunRecord] = []
}

enum StateStoreError: LocalizedError {
    case database(String)
    case newerVersion
    var errorDescription: String? {
        switch self {
        case .database(let message): "Local sync history could not be saved: \(message). Calendar changes are paused."
        case .newerVersion: "This sync history was created by a newer version of Calendar Sync. Install that version to continue."
        }
    }
}

/// The database is used only from AppModel's main actor. Each calendar write is
/// preceded by a durable journal entry; URL ownership markers recover a write
/// that succeeds before its mapping can be committed.
final class StateStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil, readOnly: Bool = false) throws {
        let directory = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: !readOnly
        ).appendingPathComponent("CalendarSync", isDirectory: true)
        if !readOnly {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let path = directory.appendingPathComponent("state.sqlite").path
        let accessFlags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &database, accessFlags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw StateStoreError.database("Unable to open the database.")
        }
        // Diagnostics may inspect an existing store, but must leave its files,
        // permissions, schema, and operation journal untouched. SQLite itself
        // rejects writes attempted through this connection.
        if readOnly { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode = DELETE")
        try execute("PRAGMA synchronous = FULL")
        try execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK (id = 1), data BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS operations (id TEXT PRIMARY KEY, rule_id TEXT NOT NULL, source_key TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, created REAL NOT NULL)")
    }

    deinit { sqlite3_close(database) }

    func load() throws -> SavedState {
        let statement = try prepare("SELECT data FROM state WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return SavedState()
        case SQLITE_ROW:
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let bytes = sqlite3_column_blob(statement, 0), count > 0 else {
                throw StateStoreError.database("The saved configuration is empty.")
            }
            let result = try JSONDecoder().decode(SavedState.self, from: Data(bytes: bytes, count: count))
            guard result.schemaVersion == 1 else { throw StateStoreError.newerVersion }
            return result
        default: throw error()
        }
    }

    func save(_ state: SavedState) throws {
        let data = try JSONEncoder().encode(state)
        let statement = try prepare("INSERT INTO state (id, data) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data")
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func begin(_ change: PlannedChange) throws -> String {
        let operationID = UUID().uuidString
        let statement = try prepare("INSERT INTO operations VALUES (?, ?, ?, ?, 'pending', ?)")
        defer { sqlite3_finalize(statement) }
        bind(operationID, to: 1, in: statement)
        bind(change.ruleID.uuidString, to: 2, in: statement)
        bind(change.sourceKey, to: 3, in: statement)
        bind(change.kind.rawValue, to: 4, in: statement)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        return operationID
    }

    func finish(_ operationID: String) throws {
        let statement = try prepare("UPDATE operations SET status = 'complete' WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(operationID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        try execute("DELETE FROM operations WHERE status = 'complete' AND created < \(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970)")
    }

    func pendingCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM operations WHERE status = 'pending'")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int(statement, 0))
    }

    func pendingSourceKeys(ruleID: UUID) throws -> Set<String> {
        let statement = try prepare("SELECT DISTINCT source_key FROM operations WHERE rule_id = ? AND status = 'pending'")
        defer { sqlite3_finalize(statement) }
        bind(ruleID.uuidString, to: 1, in: statement)
        var keys = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let text = sqlite3_column_text(statement, 0) else { throw error() }
                keys.insert(String(cString: text))
            case SQLITE_DONE: return keys
            default: throw error()
            }
        }
    }

    func acknowledgeRecoveredOperations(ruleID: UUID, sourceKeys: Set<String>) throws {
        for key in sourceKeys {
            let statement = try prepare("UPDATE operations SET status = 'complete' WHERE rule_id = ? AND source_key = ? AND status = 'pending'")
            defer { sqlite3_finalize(statement) }
            bind(ruleID.uuidString, to: 1, in: statement)
            bind(key, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func error() -> StateStoreError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable")
    }
}

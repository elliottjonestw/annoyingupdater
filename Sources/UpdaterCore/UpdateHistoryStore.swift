import Foundation
import CSQLite

public struct UpdateHistoryError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// One connection is serialized by the actor. A transaction commits version
/// baselines, first-seen dates, and events together, including across app crashes.
public actor UpdateHistoryStore {
    private let database: HistoryDatabase
    public init(url: URL) throws { database = try HistoryDatabase(url: url) }

    public func contents() throws -> HistoryContents { try database.contents() }
    @discardableResult
    public func record(_ observation: HistoryObservation, items: [UpdateItem], checkedAt: Date) throws -> HistoryContents {
        try database.transaction {
            var state = try database.state()
            let events = state.apply(observation, items: items, checkedAt: checkedAt)
            for event in events { try database.insert(event) }
            try database.save(state)
        }
        return try database.contents()
    }
    @discardableResult
    public func clear(observation: HistoryObservation?, items: [UpdateItem], at date: Date = Date()) throws -> HistoryContents {
        try database.transaction {
            var state = HistoryTrackingState()
            if let observation { _ = state.apply(observation, items: items, checkedAt: date) }
            state.startedAt = observation == nil ? nil : date
            try database.execute("DELETE FROM events")
            try database.save(state)
        }
        return try database.contents()
    }
}

private final class HistoryDatabase {
    private var connection: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure("History couldn't be opened")
            if let connection { sqlite3_close(connection) }; connection = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(connection, 3000)
            try execute("PRAGMA secure_delete = ON")
            let version = try statement("PRAGMA user_version") { statement -> Int32 in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("History couldn't be read") }
                return sqlite3_column_int(statement, 0)
            }
            guard version <= 1 else { throw UpdateHistoryError(message: "This history database was created by a newer version of Annoying Updater.") }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS tracking (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, detected_at REAL NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE INDEX IF NOT EXISTS events_by_date ON events(detected_at DESC)")
                try execute("PRAGMA user_version = 1")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            if let connection { sqlite3_close(connection) }; connection = nil
            throw error
        }
    }
    deinit { if let connection { sqlite3_close(connection) } }
    private func failure(_ context: String) -> UpdateHistoryError {
        UpdateHistoryError(message: "\(context). \(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable.")")
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure("History couldn't be saved") }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure("History couldn't be read")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }
    private func payload(_ statement: OpaquePointer, column: Int32) throws -> Data {
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, let bytes = sqlite3_column_blob(statement, column) else { throw failure("History data is incomplete") }
        return Data(bytes: bytes, count: length)
    }
    private func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) throws {
        let status = data.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient) }
        guard status == SQLITE_OK else { throw failure("History couldn't be saved") }
    }
    func state() throws -> HistoryTrackingState {
        try statement("SELECT payload FROM tracking WHERE id = 1") { statement in
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return try decoder.decode(HistoryTrackingState.self, from: payload(statement, column: 0))
            case SQLITE_DONE: return HistoryTrackingState()
            default: throw failure("History couldn't be read")
            }
        }
    }
    func save(_ state: HistoryTrackingState) throws {
        let data = try encoder.encode(state)
        try statement("INSERT OR REPLACE INTO tracking(id, payload) VALUES (1, ?)") { statement in
            try bind(data, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("History couldn't be saved") }
        }
    }
    func insert(_ entry: UpdateHistoryEntry) throws {
        let data = try encoder.encode(entry)
        try statement("INSERT INTO events(id, detected_at, payload) VALUES (?, ?, ?)") { statement in
            guard sqlite3_bind_text(statement, 1, entry.id, -1, transient) == SQLITE_OK,
                  sqlite3_bind_double(statement, 2, entry.detectedAt.timeIntervalSince1970) == SQLITE_OK else { throw failure("History couldn't be saved") }
            try bind(data, to: statement, at: 3)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("History couldn't be saved") }
        }
    }
    func contents() throws -> HistoryContents {
        try transaction { try readContents() }
    }
    private func readContents() throws -> HistoryContents {
        let state = try state()
        let entries = try statement("SELECT payload FROM events ORDER BY detected_at DESC, id DESC") { statement in
            var entries: [UpdateHistoryEntry] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: entries.append(try decoder.decode(UpdateHistoryEntry.self, from: payload(statement, column: 0)))
                case SQLITE_DONE: return entries
                default: throw failure("History couldn't be read")
                }
            }
        }
        // Availability providers identify resolved bundles; the journal follows the
        // stable installation location. Expose current aliases to existing rows.
        var firstDetected = state.offers
        for (offer, date) in state.offers {
            if let resolved = state.baselines[offer.softwareID]?.software.resolvedPath {
                firstDetected[HistoryOffer(softwareID: resolved, version: offer.version)] = date
            }
        }
        return HistoryContents(entries: entries, firstDetected: firstDetected, startedAt: state.startedAt)
    }
}

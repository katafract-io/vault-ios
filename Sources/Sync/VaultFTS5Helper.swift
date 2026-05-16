import Foundation
import SQLite3

actor VaultFTS5Helper {
    private var db: OpaquePointer?
    private let dbPath: String

    init(dbPath: String) {
        self.dbPath = dbPath
        self.db = nil
    }

    /// Open database connection and ensure FTS5 table exists
    func openDatabase() throws {
        guard db == nil else { return }

        var dbPtr: OpaquePointer?
        let result = sqlite3_open(dbPath, &dbPtr)
        guard result == SQLITE_OK else {
            throw FTS5Error.databaseOpenFailed("SQLite error: \(result)")
        }

        db = dbPtr

        // Enable FTS5
        try executeStatement("PRAGMA compile_options")

        // Create FTS5 table with content table reference
        try executeStatement("""
        CREATE TABLE IF NOT EXISTS vault_fts(
            name UNINDEXED
        ) USING fts5(
            name,
            content=vault_items,
            content_rowid=id
        )
        """)
    }

    /// Close database connection
    func closeDatabase() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    /// Index files from vault_items table
    func indexFiles() throws {
        guard let db = db else { throw FTS5Error.databaseNotOpen }

        // Clear existing FTS5 index
        try executeStatement("DELETE FROM vault_fts")

        // Rebuild index from vault_items
        try executeStatement("""
        INSERT INTO vault_fts(rowid, name)
        SELECT id, name FROM vault_items
        WHERE isDeleted = 0
        """)
    }

    /// Search for files matching query string
    /// Returns array of (id, name) tuples
    func searchFiles(query: String, limit: Int = 100) throws -> [(id: String, name: String)] {
        guard let db = db else { throw FTS5Error.databaseNotOpen }

        var results: [(id: String, name: String)] = []

        let sql = """
        SELECT vi.id, vi.name
        FROM vault_items vi
        JOIN vault_fts vf ON vi.id = vf.rowid
        WHERE vault_fts MATCH ?
        AND vi.isDeleted = 0
        LIMIT ?
        """

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw FTS5Error.prepareFailed("Failed to prepare search statement")
        }
        defer { sqlite3_finalize(statement) }

        // Bind search query
        let queryPattern = query.trimmingCharacters(in: .whitespaces)
        guard sqlite3_bind_text(statement, 1, queryPattern, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw FTS5Error.bindFailed("Failed to bind query")
        }

        // Bind limit
        guard sqlite3_bind_int(statement, 2, Int32(limit)) == SQLITE_OK else {
            throw FTS5Error.bindFailed("Failed to bind limit")
        }

        // Execute and collect results
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
               let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) {
                results.append((id: id, name: name))
            }
        }

        return results
    }

    // MARK: - Private Helpers

    private func executeStatement(_ sql: String) throws {
        guard let db = db else { throw FTS5Error.databaseNotOpen }

        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)

        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw FTS5Error.executionFailed(message)
        }
    }
}

enum FTS5Error: LocalizedError {
    case databaseNotOpen
    case databaseOpenFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotOpen:
            return "FTS5 database is not open"
        case .databaseOpenFailed(let reason):
            return "Failed to open FTS5 database: \(reason)"
        case .prepareFailed(let reason):
            return "Failed to prepare statement: \(reason)"
        case .bindFailed(let reason):
            return "Failed to bind parameters: \(reason)"
        case .executionFailed(let reason):
            return "Failed to execute statement: \(reason)"
        }
    }
}

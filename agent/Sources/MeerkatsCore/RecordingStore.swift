import Foundation
import SQLite3

public enum StoreError: Error, Equatable {
    case open(String)
    case exec(String)
    case prepare(String)
    case step(String)
}

/// 観測しているストリームの種類。
/// output は相手の声がこちらでどう鳴っているかで、検証は保留中(ADR-0006)。
/// 受け皿だけ先に用意しておく。今入れておくコストはゼロに等しい。
public enum StreamKind: String {
    case mic
    case output
}

/// ADR-0004 の記録先。macOS同梱の libsqlite3 をそのまま使うため、インストール作業は発生しない。
///
/// 時計をセッション単位、音声のパラメータをストリーム単位に分けている。自分のマイクと受信音声は
/// 同じ機械の同じ時計で観測されるため、アンカーを二重に持つ必要がない。
public final class RecordingStore {
    private var db: OpaquePointer?

    /// バインドした値をSQLite側でコピーさせる。Swiftからは定数が見えないので自前で用意する。
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw StoreError.open(message)
        }
        db = handle

        // 分析側が読んでいる間も書き込みが止まらない。
        try exec("PRAGMA journal_mode = WAL;")
        // WALではコミットごとのfsyncが行われなくなる。OSのクラッシュや電源断で直近の
        // コミットを失いうるが、失うのは数秒ぶんのレベル値にすぎない(ADR-0004)。
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try createSchema()
    }

    deinit {
        sqlite3_close_v2(db)
    }

    public func close() {
        sqlite3_close_v2(db)
        db = nil
    }

    private func createSchema() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS sessions (
              id               INTEGER PRIMARY KEY,
              started_wall_us  INTEGER NOT NULL,
              ended_wall_us    INTEGER,
              agent_version    TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS streams (
              id           INTEGER PRIMARY KEY,
              session_id   INTEGER NOT NULL REFERENCES sessions(id),
              kind         TEXT NOT NULL,
              device_name  TEXT,
              sample_rate  INTEGER NOT NULL,
              frame_ms     INTEGER NOT NULL
            );
            """
        )
    }

    // MARK: - セッションとストリーム

    public func startSession(wallUs: Int64, agentVersion: String) throws -> Int64 {
        let statement = try prepare(
            "INSERT INTO sessions (started_wall_us, agent_version) VALUES (?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, wallUs)
        sqlite3_bind_text(statement, 2, agentVersion, -1, Self.transient)
        try step(statement)
        return sqlite3_last_insert_rowid(db)
    }

    public func endSession(id: Int64, wallUs: Int64) throws {
        let statement = try prepare("UPDATE sessions SET ended_wall_us = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, wallUs)
        sqlite3_bind_int64(statement, 2, id)
        try step(statement)
    }

    public func addStream(
        sessionId: Int64,
        kind: StreamKind,
        deviceName: String?,
        sampleRate: Int,
        frameMs: Int
    ) throws -> Int64 {
        let statement = try prepare(
            """
            INSERT INTO streams (session_id, kind, device_name, sample_rate, frame_ms)
            VALUES (?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sessionId)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, Self.transient)
        if let deviceName {
            sqlite3_bind_text(statement, 3, deviceName, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, Int64(sampleRate))
        sqlite3_bind_int64(statement, 5, Int64(frameMs))
        try step(statement)
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - 低レベル

    func exec(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorPointer)
            throw StoreError.exec(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StoreError.prepare(lastErrorMessage())
        }
        return statement
    }

    func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw StoreError.step(lastErrorMessage())
        }
    }

    func lastErrorMessage() -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown" }
        return String(cString: message)
    }
}

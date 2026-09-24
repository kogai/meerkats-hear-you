import Foundation
import SQLite3

public enum StoreError: Error, Equatable {
    case open(String)
    case exec(String)
    case prepare(String)
    case step(String)
}

/// 観測しているストリームの種類。
/// output は相手の声がこちらでどう鳴っているかで、取得手段は ADR-0008 で決めた。
/// 同じ異常でも、どちらのストリームで起きたかで利用者にとっての意味が変わる。
public enum StreamKind: String {
    case mic
    case output
}

/// ADR-0004 の記録先。macOS同梱の libsqlite3 をそのまま使うため、インストール作業は発生しない。
///
/// セッションは記録のひとまとまり、ストリームはその中の音の経路(マイク、受信音声)。
/// **アンカーもストリーム単位で持つ**(ADR-0015 決定5)。
///
/// 以前はセッション単位で、「同じ機械の同じ時計で観測されるのだから二重に持つ必要がない」と
/// 書いていた。**時計は同じでも、各ストリームの `monotonic_us` が実時刻の何マイクロ秒に
/// 当たるかは同じでない。** そこはデバイスのサンプルクロックが決めるので、ストリームごとに
/// 実測した対応を持たないと換算できない。
public final class RecordingStore {
    private var db: OpaquePointer?

    /// **接続を叩くスレッドが2本ある。** マイクのタップと、受信音声のIOブロック
    /// (ADR-0008)。`SQLITE_OPEN_FULLMUTEX` は呼び出し1つずつを直列にするだけで、
    /// **呼び出しをまたぐ対を守らない。** 守れていないものが2つある。
    ///
    /// - `appendSeconds` の `BEGIN` と `COMMIT` の対。割り込まれると、入れ子の `BEGIN` で
    ///   失敗するか、**他方のトランザクションを締める**
    /// - `addStream` の挿入と `sqlite3_last_insert_rowid` の対。間に別スレッドの挿入が入ると、
    ///   **別の行のIDを自分のストリームIDとして持つ。** 以後その記録は別のストリームに付く
    ///
    /// どちらも静かに壊れるので、**書き込む口だけ**をこの錠で直列にする。
    ///
    /// **読み出す口には掛けない。** 掛けると、分析ウインドウが全行を読む間、音のスレッドが
    /// そこで待つ。ADR-0016 はその競合を一度「誤りである」と取り下げている——FULLMUTEX の
    /// ミューテックスはAPI呼び出しごとに取れて放されるので、音のスレッドが待つのは読み手の
    /// `sqlite3_step` 1回ぶんにすぎない。**錠を掛けると、取り下げたはずの競合が本当になる。**
    ///
    /// 読み出しを守らないので、**読み手が繰り返している最中の `COMMIT` が弾かれうる**
    /// 経路は残る。これは ADR-0016 決定7 の「分析ウインドウの読み出しは別接続で開く」で
    /// 閉じるもので、接続を分ければ読み書きは互いを待たなくなる。
    ///
    /// **音のスレッドで錠を取ることになる。** そこは既に SQLite まで書いているので、
    /// 書き込み同士の待ちの桁は変わらない(相手のコミットは元から待たされていた)。
    /// ただし `NSRecursiveLock` も `PipelineBox` の `NSLock` と同じく優先度継承を持たない。
    /// **ADR-0016 決定1 を実装して音のスレッドから記録を追い出すとき、この錠も一緒に外す。**
    /// リングの向こう側に錠が残ると、決定1 が空振りする。
    ///
    /// 再帰錠にしてあるのは、公開の口が互いを呼んでも死なないようにするため。
    /// **いまは互いを呼んでいるものは無い。** 将来の並べ替えに対する備えである。
    let connectionLock = NSRecursiveLock()

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
        try createRecordSchema()
    }

    deinit {
        sqlite3_close_v2(db)
    }

    public func close() {
        connectionLock.lock()
        defer { connectionLock.unlock() }
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
        connectionLock.lock()
        defer { connectionLock.unlock() }
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
        connectionLock.lock()
        defer { connectionLock.unlock() }
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
        connectionLock.lock()
        defer { connectionLock.unlock() }
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

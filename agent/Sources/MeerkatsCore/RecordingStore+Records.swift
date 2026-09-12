import Foundation
import SQLite3

/// 記録そのものの読み書き。スキーマとセッション管理は RecordingStore 本体にある。
extension RecordingStore {
    func createRecordSchema() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS clock_anchors (
              session_id    INTEGER NOT NULL REFERENCES sessions(id),
              monotonic_us  INTEGER NOT NULL,
              wall_us       INTEGER NOT NULL,
              PRIMARY KEY (session_id, monotonic_us)
            );

            CREATE TABLE IF NOT EXISTS seconds (
              stream_id     INTEGER NOT NULL REFERENCES streams(id),
              monotonic_us  INTEGER NOT NULL,
              mean_dbfs     REAL NOT NULL,
              min_dbfs      REAL NOT NULL,
              max_dbfs      REAL NOT NULL,
              speech_ratio  REAL NOT NULL,
              clip_ratio    REAL NOT NULL,
              frame_count   INTEGER NOT NULL,
              PRIMARY KEY (stream_id, monotonic_us)
            );

            CREATE TABLE IF NOT EXISTS detail_windows (
              id            INTEGER PRIMARY KEY,
              stream_id     INTEGER NOT NULL REFERENCES streams(id),
              start_us      INTEGER NOT NULL,
              frame_count   INTEGER NOT NULL,
              trigger       TEXT NOT NULL,
              frames        BLOB NOT NULL
            );
            """
        )
    }

    public func appendAnchor(sessionId: Int64, _ anchor: ClockAnchor) throws {
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO clock_anchors (session_id, monotonic_us, wall_us)
            VALUES (?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sessionId)
        sqlite3_bind_int64(statement, 2, anchor.monotonicUs)
        sqlite3_bind_int64(statement, 3, anchor.wallUs)
        try step(statement)
    }

    /// 常時層をまとめて1トランザクションで書く。
    ///
    /// 1秒ごとに個別のトランザクションを張ると毎時3600回のコミットになり、終日動く
    /// 常駐プロセスではディスクとCPUを起こし続けることになる(ADR-0004)。
    /// どれだけ溜めてから呼ぶかは呼び出し側が決める。
    public func appendSeconds(streamId: Int64, _ records: [SecondRecord]) throws {
        guard !records.isEmpty else { return }

        try exec("BEGIN;")
        do {
            let statement = try prepare(
                """
                INSERT OR REPLACE INTO seconds
                  (stream_id, monotonic_us, mean_dbfs, min_dbfs, max_dbfs,
                   speech_ratio, clip_ratio, frame_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """
            )
            defer { sqlite3_finalize(statement) }

            for record in records {
                sqlite3_reset(statement)
                sqlite3_bind_int64(statement, 1, streamId)
                sqlite3_bind_int64(statement, 2, record.monotonicUs)
                sqlite3_bind_double(statement, 3, record.meanDbfs)
                sqlite3_bind_double(statement, 4, record.minDbfs)
                sqlite3_bind_double(statement, 5, record.maxDbfs)
                sqlite3_bind_double(statement, 6, record.speechRatio)
                sqlite3_bind_double(statement, 7, record.clipRatio)
                sqlite3_bind_int64(statement, 8, Int64(record.frameCount))
                try step(statement)
            }
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        try exec("COMMIT;")
    }

    public func appendDetailWindow(streamId: Int64, _ window: DetailWindow) throws {
        let encoded = DetailFrameCodec.encode(window.frames)
        let statement = try prepare(
            """
            INSERT INTO detail_windows (stream_id, start_us, frame_count, trigger, frames)
            VALUES (?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)
        sqlite3_bind_int64(statement, 2, window.startUs)
        sqlite3_bind_int64(statement, 3, Int64(window.frames.count))
        sqlite3_bind_text(statement, 4, window.trigger, -1, Self.transient)
        encoded.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(statement, 5, raw.baseAddress, Int32(raw.count), Self.transient)
        }
        try step(statement)
    }

    // MARK: - 読み出し

    public func seconds(streamId: Int64, fromUs: Int64 = .min, toUs: Int64 = .max) throws
        -> [SecondRecord]
    {
        let statement = try prepare(
            """
            SELECT monotonic_us, mean_dbfs, min_dbfs, max_dbfs, speech_ratio, clip_ratio,
                   frame_count
            FROM seconds
            WHERE stream_id = ? AND monotonic_us BETWEEN ? AND ?
            ORDER BY monotonic_us;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)
        sqlite3_bind_int64(statement, 2, fromUs)
        sqlite3_bind_int64(statement, 3, toUs)

        var out: [SecondRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(
                SecondRecord(
                    monotonicUs: sqlite3_column_int64(statement, 0),
                    meanDbfs: sqlite3_column_double(statement, 1),
                    minDbfs: sqlite3_column_double(statement, 2),
                    maxDbfs: sqlite3_column_double(statement, 3),
                    speechRatio: sqlite3_column_double(statement, 4),
                    clipRatio: sqlite3_column_double(statement, 5),
                    frameCount: Int(sqlite3_column_int64(statement, 6))
                )
            )
        }
        return out
    }

    public func anchors(sessionId: Int64) throws -> [ClockAnchor] {
        let statement = try prepare(
            """
            SELECT monotonic_us, wall_us FROM clock_anchors
            WHERE session_id = ? ORDER BY monotonic_us;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sessionId)

        var out: [ClockAnchor] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(
                ClockAnchor(
                    monotonicUs: sqlite3_column_int64(statement, 0),
                    wallUs: sqlite3_column_int64(statement, 1)
                )
            )
        }
        return out
    }

    public func detailWindows(streamId: Int64, frameDurationUs: Int64) throws -> [DetailWindow] {
        let statement = try prepare(
            """
            SELECT start_us, trigger, frames FROM detail_windows
            WHERE stream_id = ? ORDER BY start_us;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)

        var out: [DetailWindow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let startUs = sqlite3_column_int64(statement, 0)
            let trigger = String(cString: sqlite3_column_text(statement, 1))
            let byteCount = Int(sqlite3_column_bytes(statement, 2))
            let data = sqlite3_column_blob(statement, 2)
                .map { Data(bytes: $0, count: byteCount) } ?? Data()

            out.append(
                DetailWindow(
                    startUs: startUs,
                    trigger: trigger,
                    frames: try DetailFrameCodec.decode(
                        data, startUs: startUs, frameDurationUs: frameDurationUs
                    )
                )
            )
        }
        return out
    }
}

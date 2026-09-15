import Foundation
import SQLite3

/// 記録そのものの読み書き。スキーマとセッション管理は RecordingStore 本体にある。
extension RecordingStore {
    func createRecordSchema() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS clock_anchors (
              stream_id     INTEGER NOT NULL REFERENCES streams(id),
              monotonic_us  INTEGER NOT NULL,
              wall_us       INTEGER NOT NULL,
              PRIMARY KEY (stream_id, monotonic_us)
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

            CREATE TABLE IF NOT EXISTS gaps (
              id            INTEGER PRIMARY KEY,
              stream_id     INTEGER NOT NULL REFERENCES streams(id),
              start_us      INTEGER NOT NULL,
              end_us        INTEGER NOT NULL,
              reason        TEXT NOT NULL
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

    /// **アンカーはストリーム単位で持つ**(ADR-0015 決定5)。
    ///
    /// セッション単位にしていたのは「同じ機械の同じ時計で観測されるのだから二重に持つ
    /// 必要がない」という理由だった。**時刻をフレーム数で刻む以上、これは成り立たない。**
    /// 2本のストリームは別のデバイスのクロックに乗っていて、公称レートからのずれ方が違う。
    /// 片方のアンカーでもう片方の時刻を換算すれば、その差だけ間違う。
    ///
    /// ADR-0015 決定6 で時計がセッションに1つになったので**原点は揃っている**が、
    /// 揃っているのは原点だけで、進み方は揃っていない。
    public func appendAnchor(streamId: Int64, _ anchor: ClockAnchor) throws {
        let statement = try prepare(
            """
            INSERT OR REPLACE INTO clock_anchors (stream_id, monotonic_us, wall_us)
            VALUES (?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)
        sqlite3_bind_int64(statement, 2, anchor.monotonicUs)
        sqlite3_bind_int64(statement, 3, anchor.wallUs)
        try step(statement)
    }

    /// 記録できなかった区間を残す(ADR-0015 決定7)。
    ///
    /// **主キーを `(stream_id, start_us)` にしない。** 音が戻らないまま打ち直しが続けば、
    /// 長さ0の空隙が同じ `start_us` で並ぶ。主キーにすると後の1本が前を消し、
    /// **何度途切れたのかが記録から消える。** 回数はそれ自体が読みたい値なので、
    /// 代理キーを置いて全部残す。
    public func appendGap(streamId: Int64, _ gap: RecordingGap) throws {
        let statement = try prepare(
            """
            INSERT INTO gaps (stream_id, start_us, end_us, reason)
            VALUES (?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)
        sqlite3_bind_int64(statement, 2, gap.startUs)
        sqlite3_bind_int64(statement, 3, gap.endUs)
        sqlite3_bind_text(statement, 4, gap.reason.rawValue, -1, RecordingStore.transient)
        try step(statement)
    }

    public func gaps(streamId: Int64) throws -> [RecordingGap] {
        let statement = try prepare(
            """
            SELECT start_us, end_us, reason FROM gaps
            WHERE stream_id = ? ORDER BY id;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)

        var out: [RecordingGap] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let raw = String(cString: sqlite3_column_text(statement, 2))
            // **読めない理由で行を落とさない。** 新しい版が足した理由を古い版で読むと、
            // 落とす実装では空隙そのものが消える。理由が読めないことと、
            // 途切れていないことは別である。長さは読めている。
            let reason = RecordingGap.Reason(rawValue: raw) ?? .unknown
            out.append(
                RecordingGap(
                    startUs: sqlite3_column_int64(statement, 0),
                    endUs: sqlite3_column_int64(statement, 1),
                    reason: reason
                )
            )
        }
        return out
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

    public func anchors(streamId: Int64) throws -> [ClockAnchor] {
        let statement = try prepare(
            """
            SELECT monotonic_us, wall_us FROM clock_anchors
            WHERE stream_id = ? ORDER BY monotonic_us;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)

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

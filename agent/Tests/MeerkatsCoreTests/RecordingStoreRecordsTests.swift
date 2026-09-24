import Foundation
import SQLite3
import XCTest
@testable import MeerkatsCore

final class RecordingStoreRecordsTests: XCTestCase {
    private var path = ""
    private var store: RecordingStore!
    private var streamId: Int64 = 0
    private var sessionId: Int64 = 0

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        store = try RecordingStore(path: path)
        sessionId = try store.startSession(wallUs: 0, agentVersion: "0.1")
        streamId = try store.addStream(
            sessionId: sessionId, kind: .mic, deviceName: nil, sampleRate: 48_000, frameMs: 20
        )
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func record(_ us: Int64, mean: Double = -25) -> SecondRecord {
        SecondRecord(
            monotonicUs: us, meanDbfs: mean, minDbfs: mean - 5, maxDbfs: mean + 5,
            speechRatio: 0.6, clipRatio: 0.01, frameCount: 50
        )
    }

    /// **2本のストリームが同時に書く。** 受信音声(ADR-0008)を起こすと、マイクのタップと
    /// Core Audio のIOブロックの2本がこの接続を叩く。
    ///
    /// 接続を直列にしていないと、割り込まれた側が入れ子の `BEGIN` で投げ、**そのバッチが
    /// 書かれないまま落ちる。** `SQLITE_OPEN_FULLMUTEX` は呼び出し1つずつしか直列にしない。
    ///
    /// **このテストが見ているのはそこまでである。** 2つ断っておく。
    ///
    /// - `DispatchQueue.concurrentPerform` は**並行に走ることを保証しない。** 逐次に回れば、
    ///   錠を外しても緑になる。「錠が無いと必ず落ちる」ことは固定できていない
    /// - `addStream` と `sqlite3_last_insert_rowid` の対は**覆っていない。** 錠のもう1つの
    ///   動機はそちらで、被害は静か(記録がまるごと別のストリームに付く)なぶん重い
    func testConcurrentWritersFromTwoStreams() throws {
        let otherStreamId = try store.addStream(
            sessionId: sessionId, kind: .output, deviceName: nil, sampleRate: 48_000, frameMs: 20
        )
        let rounds = 40
        let batch = 25
        let failures = ErrorBox()

        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            let stream = worker == 0 ? self.streamId : otherStreamId
            for round in 0 ..< rounds {
                let base = Int64(round * batch) * 1_000_000
                let records = (0 ..< batch).map {
                    self.record(base + Int64($0) * 1_000_000)
                }
                do {
                    try self.store.appendSeconds(streamId: stream, records)
                } catch {
                    failures.add(error)
                }
            }
        }

        XCTAssertEqual(failures.all.map { "\($0)" }, [], "同時に書いて失敗した")
        XCTAssertEqual(try store.seconds(streamId: streamId).count, rounds * batch)
        XCTAssertEqual(try store.seconds(streamId: otherStreamId).count, rounds * batch)
    }

    /// 別スレッドからの失敗を集める。テスト側の集約で競合すると、
    /// 何を確かめていたのか分からなくなる。
    private final class ErrorBox {
        private let lock = NSLock()
        private var errors: [Error] = []

        func add(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            errors.append(error)
        }

        var all: [Error] {
            lock.lock()
            defer { lock.unlock() }
            return errors
        }
    }

    func testSecondsRoundTrip() throws {
        let written = (0 ..< 5).map { record(Int64($0) * 1_000_000, mean: -20 - Double($0)) }
        try store.appendSeconds(streamId: streamId, written)

        let read = try store.seconds(streamId: streamId)
        XCTAssertEqual(read.count, 5)
        XCTAssertEqual(read.map(\.monotonicUs), written.map(\.monotonicUs))
        XCTAssertEqual(read[0].meanDbfs, -20, accuracy: 0.0001)
        XCTAssertEqual(read[0].minDbfs, -25, accuracy: 0.0001)
        XCTAssertEqual(read[0].frameCount, 50)
    }

    func testSecondsAreOrderedByTime() throws {
        try store.appendSeconds(
            streamId: streamId,
            [record(3_000_000), record(1_000_000), record(2_000_000)]
        )
        XCTAssertEqual(
            try store.seconds(streamId: streamId).map(\.monotonicUs),
            [1_000_000, 2_000_000, 3_000_000]
        )
    }

    /// 分析側は時間範囲で引く。これがADR-0004で常時層を行として持つと決めた理由。
    func testSecondsCanBeQueriedByRange() throws {
        try store.appendSeconds(
            streamId: streamId,
            (0 ..< 10).map { record(Int64($0) * 1_000_000) }
        )
        let slice = try store.seconds(
            streamId: streamId, fromUs: 3_000_000, toUs: 5_000_000
        )
        XCTAssertEqual(slice.map(\.monotonicUs), [3_000_000, 4_000_000, 5_000_000])
    }

    func testEmptyBatchIsNoOp() throws {
        try store.appendSeconds(streamId: streamId, [])
        XCTAssertTrue(try store.seconds(streamId: streamId).isEmpty)
    }

    /// 同じ時刻を二重に書いても行が増えないこと。再起動後の重複を防ぐ。
    func testSameTimestampIsReplaced() throws {
        try store.appendSeconds(streamId: streamId, [record(1_000_000, mean: -30)])
        try store.appendSeconds(streamId: streamId, [record(1_000_000, mean: -40)])

        let read = try store.seconds(streamId: streamId)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].meanDbfs, -40, accuracy: 0.0001)
    }

    func testAnchorsRoundTrip() throws {
        // 単調時計が300秒進む間に、実時刻は300秒と1msぶん進んだ状況。
        // この1msの食い違いが、そのまま換算の不確かさになる。
        try store.appendAnchor(streamId: streamId, ClockAnchor(monotonicUs: 0, wallUs: 1_000))
        try store.appendAnchor(
            streamId: streamId, ClockAnchor(monotonicUs: 300_000_000, wallUs: 300_002_000)
        )

        let anchors = try store.anchors(streamId: streamId)
        XCTAssertEqual(anchors.streamId, streamId)
        XCTAssertEqual(anchors.anchors.count, 2)
        XCTAssertEqual(anchors.anchors[0], ClockAnchor(monotonicUs: 0, wallUs: 1_000))

        // 読み出したアンカーがそのまま換算に使えること。
        let estimate = ClockConversion.wallTime(forMonotonicUs: 150_000_000, in: anchors)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate?.uncertaintyUs, 1_000, "この区間の食い違いが不確かさになる")
    }

    /// 詳細層はBLOBとして保存され、読み出すとフレームに戻ること。
    func testDetailWindowRoundTripThroughBlob() throws {
        // 型推論が重くならないよう、要素ごとに明示的に組み立てる。
        var frames: [FrameMetrics] = []
        for index in 0 ..< 100 {
            let clip: Double = index % 20 == 0 ? 0.5 : 0.0
            frames.append(
                FrameMetrics(
                    monotonicUs: Int64(index) * 20_000,
                    dbfs: -30.0 - Double(index % 10),
                    clipRatio: clip,
                    isSpeech: index % 3 == 0
                )
            )
        }
        try store.appendDetailWindow(
            streamId: streamId,
            DetailWindow(startUs: 0, trigger: "dropout", frames: frames)
        )

        let windows = try store.detailWindows(streamId: streamId, frameDurationUs: 20_000)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].trigger, "dropout")
        XCTAssertEqual(windows[0].frames.count, 100)

        for (original, restored) in zip(frames, windows[0].frames) {
            XCTAssertEqual(restored.dbfs, original.dbfs, accuracy: 0.001)
            XCTAssertEqual(restored.isSpeech, original.isSpeech)
            XCTAssertEqual(restored.monotonicUs, original.monotonicUs)
        }
    }

    func testDetailWindowsAreOrderedByStart() throws {
        for start in [Int64(5_000_000), 1_000_000, 3_000_000] {
            try store.appendDetailWindow(
                streamId: streamId,
                DetailWindow(
                    startUs: start, trigger: "clipping",
                    frames: [FrameMetrics(monotonicUs: start, dbfs: -3, clipRatio: 1, isSpeech: true)]
                )
            )
        }
        XCTAssertEqual(
            try store.detailWindows(streamId: streamId, frameDurationUs: 20_000).map(\.startUs),
            [1_000_000, 3_000_000, 5_000_000]
        )
    }

    /// 別のストリームの記録が混ざらないこと。
    func testRecordsAreScopedToStream() throws {
        let other = try store.addStream(
            sessionId: sessionId, kind: .output, deviceName: nil,
            sampleRate: 48_000, frameMs: 20
        )
        try store.appendSeconds(streamId: streamId, [record(0)])
        try store.appendSeconds(streamId: other, [record(0), record(1_000_000)])

        XCTAssertEqual(try store.seconds(streamId: streamId).count, 1)
        XCTAssertEqual(try store.seconds(streamId: other).count, 2)
    }

    func testDataSurvivesReopen() throws {
        try store.appendSeconds(streamId: streamId, [record(1_000_000, mean: -33)])
        store.close()

        store = try RecordingStore(path: path)
        let read = try store.seconds(streamId: streamId)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].meanDbfs, -33, accuracy: 0.0001)
    }

    // MARK: - 空隙(ADR-0015 決定7)

    func testGapsRoundTrip() throws {
        let written = [
            RecordingGap(startUs: 0, endUs: 300_000, reason: .start),
            RecordingGap(startUs: 60_000_000, endUs: 61_500_000, reason: .deviceChange),
        ]
        for gap in written {
            try store.appendGap(streamId: streamId, gap)
        }

        XCTAssertEqual(try store.gaps(streamId: streamId), written)
    }

    /// **同じ `start_us` の空隙が並んでも、どれも消えない。**
    ///
    /// 音が戻らないまま打ち直しが続くと、長さ0の空隙が同じ時刻に並ぶ。
    /// 主キーを `(stream_id, start_us)` にしていると後の1本が前を消し、
    /// 何度途切れたのかが記録から消える。回数はそれ自体が読みたい値である。
    func testGapsWithTheSameStartAreAllKept() throws {
        for _ in 0 ..< 3 {
            try store.appendGap(
                streamId: streamId,
                RecordingGap(startUs: 1_000_000, endUs: 1_000_000, reason: .resume)
            )
        }

        XCTAssertEqual(try store.gaps(streamId: streamId).count, 3)
    }

    /// **知らない理由でも空隙は残る。** 新しい版が書いた理由を古い版で読む場面で、
    /// 行ごと落とすと「途切れていなかった」ことになる。理由が読めないことと、
    /// 途切れていないことは別である。
    func testUnknownReasonKeepsTheGap() throws {
        let statement = try store.prepare(
            "INSERT INTO gaps (stream_id, start_us, end_us, reason) VALUES (?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, streamId)
        sqlite3_bind_int64(statement, 2, 2_000_000)
        sqlite3_bind_int64(statement, 3, 5_000_000)
        sqlite3_bind_text(statement, 4, "sampleTimeGap", -1, RecordingStore.transient)
        try store.step(statement)

        let read = try store.gaps(streamId: streamId)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.reason, .unknown)
        XCTAssertEqual(read.first?.durationUs, 3_000_000)
    }

    /// **2本のストリームのアンカーが混ざらない。**
    ///
    /// 防ぎたいのは消失ではなく**換算の混線**である。セッション単位のままだと、
    /// 引いた配列に2本ぶんが混ざる。混ざった列は間隔が細かくなるので `interpolate` の
    /// 不確かさは**小さく**出るのに、内挿の相手は別のクロックに乗った点なので値は外れる。
    /// **混ぜたほうが自信ありげな、間違った答えが返る。**
    ///
    /// (`INSERT OR REPLACE` による消失のほうは、ADR-0015 決定6 で時計が1つになった時点で
    /// ほぼ起きなくなっていた。アンカーの単調時刻が `baseUs + 300秒 * n` に限られ、
    /// 衝突には2本の `baseUs` の差が300秒の倍数であることが要るため。)
    func testAnchorsAreScopedToTheirStream() throws {
        let other = try store.addStream(
            sessionId: sessionId, kind: .output, deviceName: nil, sampleRate: 48_000, frameMs: 20
        )

        // 同じ単調時刻に、別々の実時刻で打つ。デバイスのクロックのずれ方が違うので、
        // 同じ原点から同じだけ進んでも実時刻は一致しない。
        try store.appendAnchor(streamId: streamId, ClockAnchor(monotonicUs: 0, wallUs: 1_000))
        try store.appendAnchor(streamId: other, ClockAnchor(monotonicUs: 0, wallUs: 9_000))

        XCTAssertEqual(
            try store.anchors(streamId: streamId).anchors,
            [ClockAnchor(monotonicUs: 0, wallUs: 1_000)]
        )
        XCTAssertEqual(
            try store.anchors(streamId: other).anchors,
            [ClockAnchor(monotonicUs: 0, wallUs: 9_000)]
        )
    }

    /// **同じストリームの同じ単調時刻が二度来たら投げる。黙って上書きしない。**
    ///
    /// 上書きすると、ドリフトを測るために置いた点が消える。いまの書き手は1本の
    /// ストリームの中で単調時刻を厳密に増やすので、ここに来ること自体が前提の崩れを意味する。
    func testAnchorRefusesADuplicateWithinTheSameStream() throws {
        try store.appendAnchor(streamId: streamId, ClockAnchor(monotonicUs: 0, wallUs: 1_000))

        XCTAssertThrowsError(
            try store.appendAnchor(streamId: streamId, ClockAnchor(monotonicUs: 0, wallUs: 2_000))
        )
        let kept = try store.anchors(streamId: streamId)
        XCTAssertEqual(kept.anchors, [ClockAnchor(monotonicUs: 0, wallUs: 1_000)], "先の点が残る")
    }

    /// **知らないストリームのアンカーは入らない。**
    /// 外部キーが効いていないと、どのストリームにも属さない行が静かに溜まる。
    func testAnchorRequiresAnExistingStream() {
        XCTAssertThrowsError(
            try store.appendAnchor(
                streamId: streamId + 9_999, ClockAnchor(monotonicUs: 0, wallUs: 1)
            )
        ) { error in
            // **落ちた理由まで見る。** 見ないと、SQLが壊れて `prepare` が失敗しても
            // このテストは緑のまま通り、外部キーが効いていないことに気づけない。
            XCTAssertTrue(
                "\(error)".contains("FOREIGN KEY"), "外部キー違反ではない誤り: \(error)"
            )
        }
    }
}

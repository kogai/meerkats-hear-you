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
        try store.appendAnchor(sessionId: sessionId, ClockAnchor(monotonicUs: 0, wallUs: 1_000))
        try store.appendAnchor(
            sessionId: sessionId, ClockAnchor(monotonicUs: 300_000_000, wallUs: 300_002_000)
        )

        let anchors = try store.anchors(sessionId: sessionId)
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(anchors[0], ClockAnchor(monotonicUs: 0, wallUs: 1_000))

        // 読み出したアンカーがそのまま換算に使えること。
        let estimate = ClockConversion.wallTime(forMonotonicUs: 150_000_000, anchors: anchors)
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
}

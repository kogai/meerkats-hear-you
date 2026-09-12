import Foundation
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
        try store.appendAnchor(sessionId: sessionId, ClockAnchor(monotonicUs: 0, wallUs: 1_000))
        try store.appendAnchor(
            sessionId: sessionId, ClockAnchor(monotonicUs: 300_000_000, wallUs: 300_001_000)
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
        let frames = (0 ..< 100).map { index in
            FrameMetrics(
                monotonicUs: Int64(index) * 20_000,
                dbfs: -30 - Double(index % 10),
                clipRatio: index % 20 == 0 ? 0.5 : 0,
                isSpeech: index % 3 == 0
            )
        }
        try store.appendDetailWindow(
            streamId: streamId,
            DetailWindow(startUs: 0, trigger: AnomalyKind.dropout.rawValue, frames: frames)
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
}

import Foundation
import XCTest
@testable import MeerkatsCore

private final class CollectingSink: RecordingPipeline.Sink {
    var seconds: [SecondRecord] = []
    var details: [DetailWindow] = []
    var anchors: [ClockAnchor] = []
    var gaps: [RecordingGap] = []
    /// 1回の write(seconds:) で渡された件数。まとめ書きの区切りを確かめるのに使う。
    var batchSizes: [Int] = []

    func write(seconds records: [SecondRecord]) throws {
        seconds.append(contentsOf: records)
        batchSizes.append(records.count)
    }

    func write(detail: DetailWindow) throws { details.append(detail) }
    func write(anchor: ClockAnchor) throws { anchors.append(anchor) }
    func write(gap: RecordingGap) throws { gaps.append(gap) }
}

final class RecordingPipelineTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let frameMs = 20

    /// `makePipeline` が差し込む時計。テストから進められるように持っておく。
    private var clock = FakeClock()

    private func makePipeline(
        _ configure: (inout RecordingPipeline.Configuration) -> Void = { _ in }
    ) -> (RecordingPipeline, CollectingSink, LiveState) {
        var configuration = RecordingPipeline.Configuration(
            frameMs: frameMs, sampleRate: sampleRate
        )
        configure(&configuration)
        let sink = CollectingSink()
        let state = LiveState()
        clock = FakeClock()
        return (
            RecordingPipeline(
                configuration: configuration, sink: sink, liveState: state, clock: clock
            ),
            sink, state
        )
    }

    /// 一定振幅の信号を指定秒数ぶん作る。
    private func samples(seconds: Double, amplitude: Float) -> [Float] {
        [Float](repeating: amplitude, count: Int(sampleRate * seconds))
    }

    func testFrameLengthFollowsSampleRate() {
        let configuration = RecordingPipeline.Configuration(frameMs: 20, sampleRate: 48_000)
        XCTAssertEqual(configuration.frameLength, 960)
        XCTAssertEqual(configuration.frameDurationUs, 20_000)
    }

    /// 実測に近い約100msのバッファを流しても、1秒ぶんのレコードが出ること。
    func testProducesOneRecordPerSecondFromIrregularBuffers() throws {
        let (pipeline, sink, _) = makePipeline { $0.flushIntervalSeconds = 1 }

        // 4963サンプル(約103ms)ずつ、合計3秒ぶん強を流す
        let chunk = [Float](repeating: 0.1, count: 4963)
        for _ in 0 ..< 30 {
            try pipeline.ingest(chunk, wallUs: 0)
        }
        try pipeline.finish()

        // 4963 * 30 / 960 = 155フレーム → 3秒ぶん(150フレーム)+端数
        XCTAssertEqual(sink.seconds.count, 4, "満了3件と端数1件")
        XCTAssertEqual(sink.seconds.prefix(3).map(\.frameCount), [50, 50, 50])
        XCTAssertLessThan(sink.seconds[3].frameCount, 50)
    }

    /// 時刻はフレーム番号から決まる。処理時刻を読むと、1バッファぶんのフレームが
    /// ほぼ同じ時刻になってレベルの時系列として使えない。
    func testTimestampsAreEvenlySpaced() throws {
        let (pipeline, sink, _) = makePipeline { $0.flushIntervalSeconds = 1 }
        try pipeline.ingest(samples(seconds: 3, amplitude: 0.1), wallUs: 0)
        try pipeline.flush()

        XCTAssertEqual(sink.seconds.map(\.monotonicUs), [0, 1_000_000, 2_000_000])
    }

    /// まとめ書きが効いていること。1秒ごとに書くと毎時3600回のコミットになる。
    /// 件数まで見るのは、区切りの基準を間違えるとひと塊だけ件数がずれるため。
    func testSecondsAreWrittenInBatches() throws {
        let (pipeline, sink, _) = makePipeline { $0.flushIntervalSeconds = 10 }
        try pipeline.ingest(samples(seconds: 25, amplitude: 0.1), wallUs: 0)

        XCTAssertEqual(sink.batchSizes, [10, 10], "10秒ぶんずつ、同じ件数で書かれる")
        XCTAssertEqual(sink.seconds.count, 20)

        try pipeline.finish()
        XCTAssertEqual(sink.batchSizes, [10, 10, 5], "締めで残りも書かれる")
        XCTAssertEqual(sink.seconds.count, 25)
        XCTAssertEqual(
            sink.seconds.map(\.monotonicUs).first, 0, "先頭から欠けずに書かれている"
        )
        XCTAssertEqual(sink.seconds.map(\.monotonicUs).last, 24_000_000)
    }

    func testAnchorIsWrittenAtStartAndInterval() throws {
        let (pipeline, sink, _) = makePipeline { $0.anchorIntervalSeconds = 2 }
        try pipeline.ingest(samples(seconds: 5, amplitude: 0.1), wallUs: 1_000_000)

        XCTAssertGreaterThanOrEqual(sink.anchors.count, 3, "開始時と2秒ごと")
        XCTAssertEqual(sink.anchors.first?.monotonicUs, 0)
        XCTAssertEqual(sink.anchors.first?.wallUs, 1_000_000)
    }

    /// 常時表示が読む状態が更新されること。SQLiteを経由しない。
    func testLiveStateIsUpdated() throws {
        let (pipeline, _, state) = makePipeline()
        try pipeline.ingest(samples(seconds: 2, amplitude: 0.1), wallUs: 0)

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.meanDbfs, Levels.rmsDbfs([0.1]), accuracy: 0.01)
        XCTAssertEqual(snapshot.recentLevels.count, 2)
    }

    /// 出力先を強参照で持つこと。弱参照にすると、呼び出し側が出力先を変数に
    /// 残さなかった瞬間に、例外も出ないまま記録だけが落ちる。
    func testPipelineKeepsSinkAlive() throws {
        weak var observed: CollectingSink?
        let pipeline: RecordingPipeline
        do {
            let sink = CollectingSink()
            observed = sink
            pipeline = RecordingPipeline(
                sink: sink, liveState: LiveState(), clock: FakeClock()
            )
        }

        try pipeline.ingest(samples(seconds: 1, amplitude: 0.1), wallUs: 0)
        try pipeline.flush()

        XCTAssertNotNil(observed, "出力先が解放されると記録が静かに落ちる")
        XCTAssertEqual(observed?.seconds.count, 1)
    }

    /// クリッピングが続けば異常として検知され、詳細層が書き出されること。
    func testSustainedClippingWritesDetailAndNotifies() throws {
        let (pipeline, sink, _) = makePipeline()
        var notified: [AnomalyKind] = []
        pipeline.onAnomaly = { notified.append($0) }

        try pipeline.ingest(samples(seconds: 6, amplitude: 1.0), wallUs: 0)
        try pipeline.finish()

        XCTAssertEqual(notified, [.clipping], "入った瞬間の1回だけ")
        XCTAssertEqual(sink.details.count, 1)
        XCTAssertEqual(sink.details.first?.trigger, AnomalyKind.clipping.rawValue)
        XCTAssertFalse(sink.details.first?.frames.isEmpty ?? true)
    }

    /// 詳細層には異常の「開始前」のフレームが含まれること。
    /// リングバッファを常時回している理由そのもの。
    func testDetailWindowIncludesFramesBeforeTheAnomaly() throws {
        let (pipeline, sink, _) = makePipeline { $0.detailWindowSeconds = 10 }
        pipeline.onAnomaly = { _ in }

        try pipeline.ingest(samples(seconds: 2, amplitude: 0.1), wallUs: 0)  // 正常
        try pipeline.ingest(samples(seconds: 4, amplitude: 1.0), wallUs: 0)  // クリップ
        try pipeline.finish()

        let window = try XCTUnwrap(sink.details.first)
        XCTAssertEqual(window.startUs, 0, "異常より前から始まっている")
        XCTAssertTrue(
            window.frames.contains { $0.clipRatio == 0 },
            "クリップしていないフレームも含まれる"
        )
    }

    /// 常時表示にも継続中の異常が映ること。表示はここからしか読まない。
    func testLiveStateCarriesActiveAnomalies() throws {
        let (pipeline, _, state) = makePipeline()
        try pipeline.ingest(samples(seconds: 6, amplitude: 1.0), wallUs: 0)

        XCTAssertEqual(state.snapshot().activeAnomalies, [.clipping])
    }

    /// 無音が続くだけでは異常にしない。発話が無い区間まで拾うと通知が鳴り続け、
    /// 利用者は通知を切る。
    func testQuietSignalDoesNotTriggerAnomaly() throws {
        let (pipeline, sink, _) = makePipeline()
        var notified: [AnomalyKind] = []
        pipeline.onAnomaly = { notified.append($0) }

        try pipeline.ingest(samples(seconds: 6, amplitude: 0.0005), wallUs: 0)
        try pipeline.finish()

        XCTAssertTrue(notified.isEmpty)
        XCTAssertTrue(sink.details.isEmpty)
    }

    // MARK: - 基準点(ADR-0015 決定1)

    /// 最初のバッファで基準を決める。**0 に揃えない。**
    ///
    /// セッションの開始からキャプチャが始まるまでの時間はストリームごとに違うので、
    /// 揃えると、ずれて始まった2本を「同時に始まった」と記録することになる。
    /// そこまでの区間は測れていなかった区間なので、空隙として残す。
    func testFirstBufferSetsTheBaseFromTheClock() throws {
        let (pipeline, sink, _) = makePipeline()
        clock.us = 300_000

        try pipeline.ingest(samples(seconds: 1, amplitude: 0.5), wallUs: 0)
        try pipeline.finish()

        XCTAssertEqual(sink.gaps.count, 1)
        XCTAssertEqual(sink.gaps.first?.reason, .start)
        XCTAssertEqual(sink.gaps.first?.startUs, 0)
        XCTAssertEqual(sink.gaps.first?.endUs, 300_000)
        XCTAssertEqual(sink.seconds.first?.monotonicUs, 300_000)
    }

    /// 基準が決まったあとは、フレーム数だけで刻む。
    /// **時計はもう読まない。** 読むと、バッファの到着ジッタが時系列に入る。
    func testTimestampsFollowFrameCountNotTheClock() throws {
        let (pipeline, sink, _) = makePipeline()

        try pipeline.ingest(samples(seconds: 1, amplitude: 0.5), wallUs: 0)
        // 時計が飛んでも、刻みは変わらない。
        clock.us = 99_000_000
        try pipeline.ingest(samples(seconds: 2, amplitude: 0.5), wallUs: 0)
        try pipeline.finish()

        XCTAssertEqual(sink.seconds.map(\.monotonicUs), [0, 1_000_000, 2_000_000])
        XCTAssertEqual(sink.gaps.count, 1, "基準を打ち直すのは最初の1回だけ")
    }
}

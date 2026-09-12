import Foundation
import XCTest
@testable import MeerkatsCore

private final class CollectingSink: RecordingPipeline.Sink {
    var seconds: [SecondRecord] = []
    var anchors: [ClockAnchor] = []
    /// 1回の write(seconds:) で渡された件数。まとめ書きの区切りを確かめるのに使う。
    var batchSizes: [Int] = []

    func write(seconds records: [SecondRecord]) throws {
        seconds.append(contentsOf: records)
        batchSizes.append(records.count)
    }

    func write(anchor: ClockAnchor) throws { anchors.append(anchor) }
}

final class RecordingPipelineTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let frameMs = 20

    private func makePipeline(
        _ configure: (inout RecordingPipeline.Configuration) -> Void = { _ in }
    ) -> (RecordingPipeline, CollectingSink, LiveState) {
        var configuration = RecordingPipeline.Configuration(
            frameMs: frameMs, sampleRate: sampleRate
        )
        configure(&configuration)
        let sink = CollectingSink()
        let state = LiveState()
        return (
            RecordingPipeline(configuration: configuration, sink: sink, liveState: state),
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
            pipeline = RecordingPipeline(sink: sink, liveState: LiveState())
        }

        try pipeline.ingest(samples(seconds: 1, amplitude: 0.1), wallUs: 0)
        try pipeline.flush()

        XCTAssertNotNil(observed, "出力先が解放されると記録が静かに落ちる")
        XCTAssertEqual(observed?.seconds.count, 1)
    }
}

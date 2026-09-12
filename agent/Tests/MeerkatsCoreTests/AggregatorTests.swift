import XCTest
@testable import MeerkatsCore

final class AggregatorTests: XCTestCase {
    private func metrics(
        us: Int64, dbfs: Double, speech: Bool = false, clip: Double = 0
    ) -> FrameMetrics {
        FrameMetrics(monotonicUs: us, dbfs: dbfs, clipRatio: clip, isSpeech: speech)
    }

    func testEmitsOncePerSecond() {
        var aggregator = Aggregator(frameMs: 20)
        XCTAssertEqual(aggregator.framesPerRecord, 50)

        for index in 0 ..< 49 {
            XCTAssertNil(aggregator.push(metrics(us: Int64(index) * 20_000, dbfs: -30)))
        }
        XCTAssertNotNil(aggregator.push(metrics(us: 49 * 20_000, dbfs: -30)))
    }

    func testRecordCarriesTimestampOfFirstFrame() {
        var aggregator = Aggregator(frameMs: 20)
        var record: SecondRecord?
        for index in 0 ..< 50 {
            record = aggregator.push(metrics(us: 1_000_000 + Int64(index) * 20_000, dbfs: -30))
        }
        XCTAssertEqual(record?.monotonicUs, 1_000_000)
    }

    /// 1秒の中の瞬間的な落ち込みが min に残ること。
    /// これが平均に埋もれると、要望書が問題視する「一瞬の音の途切れ」を取り逃がす。
    func testMinPreservesMomentaryDropout() {
        var aggregator = Aggregator(frameMs: 20)
        var record: SecondRecord?
        for index in 0 ..< 50 {
            // 1フレームだけ落ち込ませる
            let level = index == 25 ? Levels.floorDbfs : -20.0
            record = aggregator.push(metrics(us: Int64(index) * 20_000, dbfs: level))
        }

        XCTAssertEqual(record?.minDbfs, Levels.floorDbfs)
        XCTAssertEqual(record?.maxDbfs, -20.0)
        // 平均は1フレームの落ち込みにほとんど影響されない。だからこそ min が要る。
        XCTAssertEqual(record!.meanDbfs, -20.09, accuracy: 0.05)
    }

    func testSpeechRatio() {
        var aggregator = Aggregator(frameMs: 20)
        var record: SecondRecord?
        for index in 0 ..< 50 {
            record = aggregator.push(metrics(us: Int64(index) * 20_000, dbfs: -30, speech: index < 20))
        }
        XCTAssertEqual(record!.speechRatio, 0.4, accuracy: 0.0001)
    }

    func testClipRatioIsAveraged() {
        var aggregator = Aggregator(frameMs: 20)
        var record: SecondRecord?
        for index in 0 ..< 50 {
            record = aggregator.push(
                metrics(us: Int64(index) * 20_000, dbfs: -3, clip: index < 10 ? 0.5 : 0)
            )
        }
        XCTAssertEqual(record!.clipRatio, 0.1, accuracy: 0.0001)
    }

    func testFlushEmitsPartialRecord() {
        var aggregator = Aggregator(frameMs: 20)
        for index in 0 ..< 10 {
            _ = aggregator.push(metrics(us: Int64(index) * 20_000, dbfs: -25))
        }
        let record = aggregator.flush()
        XCTAssertEqual(record!.meanDbfs, -25, accuracy: 0.0001)
        XCTAssertNil(aggregator.flush(), "flush後は空になる")
    }

    func testFlushOnEmptyReturnsNil() {
        var aggregator = Aggregator(frameMs: 20)
        XCTAssertNil(aggregator.flush())
    }
}

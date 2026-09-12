import XCTest
@testable import MeerkatsCore

final class AnomalyDetectorTests: XCTestCase {
    private let noiseFloor = -60.0

    private func record(
        mean: Double,
        min: Double? = nil,
        max: Double? = nil,
        speech: Double = 1.0,
        clip: Double = 0
    ) -> SecondRecord {
        SecondRecord(
            monotonicUs: 0,
            meanDbfs: mean,
            minDbfs: min ?? mean,
            maxDbfs: max ?? mean,
            speechRatio: speech,
            clipRatio: clip,
            frameCount: 50
        )
    }

    private func push(_ detector: inout AnomalyDetector, _ r: SecondRecord, times: Int)
        -> [AnomalyKind]
    {
        (0 ..< times).compactMap { _ in detector.push(r, noiseFloorDbfs: noiseFloor) }
    }

    /// 瞬間的な変動では鳴らさない。誤検知のほうが見逃しより高くつく(ADR-0005)。
    func testDoesNotFireBeforeSustained() {
        var detector = AnomalyDetector(
            thresholds: .init(sustainedSeconds: 3)
        )
        let quiet = record(mean: -55)

        XCTAssertNil(detector.push(quiet, noiseFloorDbfs: noiseFloor))
        XCTAssertNil(detector.push(quiet, noiseFloorDbfs: noiseFloor))
        XCTAssertEqual(detector.push(quiet, noiseFloorDbfs: noiseFloor), .lowLevel)
    }

    /// 継続中は鳴らし続けない。同じ異常で何度も通知すると利用者は通知を切る。
    func testFiresOnlyOnEntry() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))
        let quiet = record(mean: -55)

        let fired = push(&detector, quiet, times: 10)
        XCTAssertEqual(fired, [.lowLevel], "入った瞬間の1回だけ")
        XCTAssertTrue(detector.active.contains(.lowLevel))
    }

    /// 一度解消すれば、次に再発したときはまた鳴る。
    func testReArmsAfterConditionClears() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))

        XCTAssertEqual(push(&detector, record(mean: -55), times: 3), [.lowLevel])

        _ = push(&detector, record(mean: -25), times: 1)
        XCTAssertFalse(detector.active.contains(.lowLevel))

        XCTAssertEqual(push(&detector, record(mean: -55), times: 3), [.lowLevel])
    }

    /// 無音を「レベルが低い」と誤検知しない。
    func testSilenceIsNotLowLevel() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))
        XCTAssertTrue(push(&detector, record(mean: -80, speech: 0), times: 10).isEmpty)
    }

    /// 一様に低いのは低ゲイン。間欠的な欠落ではない。
    func testUniformlyLowIsLowLevelNotDropout() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))
        // min と max が同じなので二峰性が無い
        let fired = push(&detector, record(mean: -55, min: -56, max: -54), times: 5)

        XCTAssertEqual(fired, [.lowLevel])
        XCTAssertFalse(detector.active.contains(.dropout))
    }

    /// 通常レベルとノイズフロア相当が同居しているのが間欠的な欠落。
    /// 平均は正常範囲なので、低ゲインとしては検知されない。
    func testBimodalWithinSecondIsDropout() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))
        let fired = push(
            &detector,
            record(mean: -22, min: -59, max: -20),
            times: 5
        )

        XCTAssertEqual(fired, [.dropout])
        XCTAssertFalse(detector.active.contains(.lowLevel))
    }

    /// 発話していない区間の落ち込みは欠落とみなさない。
    func testDropoutRequiresSpeech() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))
        XCTAssertTrue(
            push(&detector, record(mean: -22, min: -59, max: -20, speech: 0), times: 5).isEmpty
        )
    }

    func testSustainedClippingFires() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))
        XCTAssertEqual(
            push(&detector, record(mean: -3, clip: 0.2), times: 5),
            [.clipping]
        )
    }

    func testMomentaryClipDoesNotFire() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 3))
        _ = detector.push(record(mean: -3, clip: 0.2), noiseFloorDbfs: noiseFloor)
        _ = detector.push(record(mean: -20), noiseFloorDbfs: noiseFloor)

        XCTAssertTrue(push(&detector, record(mean: -3, clip: 0.2), times: 2).isEmpty)
    }

    /// 1秒に複数の異常が立っても、通知は1つに絞る。
    func testOnlyOneKindIsReportedPerSecond() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 1))
        let both = record(mean: -55, min: -59, max: -20, clip: 0.2)

        XCTAssertEqual(detector.push(both, noiseFloorDbfs: noiseFloor), .clipping)
        XCTAssertTrue(detector.active.contains(.lowLevel))
        XCTAssertTrue(detector.active.contains(.dropout))
    }

    /// 閾値をストリーム種別ごとに引けること。いまは同じ値だが、呼び出し側を書き換えずに
    /// 分岐できる形になっていることを固定する(ADR-0008)。
    func testThresholdsAreAddressableByStream() {
        XCTAssertEqual(AnomalyDetector.Thresholds.mic.lowLevelDbfs,
                       AnomalyDetector.Thresholds.output.lowLevelDbfs,
                       "いまは同じ値でよい。違えるのは実機で測ってから")
        XCTAssertEqual(AnomalyDetector.Thresholds.mic.sustainedSeconds, 3)
    }
}

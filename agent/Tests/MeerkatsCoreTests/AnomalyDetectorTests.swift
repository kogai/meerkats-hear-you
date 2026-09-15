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

    /// ストリーム種別から正しいほうを引けること。
    ///
    /// **値が等しいことは確認しない。** ADR-0008 は意味が違うから分けろと言っているだけで、
    /// 数値をどうするかは書いていない。いまの値が等しいのは、適正な値を実機で測っていない
    /// からにすぎない。等しさをここで固定すると、測って分けた瞬間にこのテストが落ちる。
    func testThresholdsAreLookedUpByStream() {
        XCTAssertEqual(AnomalyDetector.Thresholds.for(.mic), AnomalyDetector.Thresholds.mic)
        XCTAssertEqual(AnomalyDetector.Thresholds.for(.output), AnomalyDetector.Thresholds.output)
    }

    /// どちらのストリームの閾値も、検知器に渡して意味のある値であること。
    /// こちらは値を分けた後も成り立つ性質だけを見る。
    func testThresholdsAreUsableForEitherStream() {
        for stream in [StreamKind.mic, .output] {
            let thresholds = AnomalyDetector.Thresholds.for(stream)
            XCTAssertGreaterThan(
                thresholds.lowLevelDbfs, Levels.floorDbfs,
                "\(stream) の低レベル閾値が下限に張り付いていて、発火しようがない")
            XCTAssertTrue(
                (0...1).contains(thresholds.clipRatio),
                "\(stream) のクリップ比率が比率になっていない")
            XCTAssertTrue(
                (0...1).contains(thresholds.minSpeechRatio),
                "\(stream) の発話比率が比率になっていない")
            XCTAssertGreaterThan(
                thresholds.sustainedSeconds, 0,
                "\(stream) の継続秒数が0以下だと、瞬間的な変動で鳴る")
        }
    }

    /// 記録が途切れた区間をまたいで継続の数えが繋がらないようにする(ADR-0015 決定4)。
    ///
    /// **`sustainedSeconds` は「続いたこと」を見る。** 「2秒 → 20分の空白 → 1秒」で
    /// 3秒続いたことになれば、続いていないものを続いたと言って通知することになる。
    func testResetDropsTheStreak() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 3))
        let quiet = record(mean: -55)

        XCTAssertEqual(push(&detector, quiet, times: 2), [])
        detector.reset()
        XCTAssertEqual(push(&detector, quiet, times: 2), [], "数えが繋がっている")
        XCTAssertEqual(detector.push(quiet, noiseFloorDbfs: noiseFloor), .lowLevel)
    }

    /// 継続中の異常も落とす。
    ///
    /// 残すと、休止をまたいで同じ異常が続いた場合に一度も通知されない。
    /// **利用者から見れば、再開してから初めて起きた異常である。**
    func testResetDropsTheFiringSet() {
        var detector = AnomalyDetector(thresholds: .init(sustainedSeconds: 2))
        let quiet = record(mean: -55)

        XCTAssertEqual(push(&detector, quiet, times: 2), [.lowLevel])
        XCTAssertEqual(detector.active, [.lowLevel])

        detector.reset()

        XCTAssertTrue(detector.active.isEmpty)
        XCTAssertEqual(push(&detector, quiet, times: 2), [.lowLevel], "再開後に鳴らない")
    }
}

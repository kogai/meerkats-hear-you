import XCTest
@testable import MeerkatsCore

final class SpeechDetectorTests: XCTestCase {
    func testSteadyNoiseIsNotSpeech() {
        var detector = SpeechDetector(windowFrames: 100, recomputeInterval: 10)
        var speechCount = 0
        for _ in 0 ..< 200 where detector.push(-60) {
            speechCount += 1
        }
        XCTAssertEqual(speechCount, 0, "一定のノイズだけなら発話とみなさない")
    }

    func testLevelWellAboveFloorIsSpeech() {
        var detector = SpeechDetector(windowFrames: 100, recomputeInterval: 10)
        for _ in 0 ..< 100 { _ = detector.push(-60) }   // フロアを確立
        XCTAssertTrue(detector.push(-20), "フロアから40dB上なら発話")
    }

    func testLevelJustBelowMarginIsNotSpeech() {
        var detector = SpeechDetector(windowFrames: 100, marginDb: 12, recomputeInterval: 10)
        for _ in 0 ..< 100 { _ = detector.push(-60) }
        XCTAssertEqual(detector.noiseFloorDbfs, -60, accuracy: 0.001)
        XCTAssertFalse(detector.push(-49), "マージン12dBに届かない")
        XCTAssertTrue(detector.push(-47), "マージンを超えれば発話")
    }

    /// フロアは低パーセンタイルから取るため、発話が混ざっても静かな側に居続ける。
    func testFloorTracksQuietPortionNotSpeech() {
        var detector = SpeechDetector(
            windowFrames: 100, floorPercentile: 0.15, recomputeInterval: 10
        )
        // 7割が発話、3割が無音という会話に近い比率
        for index in 0 ..< 200 {
            _ = detector.push(index % 10 < 7 ? -25 : -65)
        }
        XCTAssertEqual(detector.noiseFloorDbfs, -65, accuracy: 0.001)
    }

    /// 窓が育ったあとは、フロアは毎フレームではなく間隔ごとに再計算される。
    /// 終日動き続ける常駐プロセスなので、不要な計算は避ける。
    func testFloorIsRecomputedOnIntervalOnceWarmedUp() {
        var detector = SpeechDetector(windowFrames: 1000, recomputeInterval: 50)

        // 窓が育つ間は毎フレーム追従する。まずそこを抜ける。
        for _ in 0 ..< 50 { _ = detector.push(-60) }
        XCTAssertEqual(detector.noiseFloorDbfs, -60, accuracy: 0.001)

        // 抜けたあとは、間隔に達するまでフロアが動かない。
        for _ in 0 ..< 10 { _ = detector.push(-70) }
        XCTAssertEqual(
            detector.noiseFloorDbfs, -60, accuracy: 0.001,
            "間隔に満たないうちは再計算しない"
        )

        // 間隔を超えれば更新される。
        for _ in 0 ..< 50 { _ = detector.push(-70) }
        XCTAssertEqual(detector.noiseFloorDbfs, -70, accuracy: 0.001)
    }

    /// 窓が埋まる前でも、そこまでに見た値だけで判定できること。
    func testWorksBeforeWindowIsFull() {
        var detector = SpeechDetector(windowFrames: 10_000, recomputeInterval: 1)
        for _ in 0 ..< 20 { _ = detector.push(-70) }
        XCTAssertTrue(detector.push(-30))
    }

    /// パーセンタイルの位置そのものを検証する。
    ///
    /// 全フレームが同じレベルのテストでは、どんなインデックス計算でも同じ値が返るため
    /// 式を一切検証できない。ここでは値をすべて異ならせ、四捨五入と切り捨てで
    /// 結果が変わる位置(要素数4、パーセンタイル0.5)を狙っている。
    /// 切り捨てなら -30、四捨五入なら -20 になる。
    func testPercentileIndexIsRoundedNotTruncated() {
        var detector = SpeechDetector(
            windowFrames: 4, floorPercentile: 0.5, recomputeInterval: 1
        )
        for level in [-40.0, -30.0, -20.0, -10.0] {
            _ = detector.push(level)
        }
        XCTAssertEqual(detector.noiseFloorDbfs, -20, accuracy: 0.001)
    }

    func testPercentileAtExtremes() {
        var lowest = SpeechDetector(windowFrames: 5, floorPercentile: 0, recomputeInterval: 1)
        var highest = SpeechDetector(windowFrames: 5, floorPercentile: 1, recomputeInterval: 1)
        for level in [-50.0, -40.0, -30.0, -20.0, -10.0] {
            _ = lowest.push(level)
            _ = highest.push(level)
        }
        XCTAssertEqual(lowest.noiseFloorDbfs, -50, accuracy: 0.001)
        XCTAssertEqual(highest.noiseFloorDbfs, -10, accuracy: 0.001)
    }

    /// 発話の途中で始まったセッションで、冒頭の発話を取りこぼさないこと。
    ///
    /// 窓が育つまで毎フレーム再計算しないと、ごく少数のサンプルから決めたフロアが
    /// 次の再計算まで(既定では1秒間)固定される。セッションが発話中に始まると
    /// フロアが発話レベルに張り付き、その間の発話がまるごと落ちる。
    func testFloorAdaptsImmediatelyWhileWindowIsGrowing() {
        var detector = SpeechDetector(windowFrames: 100, recomputeInterval: 50)

        // 発話の途中で開始。この時点ではフロアが発話レベルに一致してしまう。
        for _ in 0 ..< 5 { _ = detector.push(-25) }
        XCTAssertEqual(detector.noiseFloorDbfs, -25, accuracy: 0.001)

        // 間が空く。再計算が間隔待ちなら、ここでフロアは動かない。
        for _ in 0 ..< 3 { _ = detector.push(-70) }
        XCTAssertEqual(
            detector.noiseFloorDbfs, -70, accuracy: 0.001,
            "窓が育つ間はフレームごとに追従すること"
        )

        // 追従できていれば、再開した発話を拾える。
        XCTAssertTrue(detector.push(-25))
    }
}

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

    /// フロアは毎フレームではなく間隔ごとに再計算される。
    /// 常時稼働での消費を抑えるための設計(ADR-0004)。
    func testFloorIsRecomputedOnInterval() {
        var detector = SpeechDetector(windowFrames: 1000, recomputeInterval: 50)
        _ = detector.push(-60)
        let initial = detector.noiseFloorDbfs

        // 間隔に満たない間はフロアが動かない
        for _ in 0 ..< 10 { _ = detector.push(-70) }
        XCTAssertEqual(detector.noiseFloorDbfs, initial)

        // 間隔を超えると更新される
        for _ in 0 ..< 50 { _ = detector.push(-70) }
        XCTAssertLessThan(detector.noiseFloorDbfs, initial)
    }

    /// 窓が埋まる前でも、そこまでに見た値だけで判定できること。
    func testWorksBeforeWindowIsFull() {
        var detector = SpeechDetector(windowFrames: 10_000, recomputeInterval: 1)
        for _ in 0 ..< 20 { _ = detector.push(-70) }
        XCTAssertTrue(detector.push(-30))
    }
}

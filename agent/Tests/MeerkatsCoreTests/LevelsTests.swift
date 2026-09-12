import XCTest
@testable import MeerkatsCore

final class LevelsTests: XCTestCase {
    func testFullScaleIsZeroDbfs() {
        let frame = [Float](repeating: 1.0, count: 100)
        XCTAssertEqual(Levels.rmsDbfs(frame), 0.0, accuracy: 0.001)
    }

    func testHalfScaleIsAboutMinusSixDbfs() {
        let frame = [Float](repeating: 0.5, count: 100)
        XCTAssertEqual(Levels.rmsDbfs(frame), -6.0206, accuracy: 0.001)
    }

    func testSilenceIsClampedToFloor() {
        XCTAssertEqual(Levels.rmsDbfs([Float](repeating: 0, count: 100)), Levels.floorDbfs)
    }

    func testEmptyFrameIsFloor() {
        XCTAssertEqual(Levels.rmsDbfs([]), Levels.floorDbfs)
    }

    /// 極小の信号でも下限で頭打ちになる。完全なゼロでなくても -inf には落ちない。
    func testVerySmallSignalIsClampedToFloor() {
        let frame = [Float](repeating: 1e-8, count: 100)
        XCTAssertEqual(Levels.rmsDbfs(frame), Levels.floorDbfs)
    }

    func testClipRatioCountsSamplesAtFullScale() {
        var frame = [Float](repeating: 0.1, count: 10)
        frame[0] = 1.0
        frame[1] = -1.0
        XCTAssertEqual(Levels.clipRatio(frame), 0.2, accuracy: 0.0001)
    }

    func testClipRatioIsZeroForQuietFrame() {
        XCTAssertEqual(Levels.clipRatio([Float](repeating: 0.1, count: 10)), 0.0)
    }

    /// 回帰テスト。dB値を算術平均すると、無音フレームに全体が引きずられて
    /// 実態とかけ離れた値になる。先行する検証で実際にこの誤りを踏んでいる。
    func testPowerMeanIsNotArithmeticMean() {
        let levels = [-10.0, Levels.floorDbfs]
        let arithmetic = levels.reduce(0, +) / Double(levels.count)  // -50.0
        let power = Levels.powerMeanDbfs(levels)

        XCTAssertNotNil(power)
        // パワー領域では大きいほうがほぼ支配するため、-13dB付近に来るのが正しい。
        XCTAssertEqual(power!, -13.0103, accuracy: 0.01)
        XCTAssertGreaterThan(power!, arithmetic + 30)
    }

    func testPowerMeanOfEqualLevelsIsThatLevel() {
        XCTAssertEqual(Levels.powerMeanDbfs([-20.0, -20.0, -20.0])!, -20.0, accuracy: 0.0001)
    }

    func testPowerMeanOfEmptyIsNil() {
        XCTAssertNil(Levels.powerMeanDbfs([]))
    }
}

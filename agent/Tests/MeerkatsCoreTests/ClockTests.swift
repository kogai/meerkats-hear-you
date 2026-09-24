import Foundation
import XCTest
@testable import MeerkatsCore

final class AnchorSchedulerTests: XCTestCase {
    func testFirstCallAlwaysAnchors() {
        var scheduler = AnchorScheduler(intervalSeconds: 300)
        XCTAssertNotNil(scheduler.anchorIfDue(monotonicUs: 0, wallUs: 1_000_000))
    }

    func testDoesNotAnchorBeforeInterval() {
        var scheduler = AnchorScheduler(intervalSeconds: 300)
        _ = scheduler.anchorIfDue(monotonicUs: 0, wallUs: 0)

        XCTAssertNil(scheduler.anchorIfDue(monotonicUs: 299_000_000, wallUs: 0))
    }

    func testAnchorsOnceIntervalElapsed() {
        var scheduler = AnchorScheduler(intervalSeconds: 300)
        _ = scheduler.anchorIfDue(monotonicUs: 0, wallUs: 0)

        let anchor = scheduler.anchorIfDue(monotonicUs: 300_000_000, wallUs: 300_000_100)
        XCTAssertEqual(anchor, ClockAnchor(monotonicUs: 300_000_000, wallUs: 300_000_100))
    }

    /// 間隔は「前回のアンカーから」測る。呼び出し回数ではない。
    func testIntervalIsMeasuredFromLastAnchor() {
        var scheduler = AnchorScheduler(intervalSeconds: 10)
        _ = scheduler.anchorIfDue(monotonicUs: 0, wallUs: 0)
        _ = scheduler.anchorIfDue(monotonicUs: 10_000_000, wallUs: 0)  // 2つ目

        XCTAssertNil(scheduler.anchorIfDue(monotonicUs: 19_000_000, wallUs: 0))
        XCTAssertNotNil(scheduler.anchorIfDue(monotonicUs: 20_000_000, wallUs: 0))
    }
}

final class ClockConversionTests: XCTestCase {
    func testNoAnchorsCannotConvert() {
        XCTAssertNil(
            ClockConversion.wallTime(
                forMonotonicUs: 0, in: StreamAnchors(streamId: 1, anchors: [])
            )
        )
    }

    /// 2つのアンカーの間は線形に補間する。
    func testInterpolatesBetweenAnchors() {
        let anchors = [
            ClockAnchor(monotonicUs: 0, wallUs: 1_000_000_000),
            ClockAnchor(monotonicUs: 100_000, wallUs: 1_000_100_000),
        ]
        let estimate = ClockConversion.wallTime(
            forMonotonicUs: 50_000, in: StreamAnchors(streamId: 1, anchors: anchors)
        )

        XCTAssertEqual(estimate?.wallUs, 1_000_050_000)
        // 2つの時計の進みが一致しているので、この区間に食い違いは無い。
        XCTAssertEqual(estimate?.uncertaintyUs, 0)
    }

    /// 区間内で時計が食い違っていれば、その量がそのまま不確かさになる。
    /// アンカーを複数打つのはこれを測れるようにするため(ADR-0003)。
    func testDriftBetweenAnchorsBecomesUncertainty() {
        let anchors = [
            ClockAnchor(monotonicUs: 0, wallUs: 0),
            // 単調時計で100_000us進む間に、実時刻は100_500us進んだ
            ClockAnchor(monotonicUs: 100_000, wallUs: 100_500),
        ]
        let estimate = ClockConversion.wallTime(
            forMonotonicUs: 50_000, in: StreamAnchors(streamId: 1, anchors: anchors)
        )

        XCTAssertEqual(estimate?.wallUs, 50_250)
        XCTAssertEqual(estimate?.uncertaintyUs, 500)
    }

    func testAnchorsAreSortedBeforeUse() {
        let anchors = [
            ClockAnchor(monotonicUs: 100_000, wallUs: 100_000),
            ClockAnchor(monotonicUs: 0, wallUs: 0),
        ]
        XCTAssertEqual(
            ClockConversion.wallTime(
            forMonotonicUs: 50_000, in: StreamAnchors(streamId: 1, anchors: anchors)
        )?.wallUs,
            50_000
        )
    }

    /// 範囲外は外挿になり、離れるほど不確かさが増える。
    func testExtrapolationUncertaintyGrowsWithDistance() {
        let anchors = [ClockAnchor(monotonicUs: 0, wallUs: 1_000_000)]

        let near = ClockConversion.wallTime(
            forMonotonicUs: 1_000_000, in: StreamAnchors(streamId: 1, anchors: anchors)
        )
        let far = ClockConversion.wallTime(
            forMonotonicUs: 100_000_000, in: StreamAnchors(streamId: 1, anchors: anchors)
        )

        XCTAssertEqual(near?.wallUs, 2_000_000)
        XCTAssertGreaterThan(far!.uncertaintyUs, near!.uncertaintyUs)
        // 100秒ぶん外挿したときの見込みドリフト(100ppm)
        XCTAssertEqual(far?.uncertaintyUs, 10_000)
    }

    func testEstimateExposesInterval() {
        let estimate = WallClockEstimate(wallUs: 1_000, uncertaintyUs: 50)
        XCTAssertEqual(estimate.earliestUs, 950)
        XCTAssertEqual(estimate.latestUs, 1_050)
    }
}

final class ContinuousMonotonicClockTests: XCTestCase {
    func testStartsNearZeroAndAdvances() {
        let clock = ContinuousMonotonicClock()
        let first = clock.nowUs()
        XCTAssertLessThan(first, 1_000_000, "生成直後はほぼ0のはず")

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertGreaterThan(clock.nowUs(), first)
    }

    func testIsMonotonic() {
        let clock = ContinuousMonotonicClock()
        var previous = clock.nowUs()
        for _ in 0 ..< 1000 {
            let current = clock.nowUs()
            XCTAssertGreaterThanOrEqual(current, previous)
            previous = current
        }
    }
}

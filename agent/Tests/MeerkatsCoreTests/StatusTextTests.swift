import XCTest
@testable import MeerkatsCore

final class StatusTextTests: XCTestCase {
    private func snapshot(
        mean: Double = -25,
        speaking: Bool = true,
        floor: Double = -60,
        anomalies: Set<AnomalyKind> = []
    ) -> LiveState.Snapshot {
        LiveState.Snapshot(
            meanDbfs: mean,
            isSpeaking: speaking,
            noiseFloorDbfs: floor,
            activeAnomalies: anomalies,
            recentLevels: []
        )
    }

    func testSpeakingAndSilentIndicators() {
        XCTAssertEqual(StatusText.indicator(snapshot(speaking: true)), "*")
        XCTAssertEqual(StatusText.indicator(snapshot(speaking: false)), "-")
    }

    func testAnomalyOverridesSpeakingIndicator() {
        XCTAssertEqual(
            StatusText.indicator(snapshot(speaking: true, anomalies: [.clipping])), "!"
        )
    }

    /// 異常が複数あっても記号は1つ。並べるとメニューバーの幅に収まらず読み取れない。
    func testIndicatorShowsOnlyOneAnomaly() {
        let indicator = StatusText.indicator(
            snapshot(anomalies: [.clipping, .lowLevel, .dropout])
        )
        XCTAssertEqual(indicator.count, 1)
        XCTAssertEqual(indicator, "!", "原因がはっきりしているものを優先する")
    }

    /// 下限に張り付いている間は数値を出さない。
    /// -90 と表示されると「測れている」と誤解させる。
    func testFloorLevelShowsNoNumber() {
        XCTAssertEqual(StatusText.levelText(Levels.floorDbfs), "--")
        XCTAssertEqual(StatusText.levelText(-25.4), "-25")
    }

    func testMenuBarTitleCombinesIndicatorAndLevel() {
        XCTAssertEqual(StatusText.menuBarTitle(snapshot(mean: -25.4)), "* -25")
    }

    func testDetailWithoutInput() {
        let lines = StatusText.detail(
            snapshot(mean: Levels.floorDbfs, speaking: false)
        )
        XCTAssertEqual(lines.first, "入力なし")
        XCTAssertFalse(lines.contains { $0.contains("dBFS") })
    }

    func testDetailListsLevelAndFloor() {
        let lines = StatusText.detail(snapshot(mean: -25, floor: -61.5))
        XCTAssertTrue(lines.contains("レベル -25.0 dBFS"))
        XCTAssertTrue(lines.contains("ノイズフロア -61.5 dBFS"))
        XCTAssertTrue(lines.contains("発話中"))
        XCTAssertTrue(lines.contains("異常なし"))
    }

    /// 詳細では異常をすべて出す。こちらは幅に余裕がある。
    func testDetailListsAllAnomaliesInPriorityOrder() {
        let lines = StatusText.detail(snapshot(anomalies: [.lowLevel, .clipping]))

        let clippingIndex = lines.firstIndex(of: StatusText.description(of: .clipping))
        let lowLevelIndex = lines.firstIndex(of: StatusText.description(of: .lowLevel))

        XCTAssertNotNil(clippingIndex)
        XCTAssertNotNil(lowLevelIndex)
        XCTAssertLessThan(clippingIndex!, lowLevelIndex!)
        XCTAssertFalse(lines.contains("異常なし"))
    }

    /// 表示と通知で優先順位が食い違うと利用者が混乱する。同じ順序を使っていることを確認する。
    func testNotificationUsesSameWordingAsDetail() {
        for kind in [AnomalyKind.clipping, .lowLevel, .dropout] {
            XCTAssertEqual(
                StatusText.notificationBody(for: kind),
                StatusText.description(of: kind)
            )
        }
    }
}

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

        let clippingIndex = lines.firstIndex(of: StatusText.description(of: .clipping, in: .mic))
        let lowLevelIndex = lines.firstIndex(of: StatusText.description(of: .lowLevel, in: .mic))

        XCTAssertNotNil(clippingIndex)
        XCTAssertNotNil(lowLevelIndex)
        XCTAssertLessThan(clippingIndex!, lowLevelIndex!)
        XCTAssertFalse(lines.contains("異常なし"))
    }

    /// 表示と通知で優先順位が食い違うと利用者が混乱する。同じ順序を使っていることを確認する。
    func testNotificationUsesSameWordingAsDetail() {
        for kind in [AnomalyKind.clipping, .lowLevel, .dropout] {
            for stream in [StreamKind.mic, .output] {
                XCTAssertEqual(
                    StatusText.notificationBody(for: kind, in: stream),
                    StatusText.description(of: kind, in: stream)
                )
            }
        }
    }

    /// マイク側と受信側で文言が違うこと。同じ異常でも利用者にとっての意味が変わるため、
    /// 流用すると通知が嘘になる(ADR-0008)。
    func testWordingDiffersByStream() {
        for kind in [AnomalyKind.clipping, .lowLevel, .dropout] {
            XCTAssertNotEqual(
                StatusText.description(of: kind, in: .mic),
                StatusText.description(of: kind, in: .output),
                "\(kind) の文言がマイク側と受信側で同じになっている"
            )
        }
    }

    /// 受信側の文言は「相手」の話であること。こちらの入力レベルの話にしない。
    func testOutputWordingIsAboutTheOtherParty() {
        for kind in [AnomalyKind.clipping, .lowLevel, .dropout] {
            XCTAssertTrue(
                StatusText.description(of: kind, in: .output).contains("相手"),
                "\(kind) の受信側の文言が相手の話になっていない"
            )
        }
    }

    /// マイク側の文言は自分の話であること。受信側の言い回しが紛れ込んでいないか見る。
    func testMicWordingIsNotAboutTheOtherPartysAudio() {
        for kind in [AnomalyKind.clipping, .lowLevel, .dropout] {
            XCTAssertFalse(
                StatusText.description(of: kind, in: .mic).hasPrefix("相手"),
                "\(kind) のマイク側の文言が相手の話から始まっている"
            )
        }
    }
}

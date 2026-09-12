import Foundation
import XCTest
@testable import MeerkatsCore

final class LiveStateTests: XCTestCase {
    private func record(mean: Double, speech: Double = 1.0) -> SecondRecord {
        SecondRecord(
            monotonicUs: 0, meanDbfs: mean, minDbfs: mean, maxDbfs: mean,
            speechRatio: speech, clipRatio: 0, frameCount: 50
        )
    }

    func testInitialSnapshotIsAtFloor() {
        let state = LiveState()
        let snapshot = state.snapshot()

        XCTAssertEqual(snapshot.meanDbfs, Levels.floorDbfs)
        XCTAssertFalse(snapshot.isSpeaking)
        XCTAssertTrue(snapshot.recentLevels.isEmpty)
        XCTAssertTrue(snapshot.activeAnomalies.isEmpty)
    }

    func testUpdateIsVisibleInSnapshot() {
        let state = LiveState()
        state.update(record: record(mean: -25), noiseFloorDbfs: -60, anomalies: [.lowLevel])

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.meanDbfs, -25)
        XCTAssertTrue(snapshot.isSpeaking)
        XCTAssertEqual(snapshot.noiseFloorDbfs, -60)
        XCTAssertEqual(snapshot.activeAnomalies, [.lowLevel])
    }

    func testNotSpeakingWhenNoSpeechFrames() {
        let state = LiveState()
        state.update(record: record(mean: -70, speech: 0), noiseFloorDbfs: -70, anomalies: [])
        XCTAssertFalse(state.snapshot().isSpeaking)
    }

    /// 履歴は古い順で、容量を超えたら古いほうから落ちる。
    func testHistoryKeepsMostRecentInOrder() {
        let state = LiveState(historySeconds: 3)
        for level in [-10.0, -20.0, -30.0, -40.0, -50.0] {
            state.update(record: record(mean: level), noiseFloorDbfs: -60, anomalies: [])
        }
        XCTAssertEqual(state.snapshot().recentLevels, [-30, -40, -50])
    }

    func testHistoryBelowCapacity() {
        let state = LiveState(historySeconds: 60)
        state.update(record: record(mean: -10), noiseFloorDbfs: -60, anomalies: [])
        state.update(record: record(mean: -20), noiseFloorDbfs: -60, anomalies: [])
        XCTAssertEqual(state.snapshot().recentLevels, [-10, -20])
    }

    /// 音声処理のスレッドと表示のスレッドから同時に触られても壊れないこと。
    func testConcurrentUpdatesAndSnapshots() {
        let state = LiveState(historySeconds: 10)
        let writers = DispatchQueue(label: "writers", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0 ..< 200 {
            group.enter()
            writers.async {
                state.update(
                    record: self.record(mean: Double(-index)),
                    noiseFloorDbfs: -60,
                    anomalies: []
                )
                group.leave()
            }
            group.enter()
            writers.async {
                _ = state.snapshot()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertLessThanOrEqual(state.snapshot().recentLevels.count, 10)
    }
}

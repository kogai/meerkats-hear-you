import Foundation
import XCTest
@testable import MeerkatsCore

private final class CountingSink: RecordingPipeline.Sink {
    func write(seconds records: [SecondRecord]) throws {}
    func write(detail: DetailWindow) throws {}
    func write(anchor: ClockAnchor) throws {}
}

final class PipelineBoxTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func makeBox() -> (PipelineBox, LiveState) {
        let configuration = RecordingPipeline.Configuration(
            frameMs: 20, sampleRate: sampleRate
        )
        let liveState = LiveState()
        let pipeline = RecordingPipeline(
            configuration: configuration, sink: CountingSink(), liveState: liveState
        )
        return (PipelineBox(pipeline), liveState)
    }

    /// **1秒ぶん渡す。** 常時表示の状態は1秒が揃って初めて動くので、
    /// 1フレームだけ流しても通ったかどうかが見えない。
    private func oneSecond() -> [Float] {
        [Float](repeating: 0.5, count: Int(sampleRate))
    }

    func testIngestReachesThePipelineBeforeTake() throws {
        let (box, liveState) = makeBox()
        try box.ingest(oneSecond(), wallUs: 0)
        XCTAssertGreaterThan(liveState.snapshot().meanDbfs, Levels.floorDbfs,
                             "断つ前は流れること")
    }

    /// **断ったあとに届いたバッファは、記録の外の音である。**
    /// 流してしまうと、締めた経路に入って finish と ingest が同じ中身を触る。
    func testIngestIsDroppedAfterTake() throws {
        let (box, liveState) = makeBox()
        _ = box.take()
        try box.ingest(oneSecond(), wallUs: 0)
        XCTAssertEqual(liveState.snapshot().meanDbfs, Levels.floorDbfs,
                       "断ったあとは届かないこと")
    }

    /// 締めるのは取り出した側だけ。2回目は nil を返す。
    func testTakeHandsOverExactlyOnce() {
        let (box, _) = makeBox()
        XCTAssertNotNil(box.take())
        XCTAssertNil(box.take(), "2回目は取り出せないこと")
    }

    /// 音のスレッドと止める側が同時に来ても壊れないこと。
    func testConcurrentIngestAndTake() {
        let (box, _) = makeBox()
        let samples = [Float](repeating: 0.5, count: Int(sampleRate) / 50)
        let counted = NSLock()
        var handedOver = 0

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if index % 16 == 0 {
                if box.take() != nil {
                    counted.lock()
                    handedOver += 1
                    counted.unlock()
                }
            } else {
                try? box.ingest(samples, wallUs: Int64(index) * 20_000)
            }
        }

        counted.lock()
        defer { counted.unlock() }
        XCTAssertEqual(handedOver, 1, "何人が同時に取りにきても、渡るのは1人だけ")
    }
}

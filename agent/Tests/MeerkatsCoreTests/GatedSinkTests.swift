import Foundation
import XCTest
@testable import MeerkatsCore

private final class RecordingSink: RecordingPipeline.Sink {
    var seconds: [SecondRecord] = []
    var details: [DetailWindow] = []
    var anchors: [ClockAnchor] = []

    func write(seconds records: [SecondRecord]) throws { seconds.append(contentsOf: records) }
    func write(detail: DetailWindow) throws { details.append(detail) }
    func write(anchor: ClockAnchor) throws { anchors.append(anchor) }
}

final class GatedSinkTests: XCTestCase {
    private func record(atSecond second: Int, speechRatio: Double) -> SecondRecord {
        SecondRecord(
            monotonicUs: Int64(second) * 1_000_000,
            meanDbfs: -30, minDbfs: -40, maxDbfs: -20,
            speechRatio: speechRatio, clipRatio: 0, frameCount: 50
        )
    }

    /// 遷移を集めておく。**内部の状態は覗かない。** 覗けるようにすると、
    /// 表示のスレッドから読めてしまい、音声のスレッドと競合する。
    private final class Transitions {
        var all: [RecordingGate.Transition] = []
        var isRecording: Bool { all.last != .suspended }
    }

    private func make() -> (GatedSink, RecordingSink, Transitions) {
        let inner = RecordingSink()
        let sink = GatedSink(wrapping: inner, gate: RecordingGate(idleSeconds: 600))
        let transitions = Transitions()
        sink.onTransition = { transitions.all.append($0) }
        return (sink, inner, transitions)
    }

    func testPassesRecordsThroughWhileRecording() throws {
        let (sink, inner, transitions) = make()
        try sink.write(seconds: [record(atSecond: 0, speechRatio: 0.5)])
        XCTAssertEqual(inner.seconds.count, 1)
        XCTAssertTrue(transitions.isRecording)
    }

    func testStopsWritingAfterSuspension() throws {
        let (sink, inner, transitions) = make()
        for second in 0...601 {
            try sink.write(seconds: [record(atSecond: second, speechRatio: 0)])
        }
        XCTAssertEqual(transitions.all, [.suspended])
        XCTAssertFalse(transitions.isRecording)

        let beforeSuspension = inner.seconds.count
        try sink.write(seconds: [record(atSecond: 700, speechRatio: 0)])
        XCTAssertEqual(inner.seconds.count, beforeSuspension, "休止後に書いている")
    }

    /// **境目の秒は通す。** 休止に入った秒が記録に無いと、あとから境目を指せない。
    func testTheSuspendingSecondIsStillWritten() throws {
        let (sink, inner, transitions) = make()
        for second in 0...600 {
            try sink.write(seconds: [record(atSecond: second, speechRatio: 0)])
        }
        XCTAssertFalse(transitions.isRecording)
        XCTAssertEqual(inner.seconds.last?.monotonicUs, 600_000_000,
                       "休止に入った秒が落ちている")
    }

    func testResumesWritingOnSpeech() throws {
        let (sink, inner, transitions) = make()
        for second in 0...601 {
            try sink.write(seconds: [record(atSecond: second, speechRatio: 0)])
        }
        let beforeResume = inner.seconds.count

        try sink.write(seconds: [record(atSecond: 700, speechRatio: 0.5)])
        XCTAssertEqual(inner.seconds.count, beforeResume + 1, "再開した秒が落ちている")
        XCTAssertTrue(transitions.isRecording)
    }

    /// **束の途中で休止に入っても、そこまでは残す。**
    /// まとめ書きは最大10秒ぶんを運ぶので、束ごと捨てると休止までの区間まで落ちる。
    func testSplitsABatchThatCrossesSuspension() throws {
        let (sink, inner, transitions) = make()
        try sink.write(seconds: [record(atSecond: 0, speechRatio: 0.5)])

        let batch = (595...604).map { record(atSecond: $0, speechRatio: 0) }
        try sink.write(seconds: batch)

        XCTAssertFalse(transitions.isRecording)
        let written = inner.seconds.map(\.monotonicUs)
        XCTAssertTrue(written.contains(600_000_000), "休止に入った秒が落ちている")
        XCTAssertFalse(written.contains(601_000_000), "休止後の秒を書いている")
    }

    func testDoesNotWriteDetailOrAnchorWhileSuspended() throws {
        let (sink, inner, transitions) = make()
        for second in 0...601 {
            try sink.write(seconds: [record(atSecond: second, speechRatio: 0)])
        }
        XCTAssertFalse(transitions.isRecording)

        try sink.write(detail: DetailWindow(startUs: 0, trigger: "lowLevel", frames: []))
        try sink.write(anchor: ClockAnchor(monotonicUs: 0, wallUs: 0))
        XCTAssertTrue(inner.details.isEmpty, "休止中に詳細層を書いている")
        XCTAssertTrue(inner.anchors.isEmpty, "休止中にアンカーを書いている")
    }

    func testWritesDetailAndAnchorWhileRecording() throws {
        let (sink, inner, transitions) = make()
        try sink.write(detail: DetailWindow(startUs: 0, trigger: "lowLevel", frames: []))
        try sink.write(anchor: ClockAnchor(monotonicUs: 0, wallUs: 0))
        XCTAssertEqual(inner.details.count, 1)
        XCTAssertEqual(inner.anchors.count, 1)
    }

    /// 空になった束で内側を呼ばない。呼ぶと、書くものが無いのに書き込みが走る。
    func testDoesNotCallInnerWithAnEmptyBatch() throws {
        let (sink, inner, transitions) = make()
        for second in 0...601 {
            try sink.write(seconds: [record(atSecond: second, speechRatio: 0)])
        }
        let before = inner.seconds.count
        try sink.write(seconds: [record(atSecond: 700, speechRatio: 0)])
        XCTAssertEqual(inner.seconds.count, before)
    }
}

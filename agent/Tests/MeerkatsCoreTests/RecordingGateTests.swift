import Foundation
import XCTest
@testable import MeerkatsCore

final class RecordingGateTests: XCTestCase {
    private func record(atSecond second: Int, speechRatio: Double) -> SecondRecord {
        SecondRecord(
            monotonicUs: Int64(second) * 1_000_000,
            meanDbfs: -30, minDbfs: -40, maxDbfs: -20,
            speechRatio: speechRatio, clipRatio: 0, frameCount: 50
        )
    }

    /// 会議の途中で立ち上げることがある。起動直後から録る。
    func testStartsRecording() {
        XCTAssertTrue(RecordingGate().isRecording)
    }

    func testSuspendsAfterIdleWithoutSpeech() {
        var gate = RecordingGate(idleSeconds: 600)
        var transitions: [RecordingGate.Transition] = []
        for second in 0...600 {
            if let transition = gate.push(record(atSecond: second, speechRatio: 0)) {
                transitions.append(transition)
            }
        }
        XCTAssertEqual(transitions, [.suspended])
        XCTAssertFalse(gate.isRecording)
    }

    /// **境界の手前では休止しない。** 早く切ると、会議中に記録が落ちる。
    func testDoesNotSuspendBeforeIdle() {
        var gate = RecordingGate(idleSeconds: 600)
        for second in 0..<600 {
            XCTAssertNil(gate.push(record(atSecond: second, speechRatio: 0)), "\(second)秒で休止した")
        }
        XCTAssertTrue(gate.isRecording)
    }

    /// 話すたびに数え直す。9分ごとに一言だけ話す会議でも休止しない。
    func testSpeechResetsTheCountdown() {
        var gate = RecordingGate(idleSeconds: 600)
        for second in 0...1800 {
            let speaking = second % 540 == 0
            XCTAssertNil(
                gate.push(record(atSecond: second, speechRatio: speaking ? 0.5 : 0)),
                "\(second)秒で状態が変わった")
        }
        XCTAssertTrue(gate.isRecording)
    }

    func testResumesOnSpeechAfterSuspension() {
        var gate = RecordingGate(idleSeconds: 600)
        for second in 0...600 { _ = gate.push(record(atSecond: second, speechRatio: 0)) }
        XCTAssertFalse(gate.isRecording)

        XCTAssertEqual(gate.push(record(atSecond: 601, speechRatio: 0.5)), .resumed)
        XCTAssertTrue(gate.isRecording)
    }

    /// **状態が変わったときだけ返す。** 毎秒返すと、呼び出し側がタップを張り直し続ける。
    func testTransitionIsReportedOnlyOnChange() {
        var gate = RecordingGate(idleSeconds: 600)
        for second in 0...600 { _ = gate.push(record(atSecond: second, speechRatio: 0)) }

        for second in 601...700 {
            XCTAssertNil(gate.push(record(atSecond: second, speechRatio: 0)),
                         "休止中に\(second)秒でまた返した")
        }
        for second in 701...710 {
            let transition = gate.push(record(atSecond: second, speechRatio: 0.5))
            XCTAssertEqual(transition, second == 701 ? .resumed : nil,
                           "\(second)秒の返りが違う")
        }
    }

    /// 足切りを下回る発話は、話したとみなさない。
    /// 息や物音でフロアをまたいだだけの秒で、休止が止まらないようにする。
    func testSpeechBelowTheRatioDoesNotCount() {
        var gate = RecordingGate(idleSeconds: 600, minSpeechRatio: 0.2)
        var suspended = false
        for second in 0...600 {
            if gate.push(record(atSecond: second, speechRatio: 0.1)) == .suspended {
                suspended = true
            }
        }
        XCTAssertTrue(suspended, "足切り未満の発話で休止が止まっている")
    }

    /// **経過はレコードの時刻で測る。** 件数で数えていると、記録が途切れていた区間のぶん
    /// 休止が遅れる。スリープから戻った直後がその形になる。
    func testIdleIsMeasuredByTimeNotByCount() {
        var gate = RecordingGate(idleSeconds: 600)
        XCTAssertNil(gate.push(record(atSecond: 0, speechRatio: 0.5)))
        XCTAssertEqual(
            gate.push(record(atSecond: 3600, speechRatio: 0)), .suspended,
            "1件しか来ていなくても、時刻が離れていれば休止すること")
    }

    /// 一度も話さないまま立ち上げたときも、最初のレコードから数える。
    func testCountsFromTheFirstRecordWhenNeverSpoken() {
        var gate = RecordingGate(idleSeconds: 600)
        XCTAssertNil(gate.push(record(atSecond: 1000, speechRatio: 0)))
        XCTAssertNil(gate.push(record(atSecond: 1599, speechRatio: 0)), "起動から10分未満")
        XCTAssertEqual(gate.push(record(atSecond: 1600, speechRatio: 0)), .suspended)
    }
}

import XCTest
@testable import MeerkatsCore

final class FramerTests: XCTestCase {
    func testExactMultipleProducesNoCarry() {
        var framer = Framer(frameLength: 320)
        let frames = framer.push([Float](repeating: 0.1, count: 960))
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(framer.pendingSampleCount, 0)
        XCTAssertTrue(frames.allSatisfy { $0.count == 320 })
    }

    func testRemainderIsCarriedToNextPush() {
        var framer = Framer(frameLength: 320)
        XCTAssertEqual(framer.push([Float](repeating: 0, count: 500)).count, 1)
        XCTAssertEqual(framer.pendingSampleCount, 180)

        XCTAssertEqual(framer.push([Float](repeating: 0, count: 140)).count, 1)
        XCTAssertEqual(framer.pendingSampleCount, 0)
    }

    func testBufferSmallerThanFrameProducesNothing() {
        var framer = Framer(frameLength: 320)
        XCTAssertTrue(framer.push([Float](repeating: 0, count: 100)).isEmpty)
        XCTAssertEqual(framer.pendingSampleCount, 100)
    }

    /// スパイクの実測では48kHzで約100msのバッファが届いた。
    /// 20msフレーム(960サンプル)に対して端数が出る状況を再現する。
    func testRealisticMacOSBufferSize() {
        let frameLength = 960          // 48kHz / 20ms
        let bufferLength = 4963        // 実測されたバッファ長に近い値(割り切れない)
        var framer = Framer(frameLength: frameLength)

        var total = 0
        for _ in 0 ..< 10 {
            total += framer.push([Float](repeating: 0.01, count: bufferLength)).count
        }

        // 10バッファ分のサンプルから取り出せるフレーム数と一致すること。
        XCTAssertEqual(total, (bufferLength * 10) / frameLength)
        XCTAssertLessThan(framer.pendingSampleCount, frameLength)
    }

    /// サンプルが失われたり重複したりしないこと。
    func testSamplesArePreservedInOrder() {
        var framer = Framer(frameLength: 4)
        let input: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let frames = framer.push(input)

        XCTAssertEqual(frames, [[1, 2, 3, 4], [5, 6, 7, 8]])
        XCTAssertEqual(framer.pendingSampleCount, 2)

        let more = framer.push([11, 12])
        XCTAssertEqual(more, [[9, 10, 11, 12]])
    }

    func testResetDiscardsCarry() {
        var framer = Framer(frameLength: 320)
        _ = framer.push([Float](repeating: 0, count: 100))
        framer.reset()
        XCTAssertEqual(framer.pendingSampleCount, 0)
    }
}

import XCTest
@testable import MeerkatsCore

final class FrameRingBufferTests: XCTestCase {
    private func metrics(_ us: Int64) -> FrameMetrics {
        FrameMetrics(monotonicUs: us, dbfs: -30, clipRatio: 0, isSpeech: false)
    }

    func testEmptySnapshot() {
        let buffer = FrameRingBuffer(capacity: 4)
        XCTAssertTrue(buffer.snapshot().isEmpty)
        XCTAssertEqual(buffer.count, 0)
    }

    func testPartiallyFilledKeepsOrder() {
        var buffer = FrameRingBuffer(capacity: 4)
        buffer.append(metrics(1))
        buffer.append(metrics(2))

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.snapshot().map(\.monotonicUs), [1, 2])
    }

    func testOverwritesOldestOnceFull() {
        var buffer = FrameRingBuffer(capacity: 3)
        for us in Int64(1) ... 5 {
            buffer.append(metrics(us))
        }

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.snapshot().map(\.monotonicUs), [3, 4, 5])
    }

    /// 何周しても順序が崩れないこと。異常検知時に取り出す内容が
    /// 時刻順である前提で詳細層を書き出すため、ここが崩れると記録が壊れる。
    func testOrderSurvivesManyWraps() {
        var buffer = FrameRingBuffer(capacity: 10)
        for us in Int64(1) ... 1000 {
            buffer.append(metrics(us))
        }

        let snapshot = buffer.snapshot().map(\.monotonicUs)
        XCTAssertEqual(snapshot, Array(Int64(991) ... 1000))
        XCTAssertEqual(snapshot, snapshot.sorted(), "時刻順であること")
    }

    func testExactlyFull() {
        var buffer = FrameRingBuffer(capacity: 3)
        for us in Int64(1) ... 3 {
            buffer.append(metrics(us))
        }
        XCTAssertEqual(buffer.snapshot().map(\.monotonicUs), [1, 2, 3])
    }

    func testRemoveAll() {
        var buffer = FrameRingBuffer(capacity: 3)
        buffer.append(metrics(1))
        buffer.removeAll()

        XCTAssertEqual(buffer.count, 0)
        XCTAssertTrue(buffer.snapshot().isEmpty)

        buffer.append(metrics(9))
        XCTAssertEqual(buffer.snapshot().map(\.monotonicUs), [9])
    }
}

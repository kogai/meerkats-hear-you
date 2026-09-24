import XCTest
@testable import MeerkatsCore

final class SampleRingTests: XCTestCase {
    func testRoundTripKeepsOrderAndClock() {
        var ring = SampleRing(sampleCapacity: 16, chunkCapacity: 4)
        ring.write(clockUs: 10, [1, 2])
        ring.write(clockUs: 20, [3, 4, 5])

        let first = ring.read()
        XCTAssertEqual(first, SampleRing.Chunk(clockUs: 10, samples: [1, 2], droppedBefore: 0))
        let second = ring.read()
        XCTAssertEqual(second, SampleRing.Chunk(clockUs: 20, samples: [3, 4, 5], droppedBefore: 0))
        let drained = ring.read()
        XCTAssertNil(drained)
        XCTAssertTrue(ring.isEmpty)
    }

    /// **境界をまたぐ書き込みが割れない。**
    ///
    /// 読み出しが進んだぶん空きは先頭側に戻るので、次の書き込みは末尾から先頭へ
    /// 巻き込む。ここを取り違えると、1つのバッファの後半だけが別の場所から読まれて、
    /// **波形が繋ぎ変わったまま静かに記録される。**
    func testWritesThatWrapAroundStayIntact() {
        var ring = SampleRing(sampleCapacity: 8, chunkCapacity: 4)
        ring.write(clockUs: 1, [1, 2, 3, 4, 5, 6])
        _ = ring.read()

        // 空きは 6 サンプルぶん、うち末尾に 2、先頭に 4。
        let wrapped = ring.write(clockUs: 2, [7, 8, 9, 10, 11])
        XCTAssertTrue(wrapped)
        let back = ring.read()
        XCTAssertEqual(back?.samples, [7, 8, 9, 10, 11])
    }

    /// **溢れたら新しいほうを捨てる。古いものは無傷で残る。**
    func testDropsTheNewestWhenSamplesAreFull() {
        var ring = SampleRing(sampleCapacity: 4, chunkCapacity: 4)
        ring.write(clockUs: 1, [1, 2, 3])

        let rejected = ring.write(clockUs: 2, [4, 5])
        XCTAssertFalse(rejected)
        XCTAssertEqual(ring.pendingDroppedSamples, 2)

        // 先に入っていたぶんは変わっていない。
        let survived = ring.read()
        XCTAssertEqual(survived, SampleRing.Chunk(clockUs: 1, samples: [1, 2, 3], droppedBefore: 0))
    }

    /// サンプルに空きがあっても、抱えられる回数が尽きれば捨てる。
    func testDropsWhenChunkSlotsAreFull() {
        var ring = SampleRing(sampleCapacity: 64, chunkCapacity: 2)
        ring.write(clockUs: 1, [1])
        ring.write(clockUs: 2, [2])

        let rejected = ring.write(clockUs: 3, [3])
        XCTAssertFalse(rejected)
        XCTAssertEqual(ring.bufferedSamples, 2, "サンプル側にはまだ余裕がある")
        XCTAssertEqual(ring.pendingDroppedSamples, 1)
    }

    /// **捨てた量は、次に入った書き込みに付く。**
    ///
    /// 総数だけを持つと、受け取った側は何サンプル失ったかは分かっても
    /// **どこで失ったかが分からない。** 空隙をどの時刻に置くかが決まらなくなる。
    func testDroppedCountAttachesToTheNextChunk() {
        var ring = SampleRing(sampleCapacity: 4, chunkCapacity: 4)
        ring.write(clockUs: 1, [1, 2, 3, 4])
        ring.write(clockUs: 2, [5, 6])  // 捨てられる
        ring.write(clockUs: 3, [7])     // これも捨てられる

        XCTAssertEqual(ring.pendingDroppedSamples, 3)
        _ = ring.read()  // 空きを作る

        ring.write(clockUs: 4, [8, 9])
        XCTAssertEqual(ring.pendingDroppedSamples, 0, "付け替えたので残っていない")
        let carried = ring.read()
        XCTAssertEqual(carried, SampleRing.Chunk(clockUs: 4, samples: [8, 9], droppedBefore: 3))
    }

    /// **容量そのものを超えるバッファは、空でも入らない。** 待たずに捨てて勘定に入れる。
    func testDropsABufferLargerThanTheWholeRing() {
        var ring = SampleRing(sampleCapacity: 4, chunkCapacity: 4)

        let rejected = ring.write(clockUs: 1, [1, 2, 3, 4, 5])
        XCTAssertFalse(rejected)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.pendingDroppedSamples, 5)
    }

    /// 空の書き込みは何も起こさない。捨てたことにもしない。
    func testEmptyWriteIsANoOp() {
        var ring = SampleRing(sampleCapacity: 4, chunkCapacity: 2)

        let accepted = ring.write(clockUs: 1, [Float]())
        XCTAssertTrue(accepted)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.pendingDroppedSamples, 0)
    }

    /// 詰めて出してを繰り返しても位置がずれない。
    func testSurvivesManyCycles() {
        var ring = SampleRing(sampleCapacity: 7, chunkCapacity: 3)
        for round in 0 ..< 50 {
            let value = Float(round)
            let accepted = ring.write(clockUs: Int64(round), [value, value + 0.5])
            XCTAssertTrue(accepted)
            let chunk = ring.read()
            XCTAssertEqual(
                chunk,
                SampleRing.Chunk(
                    clockUs: Int64(round), samples: [value, value + 0.5], droppedBefore: 0
                )
            )
        }
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.bufferedSamples, 0)
    }
}

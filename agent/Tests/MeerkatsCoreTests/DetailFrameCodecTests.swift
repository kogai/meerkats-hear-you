import Foundation
import XCTest
@testable import MeerkatsCore

final class DetailFrameCodecTests: XCTestCase {
    private func frame(_ us: Int64, _ dbfs: Double, speech: Bool = false, clip: Double = 0)
        -> FrameMetrics
    {
        FrameMetrics(monotonicUs: us, dbfs: dbfs, clipRatio: clip, isSpeech: speech)
    }

    func testSizeIsFiveBytesPerFrame() {
        let frames = (0 ..< 100).map { frame(Int64($0) * 20_000, -30) }
        let data = DetailFrameCodec.encode(frames)

        // ヘッダ1バイト + 5バイト × 100
        XCTAssertEqual(data.count, 1 + 500)
    }

    /// ADR-0004が行ではなくBLOBを選んだ根拠は容量差にある。
    /// 10秒の区間(500フレーム)が数KBに収まることを確認する。
    func testTenSecondWindowIsAboutTwoAndAHalfKilobytes() {
        let frames = (0 ..< 500).map { frame(Int64($0) * 20_000, -30) }
        XCTAssertEqual(DetailFrameCodec.encode(frames).count, 2501)
    }

    func testRoundTripPreservesLevelsAndFlags() throws {
        let frames = [
            frame(1_000_000, -20.5, speech: true),
            frame(1_020_000, -65.25, speech: false),
            frame(1_040_000, -3.0, speech: true, clip: 0.4),
        ]
        let decoded = try DetailFrameCodec.decode(
            DetailFrameCodec.encode(frames), startUs: 1_000_000, frameDurationUs: 20_000
        )

        XCTAssertEqual(decoded.count, 3)
        for (original, restored) in zip(frames, decoded) {
            // Float32を経由するため厳密一致はしない
            XCTAssertEqual(restored.dbfs, original.dbfs, accuracy: 0.001)
            XCTAssertEqual(restored.isSpeech, original.isSpeech)
            XCTAssertEqual(restored.monotonicUs, original.monotonicUs)
        }
        // クリップは詳細層では有無のみ。比率は常時層が持つ。
        XCTAssertEqual(decoded[2].clipRatio, 1)
        XCTAssertEqual(decoded[0].clipRatio, 0)
    }

    /// 時刻は符号化せず、開始時刻とフレーム長から復元する。
    func testTimestampsAreReconstructedFromStart() throws {
        let frames = (0 ..< 5).map { frame(Int64($0) * 20_000, -40) }
        let decoded = try DetailFrameCodec.decode(
            DetailFrameCodec.encode(frames), startUs: 500_000, frameDurationUs: 20_000
        )
        XCTAssertEqual(
            decoded.map(\.monotonicUs),
            [500_000, 520_000, 540_000, 560_000, 580_000]
        )
    }

    func testFloorLevelSurvivesRoundTrip() throws {
        let decoded = try DetailFrameCodec.decode(
            DetailFrameCodec.encode([frame(0, Levels.floorDbfs)]),
            startUs: 0, frameDurationUs: 20_000
        )
        XCTAssertEqual(decoded[0].dbfs, Levels.floorDbfs, accuracy: 0.001)
    }

    func testEmptyFrameListEncodesHeaderOnly() throws {
        let data = DetailFrameCodec.encode([])
        XCTAssertEqual(data.count, 1)
        XCTAssertTrue(try DetailFrameCodec.decode(data, startUs: 0, frameDurationUs: 20_000).isEmpty)
    }

    func testEmptyDataIsRejected() {
        XCTAssertThrowsError(
            try DetailFrameCodec.decode(Data(), startUs: 0, frameDurationUs: 20_000)
        ) { error in
            XCTAssertEqual(error as? DetailFrameCodec.DecodeError, .empty)
        }
    }

    /// 版が違うデータを黙って読み違えないこと。
    /// 1フレームあたりのバイト数を変える変更は過去のデータを読めなくするため、
    /// ここで弾けないと壊れた値を正常なものとして扱ってしまう。
    func testUnknownVersionIsRejected() {
        var data = DetailFrameCodec.encode([frame(0, -30)])
        data[data.startIndex] = 99

        XCTAssertThrowsError(
            try DetailFrameCodec.decode(data, startUs: 0, frameDurationUs: 20_000)
        ) { error in
            XCTAssertEqual(error as? DetailFrameCodec.DecodeError, .unsupportedVersion(99))
        }
    }

    func testTruncatedPayloadIsRejected() {
        let data = DetailFrameCodec.encode([frame(0, -30)]).dropLast()

        XCTAssertThrowsError(
            try DetailFrameCodec.decode(Data(data), startUs: 0, frameDurationUs: 20_000)
        ) { error in
            XCTAssertEqual(error as? DetailFrameCodec.DecodeError, .truncated(byteCount: 4))
        }
    }
}

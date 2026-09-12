import Foundation
import XCTest
@testable import MeerkatsCore

final class RecordingStoreTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    func testOpenCreatesDatabase() throws {
        let store = try RecordingStore(path: path)
        store.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSessionRoundTrip() throws {
        let store = try RecordingStore(path: path)
        defer { store.close() }

        let id = try store.startSession(wallUs: 1_700_000_000_000_000, agentVersion: "0.1")
        XCTAssertGreaterThan(id, 0)
        try store.endSession(id: id, wallUs: 1_700_000_060_000_000)
    }

    func testSessionIdsAreDistinct() throws {
        let store = try RecordingStore(path: path)
        defer { store.close() }

        let first = try store.startSession(wallUs: 0, agentVersion: "0.1")
        let second = try store.startSession(wallUs: 1, agentVersion: "0.1")
        XCTAssertNotEqual(first, second)
    }

    func testStreamBelongsToSession() throws {
        let store = try RecordingStore(path: path)
        defer { store.close() }

        let session = try store.startSession(wallUs: 0, agentVersion: "0.1")
        let mic = try store.addStream(
            sessionId: session, kind: .mic, deviceName: "Jabra Engage 50 II",
            sampleRate: 48_000, frameMs: 20
        )
        XCTAssertGreaterThan(mic, 0)
    }

    /// 自分のマイクと受信音声を同じセッションに並べられること。
    /// 受信音声の検証は保留中だが、受け皿は先に用意してある(ADR-0006)。
    func testMicAndOutputStreamsShareASession() throws {
        let store = try RecordingStore(path: path)
        defer { store.close() }

        let session = try store.startSession(wallUs: 0, agentVersion: "0.1")
        let mic = try store.addStream(
            sessionId: session, kind: .mic, deviceName: nil, sampleRate: 48_000, frameMs: 20
        )
        let output = try store.addStream(
            sessionId: session, kind: .output, deviceName: nil, sampleRate: 48_000, frameMs: 20
        )
        XCTAssertNotEqual(mic, output)
    }

    /// 存在しないセッションに紐づくストリームは作れない。
    func testForeignKeyIsEnforced() throws {
        let store = try RecordingStore(path: path)
        defer { store.close() }

        XCTAssertThrowsError(
            try store.addStream(
                sessionId: 9999, kind: .mic, deviceName: nil, sampleRate: 48_000, frameMs: 20
            )
        )
    }

    /// 分析側が読んでいる間も書き込みが止まらないようWALにしてある。
    func testWalModeIsEnabled() throws {
        let store = try RecordingStore(path: path)
        _ = try store.startSession(wallUs: 0, agentVersion: "0.1")
        store.close()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path + "-wal"),
            "WALファイルが作られていること"
        )
    }

    func testReopenKeepsExistingData() throws {
        let first = try RecordingStore(path: path)
        let session = try first.startSession(wallUs: 42, agentVersion: "0.1")
        first.close()

        let second = try RecordingStore(path: path)
        defer { second.close() }
        let next = try second.startSession(wallUs: 43, agentVersion: "0.1")
        XCTAssertGreaterThan(next, session, "既存の行を消さずに追記される")
    }
}

import AppKit
import Foundation
import MeerkatsCore

/// エージェント本体。ADR-0005のとおり、キャプチャ・記録・表示を単一のプロセスに置く。
///
/// 常時表示がメモリから直接読めるのはこの構成による。別プロセスにすると、
/// ADR-0004のまとめ書きの間隔ぶんだけ表示が遅れる。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: RecordingStore?
    private var capture: AudioCapture?
    private var menuBar: MenuBarController?
    private let liveState = LiveState()

    private var sessionId: Int64 = 0
    private var streamId: Int64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 記録より先に出す。許可が下りずに記録が始まらなくても、
        // 「動いてはいるが測れていない」ことが表示から分かるようにするため。
        let menuBar = MenuBarController(liveState: liveState)
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.start()
        self.menuBar = menuBar

        Task { await startRecording() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 締めてから閉じる。端数の1秒と溜まっている常時層はここでしか書かれない。
        capture?.stop()
        if sessionId != 0 {
            try? store?.endSession(id: sessionId, wallUs: Self.nowWallUs())
        }
        store?.close()
        menuBar?.stop()
    }

    private func startRecording() async {
        guard await AudioCapture.requestPermission() else {
            report("マイクへのアクセスが許可されていません。システム設定で許可してください。")
            return
        }

        do {
            let store = try RecordingStore(path: Self.databasePath())
            self.store = store

            let configuration = RecordingPipeline.Configuration()
            sessionId = try store.startSession(
                wallUs: Self.nowWallUs(), agentVersion: Self.version
            )
            streamId = try store.addStream(
                sessionId: sessionId,
                kind: .mic,
                deviceName: AudioCapture.currentInputDeviceName(),
                sampleRate: Int(configuration.sampleRate),
                frameMs: configuration.frameMs
            )

            let sink = StoreSink(store: store, streamId: streamId, sessionId: sessionId)
            let pipeline = RecordingPipeline(
                configuration: configuration, sink: sink, liveState: liveState
            )

            let capture = AudioCapture(
                pipeline: pipeline,
                onError: { [weak self] error in self?.report("\(error)") }
            )
            try capture.start()
            self.capture = capture
        } catch {
            report("記録を開始できませんでした: \(error)")
        }
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static let version = "0.1"

    static func nowWallUs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    /// ADR-0004のとおりアプリケーションサポート配下に置く。
    static func databasePath() -> String {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Meerkats", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("recordings.sqlite").path
    }
}

/// RecordingPipeline の出力先を RecordingStore に繋ぐ。
/// アンカーはセッションに、レベルはストリームに紐づくので、両方のIDを持つ。
private final class StoreSink: RecordingPipeline.Sink {
    private let store: RecordingStore
    private let streamId: Int64
    private let sessionId: Int64

    init(store: RecordingStore, streamId: Int64, sessionId: Int64) {
        self.store = store
        self.streamId = streamId
        self.sessionId = sessionId
    }

    func write(seconds records: [SecondRecord]) throws {
        try store.appendSeconds(streamId: streamId, records)
    }

    func write(detail: DetailWindow) throws {
        try store.appendDetailWindow(streamId: streamId, detail)
    }

    func write(anchor: ClockAnchor) throws {
        try store.appendAnchor(sessionId: sessionId, anchor)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Info.plist の LSUIElement と揃える。Dockアイコンを持たない常駐にする。
app.setActivationPolicy(.accessory)
app.run()

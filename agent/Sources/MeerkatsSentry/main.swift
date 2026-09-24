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
    private var analysis: AnalysisWindowController?
    private let liveState = LiveState()

    /// **セッションで1つ。** 2本のパイプラインに同じものを渡す(ADR-0015 決定6)。
    /// ここに置いてあるのは、別々に作った瞬間に2本が別の原点を持つからである。
    private let clock = ContinuousMonotonicClock()

    /// 記録の設定。**ストリーム種別を決めている唯一の場所にする。**
    /// 表示は記録より先に立ち上がるので、ここに置かないとメニューバーだけ別の値を持つ。
    /// 受信音声を足すときに、文言だけ取り残されるのがその形になる。
    private let configuration = RecordingPipeline.Configuration()

    private var sessionId: Int64 = 0
    private var streamId: Int64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 記録より先に出す。許可が下りずに記録が始まらなくても、
        // 「動いてはいるが測れていない」ことが表示から分かるようにするため。
        // liveState はマイク側1本ぶん。受信音声を足すときは、LiveStateごと分ける。
        let menuBar = MenuBarController(
            liveState: liveState, streamKind: configuration.streamKind
        )
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
        // 通知が拒否されても記録は続ける。気づける手段が減るだけで、振り返りは成立する。
        _ = await AnomalyNotifier.requestPermission()

        do {
            let store = try RecordingStore(path: Self.databasePath())
            self.store = store

            // onAnomaly は逃げる閉包なので、プロパティを直接参照すると self の明示を要る。
            // 値型なのでここで写しておけば済む。
            let configuration = self.configuration

            sessionId = try store.startSession(
                wallUs: Self.nowWallUs(), agentVersion: Self.version
            )

            // **率が分かるまでストリームを作らない。** 入力デバイスの率はこちらから決められず、
            // 48kHz と決め打って記録すると、44.1kHz の機械では嘘の値が残る。記録に残す率と、
            // 実際に切り出す率が食い違えば、あとから見ても直しようがない。
            let currentSessionId = self.sessionId
            let liveState = self.liveState
            // 時計も写しておく。プロパティのまま参照すると閉包が self を掴む。
            // 参照型なので、写しても指す先はセッションで1つのままである。
            let clock = self.clock
            var startedStreamId: Int64 = 0

            let capture = AudioCapture(
                frameMs: configuration.frameMs,
                makePipeline: { sampleRate in
                    var configuration = configuration
                    configuration.sampleRate = sampleRate

                    let streamId = try store.addStream(
                        sessionId: currentSessionId,
                        kind: configuration.streamKind,
                        deviceName: AudioCapture.currentInputDeviceName(),
                        sampleRate: Int(sampleRate),
                        frameMs: configuration.frameMs
                    )
                    startedStreamId = streamId

                    let sink = StoreSink(store: store, streamId: streamId)
                    let pipeline = RecordingPipeline(
                        configuration: configuration, sink: sink, liveState: liveState,
                        clock: clock
                    )
                    pipeline.onAnomaly = {
                        AnomalyNotifier.notify($0, in: configuration.streamKind)
                    }
                    return pipeline
                },
                onError: { [weak self] error in self?.report("\(error)") }
            )
            // 工場は start の中で同期に呼ばれる。戻ったときには streamId が決まっている。
            try capture.start()
            self.capture = capture
            self.streamId = startedStreamId

            // 記録が始まってから開けるようにする。ストリームIDが決まる前に開くと、
            // 空のウインドウが出て「記録されていない」と誤解させる。
            analysis = AnalysisWindowController(
                store: store,
                streamId: streamId,
                streamKind: configuration.streamKind,
                frameDurationUs: configuration.frameDurationUs
            )
            menuBar?.onOpenAnalysis = { [weak self] in self?.analysis?.show() }
        } catch {
            report("記録を開始できませんでした: \(error)")
        }
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// バンドルから読む。ここを固定値にすると、リリースのたびに記録へ嘘のバージョンが残る。
    static let version =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

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
///
/// **持つIDはストリームだけ。** アンカーもストリームに紐づくようになった
/// (ADR-0015 決定5)。2本のストリームは別のデバイスのクロックに乗っているので、
/// 片方のアンカーでもう片方を換算すると、ずれ方の差だけ間違う。
private final class StoreSink: RecordingPipeline.Sink {
    private let store: RecordingStore
    private let streamId: Int64

    init(store: RecordingStore, streamId: Int64) {
        self.store = store
        self.streamId = streamId
    }

    func write(seconds records: [SecondRecord]) throws {
        try store.appendSeconds(streamId: streamId, records)
    }

    func write(detail: DetailWindow) throws {
        try store.appendDetailWindow(streamId: streamId, detail)
    }

    func write(anchor: ClockAnchor) throws {
        try store.appendAnchor(streamId: streamId, anchor)
    }

    func write(gap: RecordingGap) throws {
        try store.appendGap(streamId: streamId, gap)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Info.plist の LSUIElement と揃える。Dockアイコンを持たない常駐にする。
app.setActivationPolicy(.accessory)
app.run()

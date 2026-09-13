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

    /// 受信音声。**休止と再開で張り直すので、保持だけしておく。**
    private var outputTap: SystemOutputTap?
    /// 受信側の常時表示の状態。**まだ誰も読まない。** 表示に出すのは別の作業になる。
    private let outputLiveState = LiveState()

    /// 記録の設定。**ストリーム種別を決めている唯一の場所にする。**
    /// 表示は記録より先に立ち上がるので、ここに置かないとメニューバーだけ別の値を持つ。
    /// 受信音声を足すときに、文言だけ取り残されるのがその形になる。
    private let configuration = RecordingPipeline.Configuration()

    /// 受信側の設定。刻みと率の扱いはマイク側と同じで、ストリーム種別だけ違う。
    private var outputConfiguration: RecordingPipeline.Configuration {
        var configuration = self.configuration
        configuration.streamKind = .output
        return configuration
    }

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
        stopOutputTap()
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
            var startedStreamId: Int64 = 0
            var gatedSink: GatedSink?

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

                    // **休止の判定を挟む。** 自分の発話が10分途切れたら、会議中ではないと
                    // みなして記録を止める(ADR-0014)。判定はマイク側のレコードだけで決まる。
                    let sink = GatedSink(wrapping: StoreSink(
                        store: store, streamId: streamId, sessionId: currentSessionId
                    ))
                    // **ここで self に触らない。** 触ると工場の閉包が self を強く持ち、
                    // AppDelegate → AudioCapture → 工場 → self で輪になる。
                    // 遷移の受け取りは start のあとに繋ぐ。
                    gatedSink = sink

                    let pipeline = RecordingPipeline(
                        configuration: configuration, sink: sink, liveState: liveState
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

            // **休止と再開の受け取りをここで繋ぐ。** 工場の中で繋ぐと輪になる。
            // 呼ばれるのは音声のスレッドなので、主スレッドに渡してから触る。
            gatedSink?.onTransition = { [weak self] transition in
                DispatchQueue.main.async { self?.apply(transition) }
            }

            // 起動直後は記録している(ADR-0014)。会議の途中で立ち上げることがある。
            startOutputTap()

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

    // MARK: - 受信音声の張り直し(ADR-0014)

    /// 休止と再開を受けて、受信音声のタップを畳む・張り直す。**主スレッドで呼ぶこと。**
    private func apply(_ transition: RecordingGate.Transition) {
        switch transition {
        case .suspended: stopOutputTap()
        case .resumed: startOutputTap()
        }
    }

    /// **張り直すたびに新しいストリームを作る。** 続きとして繋がない。
    ///
    /// タップは実際に畳まれるので、その間の音は録れていない。1本のストリームに繋ぐと、
    /// **録れていない区間が無音として残る。** 要望書の「記録上は正常」と同じ形になる。
    /// 別のストリームにしておけば、録っていた区間が記録の側から分かる。
    private func startOutputTap() {
        guard outputTap == nil, let store, sessionId != 0 else { return }

        let configuration = outputConfiguration
        let currentSessionId = sessionId
        let liveState = outputLiveState

        let tap = SystemOutputTap(
            frameMs: configuration.frameMs,
            makePipeline: { sampleRate in
                var configuration = configuration
                configuration.sampleRate = sampleRate

                let streamId = try store.addStream(
                    sessionId: currentSessionId,
                    kind: configuration.streamKind,
                    deviceName: "システム出力",
                    sampleRate: Int(sampleRate),
                    frameMs: configuration.frameMs
                )
                let sink = StoreSink(
                    store: store, streamId: streamId, sessionId: currentSessionId
                )
                // **こちらに休止の判定は挟まない。** 休止中はタップごと畳むので、
                // レコードが流れてこない。挟むと、マイク側のレコードで決まる判定を
                // 受信側のレコードでも動かすことになる。
                let pipeline = RecordingPipeline(
                    configuration: configuration, sink: sink, liveState: liveState
                )
                pipeline.onAnomaly = {
                    AnomalyNotifier.notify($0, in: configuration.streamKind)
                }
                return pipeline
            },
            onError: { [weak self] error in
                DispatchQueue.main.async { self?.report("\(error)") }
            }
        )

        do {
            try tap.start()
            outputTap = tap
        } catch {
            // **受信音声が録れなくてもマイク側は続ける。** 片側だけでも振り返りは成立する。
            report("受信音声を取得できませんでした: \(error)")
        }
    }

    private func stopOutputTap() {
        outputTap?.stop()
        outputTap = nil
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

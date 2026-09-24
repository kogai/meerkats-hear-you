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
    private var outputTap: SystemOutputTap?
    private var menuBar: MenuBarController?
    private var analysis: AnalysisWindowController?

    /// **ストリームごとに分ける。** 1つを2本で共有すると、あとから来たほうの値で
    /// 上書きし合い、表示はどちらのものとも言えない数字になる。
    private let micLiveState = LiveState()
    private let outputLiveState = LiveState()

    /// **セッションで1つ。** 2本のパイプラインに同じものを渡す(ADR-0015 決定6)。
    /// ここに置いてあるのは、別々に作った瞬間に2本が別の原点を持つからである。
    private let clock = ContinuousMonotonicClock()

    /// 記録の設定。**ストリーム種別を決めている唯一の場所にする。**
    /// 表示は記録より先に立ち上がるので、ここに置かないとメニューバーだけ別の値を持つ。
    private let micConfiguration = RecordingPipeline.Configuration(streamKind: .mic)
    private let outputConfiguration = RecordingPipeline.Configuration(streamKind: .output)

    private var sessionId: Int64 = 0
    private var micStreamId: Int64 = 0

    /// 受信側のストリームID。**いまは読んでいない。** 分析ウインドウが1本ぶんしか
    /// 読み口を持たないためで、2本を並べる ADR-0012 の突合で要る。
    private var outputStreamId: Int64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 記録より先に出す。許可が下りずに記録が始まらなくても、
        // 「動いてはいるが測れていない」ことが表示から分かるようにするため。
        //
        // **2本とも先に出す。** 受信側は別の許可を要り、断られることがある。載せておけば、
        // 断られた側は「まだ測れていない」のまま並ぶ。**最初の1秒を観測するまでは両方が
        // そう出る**ので、片方だけ測れていないと分かるのは、もう片方が数字を出してからになる。
        let menuBar = MenuBarController(streams: [
            .init(liveState: micLiveState, kind: micConfiguration.streamKind),
            .init(liveState: outputLiveState, kind: outputConfiguration.streamKind),
        ])
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.start()
        self.menuBar = menuBar

        Task { await startRecording() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 締めてから閉じる。端数の1秒と溜まっている常時層はここでしか書かれない。
        // **2本とも締める。** 片方だけ締めると、もう片方の端数がそのまま消える。
        capture?.stop()
        outputTap?.stop()
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

            sessionId = try store.startSession(
                wallUs: Self.nowWallUs(), agentVersion: Self.version
            )

            var startedStreamId: Int64 = 0
            let configuration = micConfiguration
            let capture = AudioCapture(
                frameMs: configuration.frameMs,
                makePipeline: Self.pipelineFactory(
                    store: store,
                    sessionId: sessionId,
                    configuration: configuration,
                    liveState: micLiveState,
                    clock: clock,
                    deviceName: { AudioCapture.currentInputDeviceName() },
                    onStream: { startedStreamId = $0 }
                ),
                onError: { [weak self] error in self?.report("\(error)") }
            )
            // 工場は start の中で同期に呼ばれる。戻ったときには streamId が決まっている。
            try capture.start()
            self.capture = capture
            self.micStreamId = startedStreamId

            // 記録が始まってから開けるようにする。ストリームIDが決まる前に開くと、
            // 空のウインドウが出て「記録されていない」と誤解させる。
            //
            // **このウインドウはまだマイク側しか見せない。** 受信側の行はDBに入るが、
            // 読み口が1本ぶんしかない。2本を並べる作業は突合(ADR-0012)と同じ形になるので、
            // そちらでまとめて扱う。
            analysis = AnalysisWindowController(
                store: store,
                streamId: micStreamId,
                streamKind: configuration.streamKind,
                frameDurationUs: configuration.frameDurationUs
            )
            menuBar?.onOpenAnalysis = { [weak self] in self?.analysis?.show() }

            startOutputTap(store: store)
        } catch {
            report("記録を開始できませんでした: \(error)")
        }
    }

    /// 受信音声を起こす(ADR-0008、ADR-0013)。
    ///
    /// **失敗してもマイク側は続ける。** こちらは `NSAudioCaptureUsageDescription` の許可を
    /// 別に要り、断られることも、出力デバイスの都合で弾かれることもある。そこで記録全体を
    /// 止めると、**片方が取れないだけで両方失う。**
    ///
    /// **分離を作っているのは、この関数が中で握りつぶしていることである。順序ではない。**
    /// ここは投げないので、マイクより先に呼んでもマイク側の配線には入れる。`catch` を外すか
    /// `throws` にすると、そこで分離が消える。
    private func startOutputTap(store: RecordingStore) {
        var startedStreamId: Int64 = 0
        let configuration = outputConfiguration
        let tap = SystemOutputTap(
            frameMs: configuration.frameMs,
            makePipeline: Self.pipelineFactory(
                store: store,
                sessionId: sessionId,
                configuration: configuration,
                liveState: outputLiveState,
                clock: clock,
                // **デバイス名を残さない。** プロセスタップが拾うのはこのMacの出力そのもので、
                // 利用者が選んだ機器ではない(ADR-0013)。入力側の値をここに写すと、
                // 記録に嘘の条件が残る。
                deviceName: { nil },
                onStream: { startedStreamId = $0 }
            ),
            onError: { [weak self] error in self?.report("\(error)") }
        )
        do {
            try tap.start()
            outputTap = tap
            outputStreamId = startedStreamId
        } catch {
            // **一度も書かれないストリームの行が残ることがある。** 工場は率が分かった段で
            // 呼ばれ、そこで `addStream` が行を入れる。そのあとの `AudioDeviceStart` などで
            // 落ちると行だけが残り、消す口は無い。マイク側(`AudioCapture`)と同じ形。
            // **許可の拒否はその手前で落ちる**ので、いちばん多い失敗ではこうならない。
            report("このMacの音を記録できませんでした: \(error)")
        }
    }

    /// 2本のストリームで同じ工場を使う。**片方だけ直すと、2つの経路で理由の違う実装が並ぶ。**
    ///
    /// **率が分かるまでストリームを作らない。** 率はデバイスの既定に従い、こちらから
    /// 決められない。48kHz と決め打って記録すると、44.1kHz の機械では嘘の値が残る。
    /// 記録に残す率と、実際に切り出す率が食い違えば、あとから見ても直しようがない。
    ///
    /// `self` を捕まえないよう、要るものはすべて引数で受け取る。**この工場自体は音の
    /// スレッドからは呼ばれない**(`start()` の中で同期に呼ばれる)。掴ませないのは、
    /// 閉包が可変のプロパティを持ち続けないようにするためである。音のスレッドから呼ばれるのは
    /// `onError` のほうで、そちらは `[weak self]` で持つ。
    private static func pipelineFactory(
        store: RecordingStore,
        sessionId: Int64,
        configuration: RecordingPipeline.Configuration,
        liveState: LiveState,
        clock: MonotonicClock,
        deviceName: @escaping () -> String?,
        onStream: @escaping (Int64) -> Void
    ) -> (Double) throws -> RecordingPipeline {
        return { sampleRate in
            var configuration = configuration
            configuration.sampleRate = sampleRate

            let streamId = try store.addStream(
                sessionId: sessionId,
                kind: configuration.streamKind,
                deviceName: deviceName(),
                sampleRate: Int(sampleRate),
                frameMs: configuration.frameMs
            )
            onStream(streamId)

            let sink = StoreSink(store: store, streamId: streamId)
            let pipeline = RecordingPipeline(
                configuration: configuration, sink: sink, liveState: liveState, clock: clock
            )
            // **種別だけを写して渡す。** `configuration` は直前に `var` で作り直しており、
            // 閉包が箱ごと掴むと、あとから書き換えが足されたときに音のスレッドがそれを読む。
            let streamKind = configuration.streamKind
            pipeline.onAnomaly = { AnomalyNotifier.notify($0, in: streamKind) }
            return pipeline
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

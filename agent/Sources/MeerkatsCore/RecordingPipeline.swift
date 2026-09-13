import Foundation

/// キャプチャから記録までの流れをまとめたもの。
///
/// AVFoundationに触れないのは意図的で、音声バッファを受け取る口だけを開けてある。
/// 実機でしか動かせないのはバッファを供給する側だけになり、繋ぎ込みの論理はCIで検証できる。
public final class RecordingPipeline {
    public struct Configuration {
        /// どちらのストリームを扱っているか。閾値と文言がこれで変わる(ADR-0008)。
        public var streamKind: StreamKind
        public var frameMs: Int
        public var sampleRate: Double
        /// 詳細層として残す長さ。異常の開始前を含めるため、リングバッファはこの秒数ぶん持つ。
        public var detailWindowSeconds: Int
        /// 常時層をまとめてコミットする間隔。
        public var flushIntervalSeconds: Int
        public var anchorIntervalSeconds: Int

        public init(
            streamKind: StreamKind = .mic,
            frameMs: Int = 20,
            sampleRate: Double = 48_000,
            detailWindowSeconds: Int = 10,
            flushIntervalSeconds: Int = 10,
            anchorIntervalSeconds: Int = 300
        ) {
            self.streamKind = streamKind
            self.frameMs = frameMs
            self.sampleRate = sampleRate
            self.detailWindowSeconds = detailWindowSeconds
            self.flushIntervalSeconds = flushIntervalSeconds
            self.anchorIntervalSeconds = anchorIntervalSeconds
        }

        /// 1フレームのサンプル数。**切り捨てで整数にする。** 率が刻みで割り切れない場合、
        /// 捨てた端数は溜まって恒常的なずれになる。割り切れるかどうかは、率を決める側が見る。
        public var frameLength: Int { Int(sampleRate * Double(frameMs) / 1000.0) }
        public var frameDurationUs: Int64 { Int64(frameMs) * 1000 }
        var framesPerDetailWindow: Int { detailWindowSeconds * (1000 / frameMs) }
    }

    /// 記録の出力先。テストでは差し替える。
    public protocol Sink: AnyObject {
        func write(seconds: [SecondRecord]) throws
        func write(detail: DetailWindow) throws
        func write(anchor: ClockAnchor) throws
        func write(gap: RecordingGap) throws
    }

    public let configuration: Configuration
    /// 強参照で持つ。弱参照にすると、呼び出し側が出力先を変数に残さなかった瞬間に
    /// 記録が静かに落ちる。パイプラインを指し返す出力先は無いので、循環はしない。
    private let sink: Sink
    private let liveState: LiveState

    /// **セッションで1つの時計を共有する**(ADR-0015 決定6)。既定値を置かないのは、
    /// 置くとパイプラインごとに別の時計が生まれ、2本のストリームが別の原点を持つためである。
    /// それは ADR-0015 が直そうとしている状態そのものになる。
    private let clock: MonotonicClock

    private var framer: Framer
    private var detector: SpeechDetector
    private var aggregator: Aggregator
    private var ring: FrameRingBuffer
    private var anomalies: AnomalyDetector
    private var anchors: AnchorScheduler

    private var pendingSeconds: [SecondRecord] = []

    /// 時刻は `baseUs + frameIndex * frameDurationUs`(ADR-0015 決定1)。
    /// キャプチャが続いている間はフレーム数だけで決まるので、バッファの到着ジッタが入らない。
    private var baseUs: Int64 = 0
    private var frameIndex: Int64 = 0
    private var started = false
    private var pendingRebase: RecordingGap.Reason?

    /// 異常に入った瞬間に呼ばれる。通知の送出に使う(ADR-0005)。
    public var onAnomaly: ((AnomalyKind) -> Void)?

    public init(
        configuration: Configuration = Configuration(),
        sink: Sink,
        liveState: LiveState,
        clock: MonotonicClock
    ) {
        self.configuration = configuration
        self.sink = sink
        self.liveState = liveState
        self.clock = clock

        framer = Framer(frameLength: configuration.frameLength)
        detector = SpeechDetector()
        aggregator = Aggregator(frameMs: configuration.frameMs)
        ring = FrameRingBuffer(capacity: configuration.framesPerDetailWindow)
        anomalies = AnomalyDetector(
            thresholds: AnomalyDetector.Thresholds.for(configuration.streamKind)
        )
        anchors = AnchorScheduler(intervalSeconds: configuration.anchorIntervalSeconds)
    }

    /// 音声バッファを流し込む。長さは任意でよく、内部で固定長フレームに切り直される。
    ///
    /// - Parameters:
    ///   - wallUs: いまの実時刻。アンカーを打つのに使う。
    public func ingest(_ samples: [Float], wallUs: Int64) throws {
        // 最初のバッファは必ず打ち直す。セッションの開始からキャプチャが実際に始まるまでの
        // 時間(エンジンの起動、タップの確立、許可の応答)はストリームごとに違う。
        // そこを 0 に揃えると、実際にはずれて始まった2本を「同時に始まった」と記録する。
        let reason: RecordingGap.Reason? = started ? pendingRebase : .start
        if let reason {
            try applyRebase(reason: reason)
        }
        for frame in framer.push(samples) {
            try process(frame: frame, wallUs: wallUs)
        }
    }

    /// 途切れたと分かったときに呼ぶ(ADR-0015 決定2)。
    ///
    /// **ここでは時計を読まない。次のバッファまで待つ。** ここで読むと、
    /// 呼ばれてから音が実際に戻るまでの間も新しい基準に含まれてしまい、
    /// 最初のフレームが、まだ捕まえていない時刻を名乗ることになる。
    /// 空隙が終わるのは、こちらが気づいた時ではなく、音が戻った時である。
    ///
    /// 次のバッファが来なければ何も起きない。打ち直しも空隙の行も出ない。
    /// **それでよい。** 戻ってこなかったキャプチャは、締めるときに端数として締まる。
    public func rebase(reason: RecordingGap.Reason) {
        pendingRebase = reason
    }

    private func applyRebase(reason: RecordingGap.Reason) throws {
        // **途中の状態を捨てる**(ADR-0015 決定4)。捨てないと、欠落の前と後のフレームが
        // 1つの秒に混ざる。前の30フレームと後の20フレームで1行が完成し、`monotonicUs` は
        // 欠落前を指し、`frameCount` は 50 になる。主キーは衝突せず、1秒に満たない行にも
        // ならない。**完全に見える嘘の行**で、あとから検出する手がかりが何も残らない。
        //
        // 端数の秒はここで吐き出す。`frameCount` が揃わないので、短い秒だと分かる。
        if let last = aggregator.flush() {
            pendingSeconds.append(last)
        }
        framer.reset()
        detector.reset()

        let startUs = started ? baseUs + frameIndex * configuration.frameDurationUs : 0

        // **後ろへは戻さない。** `seconds` の主キーは `(stream_id, monotonic_us)` なので、
        // 戻した時刻は既存の行を黙って上書きする。デバイスのクロックが公称より速ければ、
        // フレーム時刻は実時間より先行しうるので、これは起きる。
        // そのときは先行ぶんを引き継ぎ、空隙は長さ0として残す。
        // **先行そのものはドリフトであり、打ち直しではなくアンカーが測る**(ADR-0015 決定3)。
        baseUs = max(clock.nowUs(), startUs)
        frameIndex = 0
        started = true
        pendingRebase = nil

        try sink.write(gap: RecordingGap(startUs: startUs, endUs: baseUs, reason: reason))
    }

    private func process(frame: [Float], wallUs: Int64) throws {
        // 時刻は基準からのフレーム番号で決める。ここで時計を読むと、1バッファぶんの
        // フレームがほぼ同じ時刻になってしまい、レベルの時系列として使えない。
        // 基準が動くのは打ち直しのときだけである(ADR-0015 決定1)。
        let monotonicUs = baseUs + frameIndex * configuration.frameDurationUs
        frameIndex += 1

        let dbfs = Levels.rmsDbfs(frame)
        let metrics = FrameMetrics(
            monotonicUs: monotonicUs,
            dbfs: dbfs,
            clipRatio: Levels.clipRatio(frame),
            isSpeech: detector.push(dbfs)
        )
        ring.append(metrics)

        if let anchor = anchors.anchorIfDue(monotonicUs: monotonicUs, wallUs: wallUs) {
            try sink.write(anchor: anchor)
        }

        guard let record = aggregator.push(metrics) else { return }
        try complete(second: record)
    }

    private func complete(second record: SecondRecord) throws {
        // 区切りは、溜まっている先頭からの経過で決める。書いたあとの時刻を基準にすると、
        // 最初のひと塊だけ1件多くなる。件数が揃わないと、溜まる量の見積もりが立たない。
        let flushIntervalUs = Int64(configuration.flushIntervalSeconds) * 1_000_000
        if let start = pendingSeconds.first?.monotonicUs,
           record.monotonicUs - start >= flushIntervalUs {
            try flush()
        }
        pendingSeconds.append(record)

        let entered = anomalies.push(record, noiseFloorDbfs: detector.noiseFloorDbfs)
        liveState.update(
            record: record,
            noiseFloorDbfs: detector.noiseFloorDbfs,
            anomalies: anomalies.active
        )

        if let entered {
            // リングバッファには異常が始まる前のフレームも入っている。
            // 通知より先に書き出すのは、通知を見て分析を開いたときに記録が揃っているようにするため。
            let frames = ring.snapshot()
            if let first = frames.first {
                try sink.write(
                    detail: DetailWindow(
                        startUs: first.monotonicUs, trigger: entered.rawValue, frames: frames
                    )
                )
            }
            onAnomaly?(entered)
        }
    }

    /// 溜まっている常時層を書き出す。セッション終了時にも呼ぶ。
    public func flush() throws {
        guard !pendingSeconds.isEmpty else { return }
        try sink.write(seconds: pendingSeconds)
        pendingSeconds.removeAll(keepingCapacity: true)
    }

    /// 端数のフレームも含めて締める。
    public func finish() throws {
        if let last = aggregator.flush() {
            pendingSeconds.append(last)
        }
        try flush()
    }
}

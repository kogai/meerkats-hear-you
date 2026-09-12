import Foundation

/// キャプチャから記録までの流れをまとめたもの。
///
/// AVFoundationに触れないのは意図的で、音声バッファを受け取る口だけを開けてある。
/// 実機でしか動かせないのはバッファを供給する側だけになり、繋ぎ込みの論理はCIで検証できる。
public final class RecordingPipeline {
    public struct Configuration {
        public var frameMs: Int
        public var sampleRate: Double
        /// 常時層をまとめてコミットする間隔。
        public var flushIntervalSeconds: Int
        public var anchorIntervalSeconds: Int

        public init(
            frameMs: Int = 20,
            sampleRate: Double = 48_000,
            flushIntervalSeconds: Int = 10,
            anchorIntervalSeconds: Int = 300
        ) {
            self.frameMs = frameMs
            self.sampleRate = sampleRate
            self.flushIntervalSeconds = flushIntervalSeconds
            self.anchorIntervalSeconds = anchorIntervalSeconds
        }

        var frameLength: Int { Int(sampleRate * Double(frameMs) / 1000.0) }
        public var frameDurationUs: Int64 { Int64(frameMs) * 1000 }
    }

    /// 記録の出力先。テストでは差し替える。
    public protocol Sink: AnyObject {
        func write(seconds: [SecondRecord]) throws
        func write(anchor: ClockAnchor) throws
    }

    public let configuration: Configuration
    /// 強参照で持つ。弱参照にすると、呼び出し側が出力先を変数に残さなかった瞬間に
    /// 記録が静かに落ちる。パイプラインを指し返す出力先は無いので、循環はしない。
    private let sink: Sink
    private let liveState: LiveState

    private var framer: Framer
    private var detector: SpeechDetector
    private var aggregator: Aggregator
    private var anchors: AnchorScheduler

    private var pendingSeconds: [SecondRecord] = []
    private var frameIndex: Int64 = 0

    public init(
        configuration: Configuration = Configuration(),
        sink: Sink,
        liveState: LiveState
    ) {
        self.configuration = configuration
        self.sink = sink
        self.liveState = liveState

        framer = Framer(frameLength: configuration.frameLength)
        detector = SpeechDetector()
        aggregator = Aggregator(frameMs: configuration.frameMs)
        anchors = AnchorScheduler(intervalSeconds: configuration.anchorIntervalSeconds)
    }

    /// 音声バッファを流し込む。長さは任意でよく、内部で固定長フレームに切り直される。
    ///
    /// - Parameters:
    ///   - wallUs: いまの実時刻。アンカーを打つのに使う。
    public func ingest(_ samples: [Float], wallUs: Int64) throws {
        for frame in framer.push(samples) {
            try process(frame: frame, wallUs: wallUs)
        }
    }

    private func process(frame: [Float], wallUs: Int64) throws {
        // 時刻はフレーム番号から決める。処理時刻を読むと、1バッファぶんのフレームが
        // ほぼ同じ時刻になってしまい、レベルの時系列として使えない。
        let monotonicUs = frameIndex * configuration.frameDurationUs
        frameIndex += 1

        let dbfs = Levels.rmsDbfs(frame)
        let metrics = FrameMetrics(
            monotonicUs: monotonicUs,
            dbfs: dbfs,
            clipRatio: Levels.clipRatio(frame),
            isSpeech: detector.push(dbfs)
        )

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

        liveState.update(
            record: record,
            noiseFloorDbfs: detector.noiseFloorDbfs,
            anomalies: []
        )
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

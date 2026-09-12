import AVFoundation
import Foundation
import MeerkatsCore

/// マイクからの入力を RecordingPipeline に流し込む。
///
/// このファイルは実機でしか動かせない唯一の記録側の部品で、ロジックは持たない。
/// 判断はすべて MeerkatsCore 側にあり、ここはバッファを渡すだけにしてある。
public final class AudioCapture {
    public enum CaptureError: Error {
        case permissionDenied
        case invalidInputFormat(channels: UInt32, sampleRate: Double)
        /// 記録の経路が、渡した率で組まれていなかった。
        case pipelineRateMismatch(device: Double, pipeline: Double)
        /// 率がフレームの刻みで割り切れず、1フレームごとに端数が出る。
        case rateNotDivisibleIntoFrames(sampleRate: Double, frameMs: Int)
    }

    /// 入力デバイスの実際のサンプル率を受け取って記録の経路を作る。
    ///
    /// **率を渡してから作らせるのが要点。** 入力デバイスの率はこちらから決められない。
    /// 48kHz 前提で組んだ経路を 44.1kHz の機械に当てると、**約9%ずれた時系列が黙って
    /// 記録される。** 記録は残るので、値を見るまで気づかない。受信側(`ProcessTap`)と同じ形。
    public typealias PipelineFactory = (_ sampleRate: Double) throws -> RecordingPipeline

    private let engine = AVAudioEngine()
    private let makePipeline: PipelineFactory
    private let onError: (Error) -> Void

    private var pipeline: RecordingPipeline?

    public init(
        makePipeline: @escaping PipelineFactory, onError: @escaping (Error) -> Void
    ) {
        self.makePipeline = makePipeline
        self.onError = onError
    }

    /// 記録に残す入力デバイス名。キャプチャを開始しなくても引けるので型メソッドにしてある。
    public static func currentInputDeviceName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.permissionDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw CaptureError.invalidInputFormat(
                channels: format.channelCount, sampleRate: format.sampleRate
            )
        }

        // 率はデバイスが決める。こちらの前提を押し付けない。
        let pipeline = try makePipeline(format.sampleRate)

        // **渡した率で組まれたことを確かめる。** 確かめないと、呼び出し側が引数を捨てて
        // 既定の48kHzで組んでも通ってしまう。
        guard pipeline.configuration.sampleRate == format.sampleRate else {
            throw CaptureError.pipelineRateMismatch(
                device: format.sampleRate, pipeline: pipeline.configuration.sampleRate
            )
        }

        // 1フレームのサンプル数は切り捨てで整数になるので、割り切れない率だと
        // 1フレームごとに端数を捨てる。捨てた量は溜まり、恒常的なずれになる。
        let exactFrameLength =
            format.sampleRate * Double(pipeline.configuration.frameMs) / 1000.0
        guard Double(pipeline.configuration.frameLength) == exactFrameLength else {
            throw CaptureError.rateNotDivisibleIntoFrames(
                sampleRate: format.sampleRate, frameMs: pipeline.configuration.frameMs
            )
        }
        self.pipeline = pipeline

        // bufferSize はヒントにすぎず、実測では約100msのバッファが届く。
        // 固定長への切り直しは RecordingPipeline 側が行う。
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        do {
            try engine.start()
        } catch {
            // 作りかけの経路を手放す。残すと、一度も読んでいないものを stop() が締めにいける。
            self.pipeline = nil
            input.removeTap(onBus: 0)
            throw error
        }
    }

    public func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // 先に手放す。締めに失敗したときに、もう一度締めにいかないため。
        let pipeline = self.pipeline
        self.pipeline = nil
        do {
            try pipeline?.finish()
        } catch {
            onError(error)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        // 生のPCMはここから先へ渡さない。渡すのはこの配列だけで、
        // RecordingPipeline はフレームごとの値に変換したあと捨てる。
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        let wallUs = Int64(Date().timeIntervalSince1970 * 1_000_000)

        do {
            try pipeline?.ingest(samples, wallUs: wallUs)
        } catch {
            onError(error)
        }
    }
}

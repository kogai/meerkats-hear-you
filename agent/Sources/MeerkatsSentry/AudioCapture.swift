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
    }

    private let engine = AVAudioEngine()
    private let pipeline: RecordingPipeline
    private let onError: (Error) -> Void

    public init(pipeline: RecordingPipeline, onError: @escaping (Error) -> Void) {
        self.pipeline = pipeline
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

        // bufferSize はヒントにすぎず、実測では約100msのバッファが届く。
        // 固定長への切り直しは RecordingPipeline 側が行う。
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        try engine.start()
    }

    public func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try pipeline.finish()
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
            try pipeline.ingest(samples, wallUs: wallUs)
        } catch {
            onError(error)
        }
    }
}

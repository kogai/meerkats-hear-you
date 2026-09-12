import CoreAudio
import Foundation
import MeerkatsCore

/// 1つの会議アプリの出力音声をタップして `RecordingPipeline` に流し込む(ADR-0008)。
///
/// `AudioCapture` の受信側にあたる。**あちらと同じく、ロジックは持たない。**
/// 判断はすべて `MeerkatsCore` 側にあり、ここは Core Audio の手続きを踏んでバッファを渡すだけ。
///
/// **1プロセスにつき1つ作る。** 複数の会議アプリが鳴っているときに何本張るかは、
/// このクラスの外の決定になる(ADR-0013で議論中)。ここを1本に固定すると、その決定が
/// 変わったときに作り直すことになるので、単位を小さく取ってある。
public final class ProcessTap {
    public enum TapError: Error {
        case processNotFound(pid: pid_t)
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        /// タップの形式がパイプラインの前提と違う。実機で初めて分かる種類の失敗なので、
        /// 値を持って返す。
        case unsupportedFormat(channels: UInt32, sampleRate: Double)
        case ioProcFailed(OSStatus)
    }

    private let pipeline: RecordingPipeline
    private let onError: (Error) -> Void

    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateId = AudioObjectID(kAudioObjectUnknown)
    private var ioProcId: AudioDeviceIOProcID?

    public init(pipeline: RecordingPipeline, onError: @escaping (Error) -> Void) {
        self.pipeline = pipeline
        self.onError = onError
    }

    /// 指定した pid のプロセスの出力をタップし始める。
    ///
    /// 手順は3段。**タップを作り、それだけを載せた集約デバイスを作り、IOを回す。**
    /// タップ単体では音を取り出せず、デバイスに載せて初めて読める。
    public func start(pid: pid_t) throws {
        do {
            try beginTapping(pid: pid)
        } catch {
            // **途中で失敗したぶんを必ず戻す。** タップは作れたが集約デバイスで落ちた、
            // という形が普通に起きる。呼び出し側は start が投げたら stop を呼ばないので、
            // ここで戻さないと Core Audio の側にタップが残り続ける。
            teardown()
            throw error
        }
    }

    private func beginTapping(pid: pid_t) throws {
        let processObject = try processObject(for: pid)

        // **モノのミックスダウンで取る。** 話者の分類はしないと決めてあるので(ADR-0012)、
        // チャンネルを分けて取る意味が無い。ADR-0010 の水準では、どのみち帯域も分けない。
        //
        // ステレオで取ると、インターリーブされた列をそのまま1本のサンプル列として読むことになり、
        // 実質のサンプル率が倍になる。取り違えても音は出るので、気づくのが遅れる。
        let description = CATapDescription(monoMixdownOfProcesses: [processObject])
        // 相手の音を消してしまうと会議にならない。読むだけで、出力はそのまま通す。
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tapId)
        guard status == noErr else { throw TapError.tapCreationFailed(status) }

        aggregateId = try createAggregateDevice(tapUID: description.uuid.uuidString)
        let format = try tapFormat()

        // **パイプラインが前提にしている値と突き合わせる。** サンプル率が違えば、
        // 1秒ぶんとして切り出す長さがずれる。ずれても記録は残るので、値を見るまで気づかない。
        // チャンネル数が1でなければ、インターリーブを1本の列として読むことになる。
        // Float32 でなければ、別の並びのビットを Float として読むことになる。
        guard
            format.mChannelsPerFrame == 1,
            format.mSampleRate == pipeline.configuration.sampleRate,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32
        else {
            throw TapError.unsupportedFormat(
                channels: format.mChannelsPerFrame, sampleRate: format.mSampleRate
            )
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcId, aggregateId, nil) {
            [weak self] _, inputData, _, _, _ in
            self?.handle(inputData)
        }
        guard status == noErr, let ioProcId else { throw TapError.ioProcFailed(status) }

        status = AudioDeviceStart(aggregateId, ioProcId)
        guard status == noErr else { throw TapError.ioProcFailed(status) }
    }

    /// 記録を締めて、タップを畳む。
    public func stop() {
        teardown()
        do {
            try pipeline.finish()
        } catch {
            onError(error)
        }
    }

    /// Core Audio の資源だけを戻す。**記録は締めない。**
    ///
    /// `stop()` と分けてあるのは、`start` が途中で失敗したときにも呼ぶためである。
    /// そこで `pipeline.finish()` まで走ると、1本も読んでいない記録を締めることになる。
    /// 何度呼んでも同じ結果になるようにしてある。
    private func teardown() {
        if let ioProcId {
            AudioDeviceStop(aggregateId, ioProcId)
            AudioDeviceDestroyIOProcID(aggregateId, ioProcId)
            self.ioProcId = nil
        }
        // 集約デバイスを先に、タップを後に落とす。逆にすると、まだ載っているタップを
        // 消すことになる。
        if aggregateId != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateId)
            aggregateId = AudioObjectID(kAudioObjectUnknown)
        }
        if tapId != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapId)
            tapId = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// 呼び出し側が stop を呼び忘れても、タップだけは戻す。
    /// **Core Audio の資源はプロセスの生存期間より長く残りうる。**
    deinit {
        teardown()
    }

    // MARK: - Core Audio の手続き

    /// pid からプロセスオブジェクトを引く。
    ///
    /// `AudioProcessList` が写し取る値に含めていないのは、`AudioObjectID` が Core Audio の
    /// 型だからである。**判断側にこの型を持ち込まないために、必要になったここで引き直す。**
    private func processObject(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var input = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &input, &dataSize, &object
        )
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.processNotFound(pid: pid)
        }
        return object
    }

    /// タップだけを載せた私的な集約デバイス。
    ///
    /// 私的にするのは、システムの音声設定に出さないためである。**終日常駐するツールが
    /// 出力先の一覧に居座ると、利用者が誤って選ぶ。** 選ばれた時点で会議の音が消える。
    private func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let uid = "dev.meerkats.tap.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meerkats Tap",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]

        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr else { throw TapError.aggregateDeviceCreationFailed(status) }
        return device
    }

    private func tapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(tapId, &address, 0, nil, &dataSize, &format)
        guard status == noErr else { throw TapError.tapFormatUnavailable(status) }
        return format
    }

    // MARK: - 読み取り

    /// IOスレッドから**直に**呼ばれる。**ここで時間を使わない。** 遅れると音が途切れ、
    /// 記録しようとしている当の現象を自分で作ることになる。
    ///
    /// **いまはその約束を守れていない。** 配列を確保し、時刻を引き、パイプラインを回す。
    /// パイプラインは10秒に1回 SQLite まで到達するので、その1回はIOスレッドで書き込む。
    /// マイク側(`AudioCapture`)も同じ形なので、直すなら両方まとめて、
    /// 確保済みのリングに写して別のスレッドで捌く形になる。**片方だけ直すと、
    /// 2つの経路で理由の違う実装が並ぶ。**
    private func handle(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard let first = buffers.first, let data = first.mData else { return }

        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }

        // 生のPCMはここから先へ渡さない。渡すのはこの配列だけで、
        // RecordingPipeline はフレームごとの値に変換したあと捨てる(ADR-0010)。
        let samples = Array(
            UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
        )
        let wallUs = Int64(Date().timeIntervalSince1970 * 1_000_000)

        do {
            try pipeline.ingest(samples, wallUs: wallUs)
        } catch {
            onError(error)
        }
    }
}

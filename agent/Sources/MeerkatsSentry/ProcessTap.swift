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
        case alreadyRunning
        case processNotFound(pid: pid_t)
        case tapCreationFailed(OSStatus)
        case tapUIDUnavailable(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        /// タップの形式が扱えない並びだった。実機で初めて分かる種類の失敗なので、
        /// 判断に要った値をすべて持って返す。
        case unsupportedFormat(
            formatId: AudioFormatID, flags: AudioFormatFlags,
            channels: UInt32, bitsPerChannel: UInt32, sampleRate: Double
        )
        /// 記録の経路が、渡した率で組まれていなかった。
        case pipelineRateMismatch(tap: Double, pipeline: Double)
        /// 率がフレームの刻みで割り切れず、1フレームごとに端数が出る。
        case rateNotDivisibleIntoFrames(sampleRate: Double, frameMs: Int)
        case ioProcFailed(OSStatus)
    }

    /// タップの実際のサンプル率を受け取って記録の経路を作る。
    ///
    /// **率を渡してから作らせるのが要点。** タップの率は出力デバイスの既定に従うので、
    /// こちらから決められない。48kHz 前提で組んだ経路を後から当てると、44.1kHz の機械では
    /// 毎回弾かれるか、弾かなければ約9%ずれた時系列が黙って記録される。
    public typealias PipelineFactory = (_ sampleRate: Double) throws -> RecordingPipeline

    private let makePipeline: PipelineFactory
    private let onError: (Error) -> Void

    private var pipeline: RecordingPipeline?
    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateId = AudioObjectID(kAudioObjectUnknown)
    private var ioProcId: AudioDeviceIOProcID?

    public init(
        makePipeline: @escaping PipelineFactory, onError: @escaping (Error) -> Void
    ) {
        self.makePipeline = makePipeline
        self.onError = onError
    }

    /// 指定した pid のプロセスの出力をタップし始める。
    ///
    /// 手順は3段。**タップを作り、それだけを載せた集約デバイスを作り、IOを回す。**
    /// タップ単体では音を取り出せず、デバイスに載せて初めて読める。
    public func start(pid: pid_t) throws {
        // **2回目を黙って受け付けない。** 受け付けると、失敗したときの後始末が
        // 1回目の資源を壊し、成功したときは1回目が漏れたまま2本のIOが同じ経路を叩く。
        // 音が混ざるので、ADR-0008 が禁じたものがここから出てくる。
        guard tapId == AudioObjectID(kAudioObjectUnknown),
              aggregateId == AudioObjectID(kAudioObjectUnknown),
              ioProcId == nil
        else {
            throw TapError.alreadyRunning
        }

        do {
            try beginTapping(pid: pid)
        } catch {
            // **途中で失敗したぶんを必ず戻す。** タップは作れたが集約デバイスで落ちた、
            // という形が普通に起きる。呼び出し側は start が投げたら stop を呼ばないので、
            // ここで戻さないと Core Audio の側にタップが残り続ける。
            teardown()
            // 作りかけの経路も手放す。残すと、一度も読んでいないものを stop() が締めにいける。
            pipeline = nil
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

        // **作った実物からUIDを読む。** 渡した記述の値をそのまま使うと、Core Audio が
        // 別のUIDを振っていた場合に、集約デバイスが存在しないタップを指す。
        // そのときも作成自体は成功し、無音がゼロ埋めで返り続ける。
        let uid = try tapUID()
        aggregateId = try createAggregateDevice(tapUID: uid)

        let format = try tapFormat()
        try verify(format)

        // 率はタップが決める。こちらの前提を押し付けない。
        let pipeline = try makePipeline(format.mSampleRate)

        // **渡した率で組まれたことを確かめる。** 確かめないと、呼び出し側が引数を捨てて
        // 既定の48kHzで組んでも通ってしまう。そうなると44.1kHzの機械で約9%ずれた時系列が
        // 黙って記録される。**「毎回落ちる」を「静かにずれる」に振り替えただけになる。**
        guard pipeline.configuration.sampleRate == format.mSampleRate else {
            throw TapError.pipelineRateMismatch(
                tap: format.mSampleRate, pipeline: pipeline.configuration.sampleRate
            )
        }

        // **刻みで割り切れることも確かめる。** 1フレームのサンプル数は切り捨てで整数になるので、
        // 割り切れない率だと1フレームごとに端数を捨てる。捨てた量は溜まり、恒常的なずれになる。
        // 率が合っていることだけ確かめて満足すると、同じ「静かにずれる」を別の入口から通す。
        let exactFrameLength =
            format.mSampleRate * Double(pipeline.configuration.frameMs) / 1000.0
        guard Double(pipeline.configuration.frameLength) == exactFrameLength else {
            throw TapError.rateNotDivisibleIntoFrames(
                sampleRate: format.mSampleRate, frameMs: pipeline.configuration.frameMs
            )
        }
        self.pipeline = pipeline

        // **IOの閉包に self を入れない。** 入れると、最後の強参照がIOスレッドの中で
        // 落ちうる。そこで deinit が走ると、IOスレッドから AudioDeviceStop を呼んで
        // 自分を待つことになる。要るのは経路と誤りの行き先だけなので、それだけ持たせる。
        let onError = self.onError
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcId, aggregateId, nil) {
            _, inputData, _, _, _ in
            ProcessTap.handle(inputData, pipeline: pipeline, onError: onError)
        }
        guard status == noErr, let ioProcId else { throw TapError.ioProcFailed(status) }

        status = AudioDeviceStart(aggregateId, ioProcId)
        guard status == noErr else { throw TapError.ioProcFailed(status) }
    }

    /// 記録を締めて、タップを畳む。
    public func stop() {
        teardown()
        // 先に手放す。締めに失敗したときに、もう一度締めにいかないため。
        let pipeline = self.pipeline
        self.pipeline = nil
        do {
            try pipeline?.finish()
        } catch {
            onError(error)
        }
    }

    /// Core Audio の資源だけを戻す。**記録は締めない。**
    ///
    /// `stop()` と分けてあるのは、`start` が途中で失敗したときにも呼ぶためである。
    /// そこで `finish()` まで走ると、1本も読んでいない記録を締めることになる。
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
    ///
    /// **記録は締まらない。** 溜まっている最大10秒ぶんが消える。締めたいなら stop を呼ぶこと。
    /// ここで締めないのは、deinit の中で失敗を報告する先が無いからである。
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

    private func tapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tapId, &address, 0, nil, &dataSize, $0)
        }
        guard status == noErr, let value else { throw TapError.tapUIDUnavailable(status) }
        return value as String
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

    /// **読み方を決め打ちしている以上、その前提を確かめる。**
    /// どれが違っても音は出るので、値を見るまで気づかない。
    ///
    /// **率は「いくつか」ではなく「扱える範囲か」だけを見る。** いくつになるかはタップが決め、
    /// 記録の経路をその率で組む。ここで見るのは、その率で組めない値を先に弾くことだけになる。
    private func verify(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame == 1,
              // 実在する音声の率の範囲。下を切らないと1フレームのサンプル数が0に落ちて
              // Framer の前提を割る。上を切らないと無限大がここを通り、
              // 整数に直すところで落ちる。
              format.mSampleRate >= 8000, format.mSampleRate <= 768_000
        else {
            throw TapError.unsupportedFormat(
                formatId: format.mFormatID, flags: format.mFormatFlags,
                channels: format.mChannelsPerFrame, bitsPerChannel: format.mBitsPerChannel,
                sampleRate: format.mSampleRate
            )
        }
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
    ///
    /// 型メソッドにしてあるのは、IOの閉包に `self` を入れないためである。**`Self.` ではなく
    /// 型名で書く。** `Self.` は `final` や `static` を外した瞬間に黙って `self` を捕まえ、
    /// 症状は循環参照になって `deinit` が一度も走らなくなる。
    ///
    /// なお `onError` は呼び出し側が書く閉包なので、**そこで自分を強く捕まえれば
    /// 同じ循環が外から作れる。** 呼び出し側で弱く持つこと。
    private static func handle(
        _ bufferList: UnsafePointer<AudioBufferList>,
        pipeline: RecordingPipeline,
        onError: (Error) -> Void
    ) {
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

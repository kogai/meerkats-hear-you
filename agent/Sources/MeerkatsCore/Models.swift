import Foundation

/// 20msフレーム1つから算出した値。生のPCMはここに入らない。
/// 詳細層(ADR-0002)としてリングバッファに載るのもこの型であり、
/// 「内容は復元できない」という要件は保持する値の種類そのもので担保される。
public struct FrameMetrics: Equatable {
    public let monotonicUs: Int64
    public let dbfs: Double
    public let clipRatio: Double
    public let isSpeech: Bool

    public init(monotonicUs: Int64, dbfs: Double, clipRatio: Double, isSpeech: Bool) {
        self.monotonicUs = monotonicUs
        self.dbfs = dbfs
        self.clipRatio = clipRatio
        self.isSpeech = isSpeech
    }
}

/// 常時層(ADR-0002)の1秒ぶんの集約値。
/// minDbfs を持つのは、1秒の中で生じた瞬間的な落ち込みが平均に埋もれないようにするため。
public struct SecondRecord: Equatable {
    public let monotonicUs: Int64
    public let meanDbfs: Double
    public let minDbfs: Double
    public let maxDbfs: Double
    public let speechRatio: Double
    public let clipRatio: Double
    /// このレコードの元になったフレーム数。
    ///
    /// セッション終了時の端数や、キャプチャが途切れた区間では1秒に満たないレコードが生じる。
    /// 比率は件数で正規化されるため、これが無いと1フレームだけのレコードと満了レコードを
    /// 区別できず、分析時に同じ重みで扱ってしまう。
    public let frameCount: Int

    public init(
        monotonicUs: Int64,
        meanDbfs: Double,
        minDbfs: Double,
        maxDbfs: Double,
        speechRatio: Double,
        clipRatio: Double,
        frameCount: Int
    ) {
        self.monotonicUs = monotonicUs
        self.meanDbfs = meanDbfs
        self.minDbfs = minDbfs
        self.maxDbfs = maxDbfs
        self.speechRatio = speechRatio
        self.clipRatio = clipRatio
        self.frameCount = frameCount
    }
}


/// 詳細層として書き出す区間。frames は時刻順。
public struct DetailWindow: Equatable {
    public let startUs: Int64
    public let trigger: String
    public let frames: [FrameMetrics]

    public init(startUs: Int64, trigger: String, frames: [FrameMetrics]) {
        self.startUs = startUs
        self.trigger = trigger
        self.frames = frames
    }
}

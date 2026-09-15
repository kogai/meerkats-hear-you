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

/// 記録できなかった区間(ADR-0015 決定7)。
///
/// **記録の空隙には2種類ある。** 静かだった区間と、測れていなかった区間である。
/// 空隙そのものは同じ形で残るので、区別できるのはこの行があるときだけになる。
/// 残さないと、取りこぼしが「その間ずっと静かだった」と読める
/// ——ADR-0008 が避けようとした「記録上は正常」を、実装の都合で作ることになる。
public struct RecordingGap: Equatable {
    /// なぜ基準を打ち直したか。
    ///
    /// **どれも「途切れたと分かっている」事象である**(ADR-0015 決定2)。
    /// 閾値で推測したものはここに入らない。
    ///
    /// エンジンが走ったまま過負荷でバッファが飛んだ場合は、こちらの知っている事象が
    /// 何も起きない。**それを拾えるのは音声層が報告するサンプル時刻の不連続だけで、
    /// 取れるかどうかがまだ確かめられていない**(ADR-0015「確かめること」)。
    /// 取れると分かった時点でここに1つ増える。
    public enum Reason: String {
        /// 最初のバッファ。セッションの開始からキャプチャが実際に始まるまで。
        case start
        /// 停止してからの再開。ADR-0014 の休止・再開、タップの張り直し。
        case resume
        /// デバイスの差し替え。
        case deviceChange
        /// **読み出し側のためだけにある。** 新しい版が書いた理由を古い版で読んだときに入る。
        /// 書き手はこれを使わない。空隙を落とさずに残すためのもので、
        /// 理由が読めないことと、途切れていないことは別である。
        case unknown
    }

    /// 直前に記録したフレームの**終わり**。最初のバッファではセッションの原点(0)。
    public let startUs: Int64
    /// 打ち直した基準。
    public let endUs: Int64
    public let reason: Reason

    public init(startUs: Int64, endUs: Int64, reason: Reason) {
        self.startUs = startUs
        self.endUs = endUs
        self.reason = reason
    }

    public var durationUs: Int64 { endUs - startUs }
}

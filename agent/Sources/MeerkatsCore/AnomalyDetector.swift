import Foundation

public enum AnomalyKind: String, Equatable {
    case clipping
    case lowLevel
    case dropout
}

/// 1秒レコードの列から異常を検知する(ADR-0002)。
///
/// 同じトリガーが2つの用途を駆動する。詳細層を書き出すかどうかの判断と、
/// 「指摘されずとも気づける」ための通知(ADR-0005)である。新たな検知機構を別に持つ必要はない。
///
/// **判定は保守的に倒してある。** 実機検証の時点で、異常の有無は検出できるが原因の切り分けは
/// 粗いことが分かっている。根拠の薄い通知を繰り返せば利用者は通知を切り、その瞬間に
/// 「気づける」という要件は実質的に満たされなくなる。見逃しよりも誤検知のほうが高くつく。
public struct AnomalyDetector {
    public struct Thresholds: Equatable {
        /// 1秒のうちこの比率を超えてクリップしていれば異常とみなす。
        public var clipRatio: Double
        /// 発話しているのにこのレベルを下回っていれば低すぎるとみなす。
        public var lowLevelDbfs: Double
        /// 発話区間内で最小レベルがノイズフロアからこの幅以内なら、欠落とみなす。
        public var dropoutFloorMarginDb: Double
        /// 同じ1秒の中で最大と最小がこれ以上開いていれば、レベルが二峰化しているとみなす。
        public var dropoutSpreadDb: Double
        /// 発話とみなす最小の発話フレーム比率。無音区間を誤検知しないための足切り。
        public var minSpeechRatio: Double
        /// この秒数だけ continuously 続いて初めて発火する。瞬間的な変動では鳴らさない。
        public var sustainedSeconds: Int

        public init(
            clipRatio: Double = 0.01,
            lowLevelDbfs: Double = -45,
            dropoutFloorMarginDb: Double = 6,
            dropoutSpreadDb: Double = 25,
            minSpeechRatio: Double = 0.2,
            sustainedSeconds: Int = 3
        ) {
            self.clipRatio = clipRatio
            self.lowLevelDbfs = lowLevelDbfs
            self.dropoutFloorMarginDb = dropoutFloorMarginDb
            self.dropoutSpreadDb = dropoutSpreadDb
            self.minSpeechRatio = minSpeechRatio
            self.sustainedSeconds = sustainedSeconds
        }

        /// 自分のマイク側。
        public static let mic = Thresholds()

        /// 受信音声側。**いまは数値がマイク側と同じである。**
        ///
        /// 分けてあるのは、同じ値だからではなく、**意味が違うから分けろと ADR-0008 が
        /// 決めている**ためである。受信側の「音が小さい」は相手の問題で、こちらの入力レベルとは
        /// 別の現象を見ている。
        ///
        /// **数値をどうするかは ADR-0008 に書いていない。** 適正な値は実機で測るまで分からず、
        /// 測る前に動かせば根拠の無い数字が入る。呼び出し側を書き換えずに分岐できる形にして
        /// おくのが、いまできることになる。
        public static let output = Thresholds()

        /// ストリーム種別から閾値を引く。**三項演算子で書かない。**
        /// `StreamKind` に3つ目が増えたとき、三項演算子は黙ってどちらかに倒れる。
        /// switch なら、そこでコンパイルが止まって決め忘れを教えてくれる。
        public static func `for`(_ stream: StreamKind) -> Thresholds {
            switch stream {
            case .mic: return .mic
            case .output: return .output
            }
        }
    }

    public let thresholds: Thresholds
    private var consecutive: [AnomalyKind: Int] = [:]
    private var firing: Set<AnomalyKind> = []

    public init(thresholds: Thresholds = Thresholds()) {
        precondition(thresholds.sustainedSeconds > 0, "sustainedSeconds は正の値である必要がある")
        self.thresholds = thresholds
    }

    /// 現在継続中とみなしている異常。
    public var active: Set<AnomalyKind> { firing }

    /// 1秒レコードを1つ受け取り、**異常に入った瞬間だけ**その種別を返す。
    ///
    /// 継続中は返さない。同じ異常が続いている間に何度も通知すると、利用者は通知を切る。
    public mutating func push(
        _ record: SecondRecord,
        noiseFloorDbfs: Double
    ) -> AnomalyKind? {
        var entered: AnomalyKind?

        for kind in [AnomalyKind.clipping, .lowLevel, .dropout] {
            let present = matches(kind, record: record, noiseFloorDbfs: noiseFloorDbfs)
            if present {
                let count = (consecutive[kind] ?? 0) + 1
                consecutive[kind] = count
                if count >= thresholds.sustainedSeconds, !firing.contains(kind) {
                    firing.insert(kind)
                    // 1秒に複数の異常が立つことはあるが、通知は1つに絞る。
                    // 順序は上の配列のとおりで、原因がはっきりしているものを優先する。
                    if entered == nil { entered = kind }
                }
            } else {
                consecutive[kind] = 0
                firing.remove(kind)
            }
        }
        return entered
    }

    private func matches(
        _ kind: AnomalyKind,
        record: SecondRecord,
        noiseFloorDbfs: Double
    ) -> Bool {
        switch kind {
        case .clipping:
            return record.clipRatio > thresholds.clipRatio

        case .lowLevel:
            guard record.speechRatio >= thresholds.minSpeechRatio else { return false }
            return record.meanDbfs < thresholds.lowLevelDbfs

        case .dropout:
            // 発話しているはずの1秒の中で、通常のレベルとノイズフロア相当が同居している状態。
            // 一様に低い(低ゲイン)のとは別物で、間欠的に音が消えていることを示す。
            guard record.speechRatio >= thresholds.minSpeechRatio else { return false }
            let nearFloor = record.minDbfs <= noiseFloorDbfs + thresholds.dropoutFloorMarginDb
            let wideSpread = record.maxDbfs - record.minDbfs >= thresholds.dropoutSpreadDb
            return nearFloor && wideSpread
        }
    }
}

import Foundation

/// 適応的なエネルギー閾値による発話区間の判定。
///
/// 直近の窓から低パーセンタイルをノイズフロアとして推定し、そこから一定のマージンを
/// 超えたフレームを発話とみなす。
///
/// 実機検証(docs/experiments/mac-mic-verification-result.md)では、この方式とWebRTC VADの
/// 判定は90.8%一致し、両者が算出した発話レベルの差は0.46dBに収まった。記録の本体である
/// 音声レベルはVADの選択にほとんど左右されないため、まずはこの方式で始める。
/// ただし低SN比の条件ではWebRTC VADのほうが頑健であることも分かっているため、
/// 精度が問題になる場合はそちらへの差し替えを検討する。
public struct SpeechDetector {
    public let marginDb: Double
    public let floorPercentile: Double
    public let recomputeInterval: Int

    private var window: [Double]
    private var writeIndex = 0
    private var filled = 0
    private var framesSinceRecompute: Int
    private var cachedFloor: Double

    /// - Parameters:
    ///   - windowFrames: ノイズフロア推定に使う窓の長さ。既定は20msフレームで30秒ぶん。
    ///     会話中は発話が6〜8割を占めるため、窓が短いと低パーセンタイルまで発話レベルに
    ///     押し上げられ、発話を拾えなくなる。
    ///   - recomputeInterval: フロアを再計算する間隔(フレーム数)。既定は1秒ごと。
    ///     フロアはゆっくりしか動かないため毎フレーム計算する必要がなく、
    ///     常時稼働での消費を抑える意味もある(ADR-0004)。
    public init(
        windowFrames: Int = 1500,
        marginDb: Double = 12.0,
        floorPercentile: Double = 0.15,
        recomputeInterval: Int = 50
    ) {
        precondition(windowFrames > 0, "windowFrames は正の値である必要がある")
        precondition(recomputeInterval > 0, "recomputeInterval は正の値である必要がある")
        precondition(
            floorPercentile >= 0 && floorPercentile <= 1,
            "floorPercentile は0から1の範囲である必要がある"
        )
        self.marginDb = marginDb
        self.floorPercentile = floorPercentile
        self.recomputeInterval = recomputeInterval
        window = Array(repeating: 0, count: windowFrames)
        framesSinceRecompute = recomputeInterval  // 最初のフレームで一度計算する
        cachedFloor = Levels.floorDbfs
    }

    public var noiseFloorDbfs: Double { cachedFloor }
    public var thresholdDbfs: Double { cachedFloor + marginDb }

    public mutating func push(_ dbfs: Double) -> Bool {
        window[writeIndex] = dbfs
        writeIndex = (writeIndex + 1) % window.count
        if filled < window.count { filled += 1 }

        framesSinceRecompute += 1
        if framesSinceRecompute >= recomputeInterval {
            cachedFloor = estimateFloor()
            framesSinceRecompute = 0
        }

        return dbfs > cachedFloor + marginDb
    }

    private func estimateFloor() -> Double {
        guard filled > 0 else { return Levels.floorDbfs }
        let sorted = window[0 ..< filled].sorted()
        let index = Int((Double(sorted.count - 1) * floorPercentile).rounded())
        return sorted[index]
    }
}

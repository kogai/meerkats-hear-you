import Darwin
import Foundation

/// セッション開始からの経過を返す時計。テストで差し替えられるようにプロトコルにしてある。
public protocol MonotonicClock {
    func nowUs() -> Int64
}

/// ADR-0003 が指定する「連続単調時計」。スリープ中も進む側を使う。
///
/// macOSの単調時計は2系統あり、`mach_absolute_time()` はスリープ中に止まる。
/// そちらを選ぶとスリープした分だけタイムラインが詰まり、記録の欠落区間の長さが
/// 実際の経過時間と一致しなくなるため、実時刻アンカーからの換算が崩れる。
public final class ContinuousMonotonicClock: MonotonicClock {
    private let startTicks: UInt64
    private let numerator: Double
    private let denominator: Double

    public init() {
        var info = mach_timebase_info_data_t()
        _ = mach_timebase_info(&info)
        numerator = Double(info.numer)
        denominator = Double(info.denom)
        startTicks = mach_continuous_time()
    }

    public func nowUs() -> Int64 {
        let ticks = mach_continuous_time() &- startTicks
        let nanos = Double(ticks) * numerator / denominator
        return Int64(nanos / 1000.0)
    }
}

/// 単調時刻と実時刻の対応点(ADR-0003)。
public struct ClockAnchor: Equatable {
    public let monotonicUs: Int64
    /// UTCエポックからのマイクロ秒。タイムゾーンとDSTは保存時点では扱わない。
    public let wallUs: Int64

    public init(monotonicUs: Int64, wallUs: Int64) {
        self.monotonicUs = monotonicUs
        self.wallUs = wallUs
    }
}

/// アンカーを一定間隔で打つ。
///
/// セッション開始時の1点だけに頼ると、その瞬間にNTPがずれていればセッション全体が
/// まとめてずれ、長時間のドリフトも検出できない(ADR-0003)。
public struct AnchorScheduler {
    public let intervalUs: Int64
    private var lastAnchorUs: Int64?

    public init(intervalSeconds: Int = 300) {
        precondition(intervalSeconds > 0, "intervalSeconds は正の値である必要がある")
        intervalUs = Int64(intervalSeconds) * 1_000_000
    }

    /// 間隔に達していればアンカーを返す。最初の呼び出しでは必ず返す。
    public mutating func anchorIfDue(monotonicUs: Int64, wallUs: Int64) -> ClockAnchor? {
        if let last = lastAnchorUs, monotonicUs - last < intervalUs {
            return nil
        }
        lastAnchorUs = monotonicUs
        return ClockAnchor(monotonicUs: monotonicUs, wallUs: wallUs)
    }
}

/// ひとつのストリームのアンカー列。
///
/// **素の配列で渡さない。** `[ClockAnchor]` を受ける形だと、2本のストリームのアンカーを
/// 繋げた配列も、片方のIDで引いた配列をもう片方に使うのも、型を通ってしまう。
///
/// そして**壊れ方が静かで、混ぜたほうが自信ありげな答えを出す。** 混ざった列は
/// 間隔が細かくなるので `interpolate` が返す不確かさは小さくなるが、内挿の相手は
/// 別のクロックに乗った点なので、値そのものは外れる。ADR-0003 が TrueTime から採った
/// **「真値は区間に入る」という約束が、そこで破れる。**
public struct StreamAnchors: Equatable {
    public let streamId: Int64
    public let anchors: [ClockAnchor]

    public init(streamId: Int64, anchors: [ClockAnchor]) {
        self.streamId = streamId
        self.anchors = anchors
    }

    public var isEmpty: Bool { anchors.isEmpty }
}

/// 実時刻への換算結果。
///
/// ADR-0003 は TrueTime(Spanner)にならい、時刻を点ではなく不確かさを伴う区間として扱うと
/// 決めている。換算値を正確なものとして扱うと、分析時に根拠のない精度で事象を並べることになる。
public struct WallClockEstimate: Equatable {
    public let wallUs: Int64
    public let uncertaintyUs: Int64

    public init(wallUs: Int64, uncertaintyUs: Int64) {
        self.wallUs = wallUs
        self.uncertaintyUs = uncertaintyUs
    }

    public var earliestUs: Int64 { wallUs - uncertaintyUs }
    public var latestUs: Int64 { wallUs + uncertaintyUs }
}

public enum ClockConversion {
    /// アンカーが1つしかない場合に、経過時間から見込むドリフトの上限(百万分率)。
    /// 民生用の発振器の誤差として保守的に置いた値。
    public static let assumedDriftPpm: Double = 100

    /// 単調時刻を実時刻へ換算する。アンカーが無ければ換算できない。
    ///
    /// **同じストリームのアンカーだけを使う。** ストリームごとに `wall_us` の伸び方が違うので、
    /// 別のストリームの点を混ぜると内挿の相手が別のクロックになる(`StreamAnchors` 参照)。
    public static func wallTime(
        forMonotonicUs target: Int64,
        in stream: StreamAnchors
    ) -> WallClockEstimate? {
        guard !stream.isEmpty else { return nil }
        let sorted = stream.anchors.sorted { $0.monotonicUs < $1.monotonicUs }

        if let bracket = bracketing(target, in: sorted) {
            return interpolate(target, low: bracket.low, high: bracket.high)
        }

        // 範囲外。最も近い端から外挿する。
        let nearest = target < sorted[0].monotonicUs ? sorted[0] : sorted[sorted.count - 1]
        let elapsed = abs(target - nearest.monotonicUs)
        return WallClockEstimate(
            wallUs: nearest.wallUs + (target - nearest.monotonicUs),
            uncertaintyUs: driftAllowanceUs(forElapsedUs: elapsed)
        )
    }

    static func driftAllowanceUs(forElapsedUs elapsed: Int64) -> Int64 {
        Int64((Double(elapsed) * assumedDriftPpm / 1_000_000).rounded())
    }

    private static func bracketing(
        _ target: Int64, in sorted: [ClockAnchor]
    ) -> (low: ClockAnchor, high: ClockAnchor)? {
        guard sorted.count >= 2 else { return nil }
        for index in 0 ..< (sorted.count - 1) {
            let low = sorted[index]
            let high = sorted[index + 1]
            if target >= low.monotonicUs && target <= high.monotonicUs {
                return (low, high)
            }
        }
        return nil
    }

    private static func interpolate(
        _ target: Int64, low: ClockAnchor, high: ClockAnchor
    ) -> WallClockEstimate {
        let span = high.monotonicUs - low.monotonicUs
        guard span > 0 else {
            return WallClockEstimate(wallUs: low.wallUs, uncertaintyUs: 0)
        }
        let ratio = Double(target - low.monotonicUs) / Double(span)
        let wall = low.wallUs + Int64((Double(high.wallUs - low.wallUs) * ratio).rounded())

        // この区間で2つの時計がどれだけ食い違ったかが、そのまま不確かさの幅になる。
        // アンカーを複数持つのはこれを測れるようにするため。
        let drift = abs((high.wallUs - low.wallUs) - span)
        return WallClockEstimate(wallUs: wall, uncertaintyUs: drift)
    }
}

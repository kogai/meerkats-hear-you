import Foundation

/// 20msフレームを1秒ぶんに集約する(ADR-0002の常時層)。
public struct Aggregator {
    public let framesPerRecord: Int
    private var pending: [FrameMetrics] = []

    /// - Parameter frameMs: フレーム長(ミリ秒)。1000を割り切れる必要がある。
    public init(frameMs: Int) {
        precondition(frameMs > 0 && 1000 % frameMs == 0, "frameMs は1000を割り切れる必要がある")
        framesPerRecord = 1000 / frameMs
        pending.reserveCapacity(framesPerRecord)
    }

    /// フレームを1つ受け取り、1秒ぶん溜まったらレコードを返す。
    public mutating func push(_ metrics: FrameMetrics) -> SecondRecord? {
        pending.append(metrics)
        guard pending.count >= framesPerRecord else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return Aggregator.makeRecord(from: pending)
    }

    /// セッション終了時などに、溜まっている端数を吐き出す。
    public mutating func flush() -> SecondRecord? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return Aggregator.makeRecord(from: pending)
    }

    static func makeRecord(from frames: [FrameMetrics]) -> SecondRecord {
        let levels = frames.map(\.dbfs)
        let speechCount = frames.reduce(into: 0) { count, frame in
            if frame.isSpeech { count += 1 }
        }
        let clipSum = frames.reduce(0.0) { $0 + $1.clipRatio }
        return SecondRecord(
            monotonicUs: frames[0].monotonicUs,
            meanDbfs: Levels.powerMeanDbfs(levels) ?? Levels.floorDbfs,
            minDbfs: levels.min() ?? Levels.floorDbfs,
            maxDbfs: levels.max() ?? Levels.floorDbfs,
            speechRatio: Double(speechCount) / Double(frames.count),
            clipRatio: clipSum / Double(frames.count),
            frameCount: frames.count
        )
    }
}

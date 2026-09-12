import Foundation

/// 常時表示が読む現在の状態(ADR-0005)。
///
/// 表示はここから読み、SQLiteを経由しない。ADR-0004で書き込みを数秒ごとにまとめると決めたため、
/// DB経由で読むと表示がその間隔ぶん遅れる。「今どうなっているか」を見るための表示が
/// 数秒前を映すのでは用をなさない。
///
/// 書き込みは音声処理のスレッド、読み出しは表示のスレッドから行われるため、ロックで保護する。
public final class LiveState {
    public struct Snapshot: Equatable {
        public let meanDbfs: Double
        public let isSpeaking: Bool
        public let noiseFloorDbfs: Double
        public let activeAnomalies: Set<AnomalyKind>
        /// 直近1分ぶんの1秒レベル。古い順。
        public let recentLevels: [Double]

        public init(
            meanDbfs: Double,
            isSpeaking: Bool,
            noiseFloorDbfs: Double,
            activeAnomalies: Set<AnomalyKind>,
            recentLevels: [Double]
        ) {
            self.meanDbfs = meanDbfs
            self.isSpeaking = isSpeaking
            self.noiseFloorDbfs = noiseFloorDbfs
            self.activeAnomalies = activeAnomalies
            self.recentLevels = recentLevels
        }
    }

    private let lock = NSLock()
    private let historyCapacity: Int
    private var history: [Double] = []
    private var meanDbfs = Levels.floorDbfs
    private var isSpeaking = false
    private var noiseFloorDbfs = Levels.floorDbfs
    private var anomalies: Set<AnomalyKind> = []

    /// - Parameter historySeconds: 表示に使う直近の秒数。既定は1分。
    public init(historySeconds: Int = 60) {
        precondition(historySeconds > 0, "historySeconds は正の値である必要がある")
        historyCapacity = historySeconds
        history.reserveCapacity(historySeconds)
    }

    public func update(
        record: SecondRecord,
        noiseFloorDbfs floor: Double,
        anomalies active: Set<AnomalyKind>
    ) {
        lock.lock()
        defer { lock.unlock() }

        meanDbfs = record.meanDbfs
        isSpeaking = record.speechRatio > 0
        noiseFloorDbfs = floor
        anomalies = active

        history.append(record.meanDbfs)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            meanDbfs: meanDbfs,
            isSpeaking: isSpeaking,
            noiseFloorDbfs: noiseFloorDbfs,
            activeAnomalies: anomalies,
            recentLevels: history
        )
    }
}

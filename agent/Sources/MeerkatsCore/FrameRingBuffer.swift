import Foundation

/// 直近のフレーム値を保持する固定長のリングバッファ(ADR-0002の詳細層)。
///
/// 異常を検知した時点で書き出すため、「異常が始まる前」のフレームも残す必要がある。
/// そのために常時ここへ流し込んでおき、トリガー発火時に中身を取り出す。
///
/// 保持するのはフレームから算出した値だけで、PCMは持たない。
public struct FrameRingBuffer {
    public let capacity: Int
    private var storage: [FrameMetrics] = []
    /// 一周したあとに次へ書き込む位置。これは同時に「最も古い要素の位置」でもある。
    private var writeIndex = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity は正の値である必要がある")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ metrics: FrameMetrics) {
        if storage.count < capacity {
            storage.append(metrics)
            writeIndex = storage.count % capacity
        } else {
            storage[writeIndex] = metrics
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    /// 保持しているフレームを古い順に返す。
    public func snapshot() -> [FrameMetrics] {
        // まだ一周していなければ、追加順がそのまま時刻順。
        guard storage.count == capacity else { return storage }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        writeIndex = 0
    }
}

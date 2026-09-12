import Foundation

/// 直近のフレーム値を保持する固定長のリングバッファ(ADR-0002の詳細層)。
///
/// 異常を検知した時点で書き出すため、「異常が始まる前」のフレームも残す必要がある。
/// そのために常時ここへ流し込んでおき、トリガー発火時に中身を取り出す。
///
/// 保持するのはフレームから算出した値だけで、PCMは持たない。
public struct FrameRingBuffer {
    public let capacity: Int
    private var storage: [FrameMetrics?]
    private var writeIndex = 0
    private var filled = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity は正の値である必要がある")
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    public var count: Int { filled }

    public mutating func append(_ metrics: FrameMetrics) {
        storage[writeIndex] = metrics
        writeIndex = (writeIndex + 1) % capacity
        if filled < capacity { filled += 1 }
    }

    /// 保持しているフレームを古い順に返す。
    public func snapshot() -> [FrameMetrics] {
        guard filled > 0 else { return [] }
        var out: [FrameMetrics] = []
        out.reserveCapacity(filled)
        let start = (writeIndex - filled + capacity) % capacity
        for offset in 0 ..< filled {
            if let metrics = storage[(start + offset) % capacity] {
                out.append(metrics)
            }
        }
        return out
    }

    public mutating func removeAll() {
        for index in storage.indices { storage[index] = nil }
        writeIndex = 0
        filled = 0
    }
}

import Foundation

/// OSから届く音声バッファを固定長のフレームに切り直す。
///
/// スパイクの実測(docs/experiments/macos-app-bundle-spike-result.md)では、
/// AVAudioEngineのタップに1024サンプル(48kHzで約21ms)を指定しても実際には約100msの
/// バッファが届いた。`bufferSize` はヒントにすぎず、実際の長さはデバイス側の都合で決まる。
///
/// ADR-0002が前提とする20msという粒度は、したがってバッファ長に依存させず、
/// ここで自前で切り直して作る。
public struct Framer {
    public let frameLength: Int
    private var carry: [Float] = []

    public init(frameLength: Int) {
        precondition(frameLength > 0, "frameLength は正の値である必要がある")
        self.frameLength = frameLength
    }

    /// 受け取ったサンプルから固定長フレームを取り出す。端数は次回に持ち越す。
    public mutating func push(_ samples: [Float]) -> [[Float]] {
        carry.append(contentsOf: samples)
        guard carry.count >= frameLength else { return [] }

        var frames: [[Float]] = []
        var offset = 0
        while carry.count - offset >= frameLength {
            frames.append(Array(carry[offset ..< offset + frameLength]))
            offset += frameLength
        }
        carry.removeFirst(offset)
        return frames
    }

    /// まだフレームにできていないサンプル数。常に frameLength 未満。
    public var pendingSampleCount: Int { carry.count }

    public mutating func reset() {
        carry.removeAll(keepingCapacity: true)
    }
}

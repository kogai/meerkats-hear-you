import Foundation

/// 音のスレッドから記録側へサンプルを渡すためのリング(ADR-0016 決定1〜4)。
///
/// **この型はまだスレッドを跨いで使えない。** 添字をアトミックに持つことと、記憶域を
/// 生のメモリにすることは次の段でやる。ここにあるのは**枠の取り方と取りこぼしの勘定**だけで、
/// そこが合っていないまま並行にすると、原因の分からない壊れ方をする。
/// 先に単スレッドで固めておけば、次の段は意味を変えずに記憶域だけ入れ替える作業になる。
public struct SampleRing {
    /// 取り出した1回ぶん。
    public struct Chunk: Equatable {
        /// 音のスレッドがこのバッファを受け取ったときの時計の読み。
        public let clockUs: Int64
        public let samples: [Float]
        /// **これより前に捨てたサンプル数。**
        ///
        /// 総数ではなく「どこで捨てたか」を持つ。総数だけだと、受け取った側は
        /// 何サンプル失ったかは分かっても**どこで失ったかが分からない**ので、
        /// 空隙をどの時刻に置けばよいかが決まらない(ADR-0016 決定3)。
        public let droppedBefore: Int
    }

    private struct Header {
        var clockUs: Int64
        var start: Int
        var count: Int
        var droppedBefore: Int
    }

    private var samples: [Float]
    private var headers: [Header]
    /// 次に読み出すサンプルの位置。
    private var sampleHead = 0
    /// 使用中のサンプル数。`samples.count` との差が空き。
    private var sampleUsed = 0
    private var headerHead = 0
    private var headerUsed = 0
    /// まだどの `Chunk` にも付けていない取りこぼし。次に入った書き込みに付く。
    private var pendingDropped = 0

    /// - Parameters:
    ///   - sampleCapacity: 抱えるサンプル数。**可変長のペイロードを詰めるので、
    ///     1回ぶんの固定枠ではない**(ADR-0016 決定4)。
    ///   - chunkCapacity: 抱えられる書き込み回数。サンプルに空きがあっても
    ///     こちらが尽きれば捨てる。
    public init(sampleCapacity: Int, chunkCapacity: Int) {
        precondition(sampleCapacity > 0, "sampleCapacity は正の値である必要がある")
        precondition(chunkCapacity > 0, "chunkCapacity は正の値である必要がある")
        samples = [Float](repeating: 0, count: sampleCapacity)
        headers = [Header](
            repeating: Header(clockUs: 0, start: 0, count: 0, droppedBefore: 0),
            count: chunkCapacity
        )
    }

    /// **溢れたら新しいほうを捨てる**(ADR-0016 決定2)。
    ///
    /// 古いほうを捨てる形にすると、書き手が読み手の読んでいるスロットを上書きする。
    /// 単一生産者・単一消費者のリングが成り立たなくなる。
    ///
    /// - Returns: 入れば `true`、捨てたら `false`。
    @discardableResult
    public mutating func write(clockUs: Int64, _ incoming: UnsafeBufferPointer<Float>) -> Bool {
        let needed = incoming.count
        guard needed > 0 else { return true }
        // 容量そのものを超えるバッファは、空にしても入らない。待たずに捨てる。
        guard headerUsed < headers.count, sampleUsed + needed <= samples.count else {
            pendingDropped += needed
            return false
        }

        let start = (sampleHead + sampleUsed) % samples.count
        for offset in 0 ..< needed {
            samples[(start + offset) % samples.count] = incoming[incoming.startIndex + offset]
        }
        headers[(headerHead + headerUsed) % headers.count] = Header(
            clockUs: clockUs, start: start, count: needed, droppedBefore: pendingDropped
        )
        sampleUsed += needed
        headerUsed += 1
        pendingDropped = 0
        return true
    }

    /// 配列から書く。**音のスレッドからは使わない。** 試験と、実時間でない呼び手のため。
    @discardableResult
    public mutating func write(clockUs: Int64, _ incoming: [Float]) -> Bool {
        incoming.withUnsafeBufferPointer { write(clockUs: clockUs, $0) }
    }

    /// 古いほうから1回ぶん取り出す。
    public mutating func read() -> Chunk? {
        guard headerUsed > 0 else { return nil }
        let header = headers[headerHead]

        var out = [Float](repeating: 0, count: header.count)
        for offset in 0 ..< header.count {
            out[offset] = samples[(header.start + offset) % samples.count]
        }

        headerHead = (headerHead + 1) % headers.count
        headerUsed -= 1
        sampleHead = (sampleHead + header.count) % samples.count
        sampleUsed -= header.count
        return Chunk(clockUs: header.clockUs, samples: out, droppedBefore: header.droppedBefore)
    }

    /// **まだどの `Chunk` にも付いていない取りこぼし。**
    ///
    /// 捨てたあと一度も書き込みが成功しないまま終わると、その取りこぼしは
    /// `Chunk.droppedBefore` に乗らない。終了時にここを見て空隙を残さないと、
    /// **記録は「その間は静かだった」と読める**(ADR-0016 決定3)。
    public var pendingDroppedSamples: Int { pendingDropped }

    public var isEmpty: Bool { headerUsed == 0 }
    /// 抱えている書き込み回数。
    public var count: Int { headerUsed }
    /// 抱えているサンプル数。リングの長さを実測で決めるときに見る。
    public var bufferedSamples: Int { sampleUsed }
}

import Foundation

/// 音のスレッドと、止める側とで共有する記録経路の入れ物。
///
/// **閉包に経路そのものを渡すと、止められなくなる。** 値で渡せば、止める側が自分の参照を
/// 手放しても閉包の参照は無傷で、締めたあとの経路に流し込み続ける。そこで `finish()` と
/// `ingest` が同じ中身を同時に触ることになり、**競合が変数から中身へ移るだけ**になる。
///
/// `take()` が唯一の取り出し口で、**取り出しと断ちが錠の中で不可分に起きる。**
/// だから取り出したあとは、錠の外で締めてよい。閉包側はその時点で nil しか見ない。
///
/// **音のスレッドで錠を取ることになる。** そこで待たされる相手は `take()` だけで、
/// あちらの臨界区間は参照を1つ入れ替えるだけなので、待ち時間に上限がある。
/// `NSLock` は優先度継承を持たないが、上限が閉じているので青天井の逆転にはならない。
///
/// **代償は逆向きに出る。** 止める側が、在庫の `ingest` が終わるまで待つ。`ingest` は
/// 10秒に1回 SQLite まで到達するので、その1回にぶつかると止めるのが遅れる。
/// **挟む前の止める側は絶対に待たなかった**ので、これは新しく入れた待ちである。
/// IOスレッドから記録を追い出せば両方消えるが、それは別の話になる。
public final class PipelineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: RecordingPipeline?

    public init(_ pipeline: RecordingPipeline) {
        self.pipeline = pipeline
    }

    /// 経路が生きていれば流す。断たれたあとは黙って捨てる。
    /// **捨てるのが正しい。** 締めたあとに届いたバッファは、記録の外の音である。
    public func ingest(_ samples: [Float], wallUs: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try pipeline?.ingest(samples, wallUs: wallUs)
    }

    /// 経路を取り出して断つ。以後 `ingest` は何もしない。
    /// 2回目からは nil を返す。**取り出した側だけが締める。**
    public func take() -> RecordingPipeline? {
        lock.lock()
        defer { lock.unlock() }
        let taken = pipeline
        pipeline = nil
        return taken
    }
}

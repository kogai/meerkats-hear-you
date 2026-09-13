import Foundation

/// 記録してよい区間だけ書き込みを通す(ADR-0014)。
///
/// `RecordingGate` の判断を、実際の書き込みに効かせる。**間に挟むだけで、経路そのものは
/// 止めない。** 止めると発話の判定も止まり、再開の合図を受け取る手段が無くなる。
///
/// 1秒レコードは休止中も流れてくる。ここで捨てるだけで、`RecordingGate` には毎回渡す。
///
/// **いま記録しているかを外から読めるようにはしていない。** 判定は音声のスレッドで進むので、
/// 表示のスレッドから覗くと競合する。表示に出すなら `onTransition` を受けて
/// `LiveState` に入れること。あちらは錠で守ってある。
public final class GatedSink: RecordingPipeline.Sink {
    private let inner: RecordingPipeline.Sink
    private var gate: RecordingGate

    /// 休止と再開の瞬間に呼ばれる。受信音声のタップを畳む・張り直すのに使う。
    ///
    /// **音声を流し込んでいるスレッドから呼ばれる。** そこでタップを張り直すと、
    /// 音の処理を止めることになる。受け取った側で主スレッドに渡すこと。
    public var onTransition: ((RecordingGate.Transition) -> Void)?

    public init(wrapping inner: RecordingPipeline.Sink, gate: RecordingGate = RecordingGate()) {
        self.inner = inner
        self.gate = gate
    }

    /// **1件ずつ判断する。** まとめ書きの区切り(ADR-0004)は最大10秒ぶんを運ぶので、
    /// 束の途中で休止に入ることがある。束ごと捨てると、休止までの区間まで落ちる。
    public func write(seconds records: [SecondRecord]) throws {
        var allowed: [SecondRecord] = []
        allowed.reserveCapacity(records.count)

        for record in records {
            let wasRecording = gate.isRecording
            if let transition = gate.push(record) {
                onTransition?(transition)
            }
            // 境目のレコードは通す。休止に入った秒も、再開した秒も、
            // **その瞬間が記録に残っていないと、あとから境目を指させない。**
            if wasRecording || gate.isRecording {
                allowed.append(record)
            }
        }

        guard !allowed.isEmpty else { return }
        try inner.write(seconds: allowed)
    }

    /// 詳細層は休止中に書かない。**異常の判定自体は動いている**が、
    /// 会議でない区間の20ms刻みを残す理由が無い。
    public func write(detail: DetailWindow) throws {
        guard gate.isRecording else { return }
        try inner.write(detail: detail)
    }

    /// 時刻のアンカーも休止中は書かない。記録が無い区間に打つ意味が無い。
    public func write(anchor: ClockAnchor) throws {
        guard gate.isRecording else { return }
        try inner.write(anchor: anchor)
    }
}

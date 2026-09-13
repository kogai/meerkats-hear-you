import Foundation

/// 記録してよい区間かどうかの見立て(ADR-0014)。
///
/// **自分の発話を手がかりにする。** 会議アプリが鳴っているかどうかは待機中と区別がつかず、
/// 音が鳴っているかどうかは音楽を聴いているだけの状態と区別がつかない。独り言を除けば、
/// **人は相手が居るときに話す。**
///
/// 判定はマイク側の1秒レコードだけで閉じる。プロセスの列挙も、許可の追加も要らない。
///
/// **休止中もレコードは流し込み続けること。** 止めると再開の合図を受け取る手段が無くなる。
/// 記録に残さないだけで、発話の判定自体は動かし続ける(ADR-0014)。
public struct RecordingGate {
    public enum Transition: Equatable {
        case suspended
        case resumed
    }

    /// 無言がこれだけ続いたら休止する。
    private let idleUs: Int64
    /// 1秒のうちこの比率を超えて発話していれば、話したとみなす。
    /// `AnomalyDetector` が発話区間の足切りに使う値と揃えてある。
    private let minSpeechRatio: Double

    /// 最後に話した時刻。**まだ一度も話していない間は、最初に見たレコードの時刻が入る。**
    /// 起動してからずっと無言なら、そこから数えて休止する。
    private var lastSpeechUs: Int64?

    /// いま記録してよいか。**起動直後は記録する。** 会議の途中で立ち上げることがある。
    public private(set) var isRecording = true

    public init(idleSeconds: Int = 600, minSpeechRatio: Double = 0.2) {
        idleUs = Int64(idleSeconds) * 1_000_000
        self.minSpeechRatio = minSpeechRatio
    }

    /// 1秒ぶんのマイクのレコードを渡す。状態が変わったときだけ返す。
    ///
    /// 経過は**レコードの時刻で測る。** 件数で数えると、端数のレコードや、キャプチャが
    /// 途切れた区間のぶんだけ休止が遅れる。
    public mutating func push(_ record: SecondRecord) -> Transition? {
        let spoke = record.speechRatio >= minSpeechRatio

        if spoke {
            lastSpeechUs = record.monotonicUs
            if isRecording { return nil }
            isRecording = true
            return .resumed
        }

        // まだ一度も話していない。ここを起点にして数え始める。
        guard let since = lastSpeechUs else {
            lastSpeechUs = record.monotonicUs
            return nil
        }

        let idle = record.monotonicUs - since
        if isRecording, idle >= idleUs {
            isRecording = false
            return .suspended
        }
        return nil
    }
}

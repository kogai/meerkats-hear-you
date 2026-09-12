import Foundation

/// タップの対象になりうるプロセス。
///
/// Core Audio から引いた実物をこの形に写してから判断に渡す。値そのものは実機でしか取れないが、
/// **どれを録るかの判断はここで閉じる。** 選び方を間違えたときに実機でしか気づけない、
/// という状態を作らないため。
public struct AudioProcess: Equatable {
    public var pid: Int32
    /// `kAudioProcessPropertyBundleID` から引く。取れないプロセスもあるので省略可能にしてある。
    public var bundleId: String?
    /// 表示と記録に残す名前。バンドルIDが無いときの手掛かりでもある。
    public var name: String
    /// いま実際に音を出しているか(`kAudioProcessPropertyIsRunningOutput`)。
    ///
    /// **起動しているかどうかでは足りない。** 会議アプリは会議をしていなくても常駐している。
    /// 鳴っていないものを録ると、無音がそのまま「相手が黙っている」として記録に残る。
    public var isRunningOutput: Bool

    public init(pid: Int32, bundleId: String?, name: String, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.isRunningOutput = isRunningOutput
    }
}

/// どのプロセスを録るかの決定(ADR-0008)。
public enum TapSelection: Equatable {
    /// 会議アプリが音を出していない。録るものが無い。
    case idle
    /// これを録る。
    case tap(AudioProcess)
    /// 複数の会議アプリが同時に鳴っている。先頭を録る。
    ///
    /// **混ぜて録るという選択肢は無い。** 途切れがどちらのものか分からない記録は、
    /// ADR-0008 が避けようとしたもの、つまり解釈できない記録そのものになる。
    /// 選ばなかったほうも持って返すのは、表示で「Zoom を録っています」と言えるようにするため。
    /// 黙って片方を捨てると、利用者は録れていないことに気づけない。
    case tapWithOthersSounding(AudioProcess, others: [AudioProcess])

    /// 実際に録る対象。呼び出し側が2つのケースを毎回ほどかずに済むようにする。
    public var target: AudioProcess? {
        switch self {
        case .idle: return nil
        case .tap(let process): return process
        case .tapWithOthersSounding(let process, _): return process
        }
    }
}

/// 会議アプリの見分け方(ADR-0008の「プロセスを限定する」)。
///
/// **ブラウザは入れていない。** Google Meet はブラウザの中で動くので、対象にするなら
/// ブラウザ本体をタップすることになる。それは他のタブの音も一緒に録ることを意味し、
/// ADR-0008 の限定が効かなくなる。動画も広告も同じ記録に混ざり、途切れが相手のものか
/// どうかを見分けられない。対応するならタブ単位で分ける手段が要り、それは別の決定になる。
public enum ConferencingApps {
    /// 会議アプリとみなすバンドルIDの**前置**。
    ///
    /// 前方一致にしてあるのは補助プロセス対策である。音声が本体ではなく
    /// `us.zoom.xos.helper` のような子プロセスに出ている可能性を ADR-0008 が
    /// 未検証の前提として挙げており、完全一致だとその場合に一つも拾えない。
    ///
    /// 並びは優先順位そのもの。**会議専用のアプリを、通話もできるチャットアプリより先に置く。**
    /// 両方が鳴っているとき、会議をしている確率が高いのは前者だからで、それ以上の根拠は無い。
    /// 実機で外すようなら、ここを並べ替えれば済むようにしてある。
    public static let bundleIdPrefixes: [String] = [
        "us.zoom.xos",              // Zoom
        "com.microsoft.teams",      // Microsoft Teams (teams2 も前方一致で入る)
        "com.cisco.webexmeetingsapp",  // Webex
        "com.tinyspeck.slackmacgap",   // Slack (ハドル)
        "com.hnc.Discord",          // Discord
    ]

    /// 鳴っている会議アプリから、録る一つを決める。
    ///
    /// - Parameter processes: Core Audio が持っているプロセスの一覧。順序は問わない。
    public static func select(from processes: [AudioProcess]) -> TapSelection {
        let candidates = processes
            .filter { $0.isRunningOutput }
            .compactMap { process -> (rank: Int, process: AudioProcess)? in
                guard let rank = priority(of: process) else { return nil }
                return (rank, process)
            }
            // 同じ優先順位のプロセスが複数あるとき、並びが起動順で揺れると
            // 録る対象が実行のたびに変わる。pid で縛って決定的にする。
            .sorted { ($0.rank, $0.process.pid) < ($1.rank, $1.process.pid) }
            .map { $0.process }

        guard let chosen = candidates.first else { return .idle }
        let others = Array(candidates.dropFirst())
        return others.isEmpty ? .tap(chosen) : .tapWithOthersSounding(chosen, others: others)
    }

    /// 会議アプリなら `bundleIdPrefixes` での位置を、そうでなければ nil を返す。
    static func priority(of process: AudioProcess) -> Int? {
        guard let bundleId = process.bundleId else { return nil }
        return bundleIdPrefixes.firstIndex { bundleId.hasPrefix($0) }
    }
}

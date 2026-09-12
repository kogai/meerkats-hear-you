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
    /// この値は出力のIOが動いていることを見るので、ただ起動しているだけのものを落とせる。
    ///
    /// **落とせるのはそこまでである。** ヘッダの定義は「IOが動いていて、有効な出力ストリームが
    /// 少なくとも1本ある」であって「サンプルが出ている」ではない。**待機中の会議アプリも
    /// 1を返しうる**ので、この値だけでは会議をしているかどうかを言い当てられない。
    ///
    /// 裏を返せば、相手が黙っている間にストリームが閉じることは無い。
    /// タップがそこで外れる心配はしなくてよい。
    public var isRunningOutput: Bool

    public init(pid: Int32, bundleId: String?, name: String, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.isRunningOutput = isRunningOutput
    }
}

/// 会議アプリ1つ。
///
/// **接頭辞とアプリは1対1ではない。** Webex は製品が1つなのにバンドルIDが3系統あり、
/// 接頭辞をアプリの同一性として使うと、同じ Webex のプロセスどうしを「別の会議アプリ」として
/// 報告することになる。同一性はここで明示的に持つ。
public struct ConferencingApp: Equatable {
    /// 表示に使う名前。
    public var name: String
    /// このアプリのものとみなすバンドルIDの**前置**。
    ///
    /// 前方一致にしてあるのは補助プロセス対策である。音声が本体ではなく
    /// `us.zoom.xos.helper` のような子プロセスに出ている可能性を ADR-0008 が
    /// 未検証の前提として挙げており、完全一致だとその場合に一つも拾えない。
    public var bundleIdPrefixes: [String]

    public init(name: String, bundleIdPrefixes: [String]) {
        self.name = name
        self.bundleIdPrefixes = bundleIdPrefixes
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
    ///
    /// **1本しか録らないこと自体は決着していない。** ADR-0013 が「鳴っているアプリごとに
    /// タップを張る」を提案していて、通ればこの型は対象の一覧を返す形になる。
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
    /// **この一覧は網羅ではない。** バンドルIDを確かめられたものしか書けず、社内ツールや
    /// 地域ごとのサービスは原理的に漏れる。漏れたアプリは録られないだけで、誤って録ることは
    /// 無い。最終的には利用者が自分で足せる形が要るが、それは別の決定になる。
    ///
    /// 並びは優先順位そのもの。**仕事の会議に使われるものを先に置く。** 複数が同時に
    /// 鳴っているとき、記録したいのはそちらだからで、それ以上の根拠は無い。実機で外すようなら
    /// 並べ替えれば済む。
    public static let known: [ConferencingApp] = [
        ConferencingApp(name: "Zoom", bundleIdPrefixes: ["us.zoom.xos"]),
        // classic と new Teams (teams2) の両方に当たる。同じ製品なので畳んでよい。
        ConferencingApp(name: "Microsoft Teams", bundleIdPrefixes: ["com.microsoft.teams"]),
        // 製品は1つだがバンドルIDが3系統ある。Webex アプリは com.cisco. で**始まらない**。
        ConferencingApp(name: "Webex", bundleIdPrefixes: [
            "Cisco-Systems.Spark",
            "com.cisco.webexmeetingsapp",
            "com.webex.meetingmanager",
        ]),
        ConferencingApp(name: "Slack", bundleIdPrefixes: ["com.tinyspeck.slackmacgap"]),
        ConferencingApp(name: "Discord", bundleIdPrefixes: ["com.hnc.Discord"]),
        // 仕事の会議より後ろに置く。同時に鳴っているとき、録りたいのは仕事のほう。
        ConferencingApp(name: "FaceTime", bundleIdPrefixes: ["com.apple.FaceTime"]),
    ]

    /// 鳴っている会議アプリから、録る一つを決める。
    ///
    /// **これは選定だけを行う。** `isRunningOutput` をここで使うのは対象を選ぶためであって、
    /// いったん張ったタップをこの値で外してよいという意味ではない。外すと「相手が黙っている」と
    /// 「録れていない」が区別できなくなる(ADR-0008の未検証の前提)。継続の判断は、
    /// タップを保持する側が状態を持って行う。
    ///
    /// - Parameter processes: Core Audio が持っているプロセスの一覧。順序は問わない。
    public static func select(from processes: [AudioProcess]) -> TapSelection {
        let ranked = processes
            .filter { $0.isRunningOutput }
            .compactMap { process -> (app: Int, process: AudioProcess)? in
                guard let app = appIndex(of: process) else { return nil }
                return (app, process)
            }
            // 同じアプリのプロセスが複数あるとき、並びが起動順で揺れると
            // 録る対象が実行のたびに変わる。pid で縛って決定的にする。
            .sorted { ($0.app, $0.process.pid) < ($1.app, $1.process.pid) }

        guard let chosen = ranked.first else { return .idle }

        // **アプリごとに1つへ畳む。** 同じアプリの補助プロセスは「別の会議アプリ」ではない。
        // 畳まないと、Zoom本体とそのヘルパーが両方鳴っているだけで「他の会議アプリも
        // 鳴っています」と表示することになる。補助プロセスを拾うために前方一致にした以上、
        // ヘルパーを持つアプリでは**常に**その嘘が出る。
        var seenApps: Set<Int> = [chosen.app]
        var others: [AudioProcess] = []
        for entry in ranked.dropFirst() where !seenApps.contains(entry.app) {
            seenApps.insert(entry.app)
            others.append(entry.process)
        }

        return others.isEmpty
            ? .tap(chosen.process)
            : .tapWithOthersSounding(chosen.process, others: others)
    }

    /// このプロセスがどの会議アプリのものかを `known` での位置で返す。会議アプリでなければ nil。
    ///
    /// 照合は大文字小文字を区別する。バンドルIDは識別子であって表示名ではなく、
    /// `Cisco-Systems.Spark` のように大文字を含むものが実在する。
    static func appIndex(of process: AudioProcess) -> Int? {
        guard let bundleId = process.bundleId else { return nil }
        return known.firstIndex { app in
            app.bundleIdPrefixes.contains { bundleId.hasPrefix($0) }
        }
    }

    /// 一覧に載っている全ての接頭辞。不変条件の確認に使う。
    static var allPrefixes: [String] { known.flatMap(\.bundleIdPrefixes) }
}

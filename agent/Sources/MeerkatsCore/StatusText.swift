import Foundation

/// メニューバーに出す文字列を組み立てる(ADR-0005の常時表示)。
///
/// AppKitに触れないので、表示の中身そのものをCIで検証できる。実機でしか確かめられないのは
/// 「NSStatusItemに載せると見えるか」だけになる。
public enum StatusText {
    /// メニューバーの項目本体。幅が限られるため、記号1文字とレベルだけにする。
    public static func menuBarTitle(_ snapshot: LiveState.Snapshot) -> String {
        "\(indicator(snapshot)) \(levelText(snapshot.meanDbfs))"
    }

    /// 異常があればそれを、無ければ発話の有無を示す。
    /// 異常が複数あるときは1つに絞る。並べても幅に収まらず、読み取れない。
    public static func indicator(_ snapshot: LiveState.Snapshot) -> String {
        if let anomaly = primaryAnomaly(snapshot.activeAnomalies) {
            switch anomaly {
            case .clipping: return "!"
            case .lowLevel: return "v"
            case .dropout: return "/"
            }
        }
        return snapshot.isSpeaking ? "*" : "-"
    }

    /// 下限に張り付いている間は数値を出さない。-90.0 と表示されても情報にならず、
    /// 「測れている」と誤解させる。
    public static func levelText(_ dbfs: Double) -> String {
        guard dbfs > Levels.floorDbfs else { return "--" }
        return String(format: "%.0f", dbfs)
    }

    /// メニューを開いたときに出す説明。こちらは幅に余裕があるので日本語で書く。
    ///
    /// - Parameter stream: この LiveState が何を観測しているか。既定値を置かない。
    ///   置くと「まだマイク側しか無い」という現状が引数の陰に隠れ、受信側を繋いだときに
    ///   文言だけ取り残される。呼び出し側に毎回書かせるほうが安い。
    public static func detail(_ snapshot: LiveState.Snapshot, in stream: StreamKind) -> [String] {
        var lines: [String] = []

        // **一度も観測していないなら、そこで止める。** 続く行は「無音」「異常なし」と
        // 断定するが、それは測った結果ではない。許可が下りていない受信側と、
        // 鳴っていないだけの受信側が、同じ文字列になる。
        guard snapshot.hasObserved else { return ["まだ測れていない"] }

        if snapshot.meanDbfs > Levels.floorDbfs {
            lines.append(String(format: "レベル %.1f dBFS", snapshot.meanDbfs))
            lines.append(String(format: "ノイズフロア %.1f dBFS", snapshot.noiseFloorDbfs))
        } else {
            lines.append("入力なし")
        }

        lines.append(speechText(isSpeaking: snapshot.isSpeaking, in: stream))

        if snapshot.activeAnomalies.isEmpty {
            lines.append("異常なし")
        } else {
            for anomaly in sorted(snapshot.activeAnomalies) {
                lines.append(description(of: anomaly, in: stream))
            }
        }
        return lines
    }

    /// 音が立っているかどうか。**異常ではないがストリームで意味が変わる**。
    ///
    /// **この判定は絶対値ではない。** `SpeechDetector` は直近の背景に対してレベルが
    /// 十分に上がったかを見る。マイク側では、それが自分の発話とほぼ一致する。
    ///
    /// **受信側では一致しない。** 鳴っているのはこのMacの音すべてで、相手の声とは限らない
    /// (ADR-0013)。しかも定常的な音楽は背景そのものを押し上げるので、**鳴っていても
    /// 立ってはいない。** 「音が鳴っている」と書くと、レベルの行と同じメニューの中で矛盾する。
    public static func speechText(isSpeaking: Bool, in stream: StreamKind) -> String {
        switch (stream, isSpeaking) {
        case (.mic, true): return "発話中"
        case (.mic, false): return "無音"
        case (.output, true): return "音が立っている"
        case (.output, false): return "背景のまま"
        }
    }

    /// 同じ異常でも、どちらのストリームで起きたかで**利用者にとっての意味が変わる**(ADR-0008)。
    /// 一方の文言をもう一方に流用すると、**通知が嘘になる。**
    ///
    /// マイク側は自分の入力の話で、自分で直せる。
    ///
    /// **受信側は「聞こえ」の話である。** 限定をやめた(ADR-0013)ので、鳴っているのが
    /// 相手の声とは限らない。音楽でも通知音でも同じ判定が出る。**原因を名指ししない。**
    /// 相手の声かどうかを言い当てられるのは、ADR-0012 の突合で相手の記録と並べたあとになる。
    public static func description(of anomaly: AnomalyKind, in stream: StreamKind) -> String {
        switch (stream, anomaly) {
        case (.mic, .clipping): return "音が割れている(入力レベルが高すぎる)"
        case (.mic, .lowLevel): return "音が小さい(入力レベルが低すぎる)"
        case (.mic, .dropout): return "音が途切れている"
        case (.output, .clipping): return "聞こえている音が割れている"
        case (.output, .lowLevel): return "聞こえが小さい"
        case (.output, .dropout): return "聞こえている音が途切れている"
        }
    }

    /// どちらのストリームの行かを示す見出し。**2本並べると、どちらの話か分からなくなる。**
    /// 同じ「音が小さい」でも、マイク側は自分の入力、受信側は聞こえの話である。
    ///
    /// 呼び方は Info.plist の用途説明(「このMacで鳴っている音」)に寄せる。メニューの幅に
    /// 合わせて短くしてあるので一字一句は同じでないが、**別の呼び方はしない。**
    /// 「システム音声」などと書くと、許可を求められた画面と結びつかない。
    public static func streamLabel(_ stream: StreamKind) -> String {
        switch stream {
        case .mic: return "マイク"
        case .output: return "このMacの音"
        }
    }

    /// メニューに並べる1行。**何をどの順で出すかは表示の判断**なので、`MeerkatsCore` で決める。
    /// `MenuBarController` は受け取った列を `NSMenuItem` に載せるだけにする。
    /// AppKit を挟まないので、並びと見出しの出し分けをCIで確かめられる。
    public enum MenuLine: Equatable {
        case header(String)
        case detail(String)
        case separator
    }

    /// 観測している列からメニューの行を組み立てる。
    ///
    /// **1本のときは見出しを出さない。** 何の見出しかが自明で、行が増えるだけになる。
    /// 2本以上のときは見出しを付け、続く行を字下げして、**間にだけ**区切りを入れる。
    public static func menu(
        for streams: [(kind: StreamKind, snapshot: LiveState.Snapshot)]
    ) -> [MenuLine] {
        let labelled = streams.count > 1
        var lines: [MenuLine] = []
        for (index, stream) in streams.enumerated() {
            if labelled { lines.append(.header(streamLabel(stream.kind))) }
            for line in detail(stream.snapshot, in: stream.kind) {
                lines.append(.detail(labelled ? "  " + line : line))
            }
            if index < streams.count - 1 { lines.append(.separator) }
        }
        return lines
    }

    /// 通知の本文。何が起きているかと、次に何を見ればよいかを1行ずつ。
    public static func notificationBody(for anomaly: AnomalyKind, in stream: StreamKind) -> String {
        description(of: anomaly, in: stream)
    }

    /// 原因がはっきりしているものを先に出す。
    /// 表示と通知で優先順位が食い違うと、利用者が混乱する。
    static let priority: [AnomalyKind] = [.clipping, .dropout, .lowLevel]

    static func primaryAnomaly(_ anomalies: Set<AnomalyKind>) -> AnomalyKind? {
        priority.first { anomalies.contains($0) }
    }

    static func sorted(_ anomalies: Set<AnomalyKind>) -> [AnomalyKind] {
        priority.filter { anomalies.contains($0) }
    }
}

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
    public static func detail(_ snapshot: LiveState.Snapshot) -> [String] {
        var lines: [String] = []

        if snapshot.meanDbfs > Levels.floorDbfs {
            lines.append(String(format: "レベル %.1f dBFS", snapshot.meanDbfs))
            lines.append(String(format: "ノイズフロア %.1f dBFS", snapshot.noiseFloorDbfs))
        } else {
            lines.append("入力なし")
        }

        lines.append(snapshot.isSpeaking ? "発話中" : "無音")

        if snapshot.activeAnomalies.isEmpty {
            lines.append("異常なし")
        } else {
            for anomaly in sorted(snapshot.activeAnomalies) {
                // LiveStateが持つ異常は、いまのところマイク側のものだけ。
                // 受信側のストリームが入った時点で、種別ごとに分ける。
                lines.append(description(of: anomaly, in: .mic))
            }
        }
        return lines
    }

    /// 同じ異常でも、どちらのストリームで起きたかで**利用者にとっての意味が変わる**(ADR-0008)。
    /// マイク側は自分で直せる話、受信側は相手に伝えるか、こちらでは手が無いかになる。
    /// 一方の文言をもう一方に流用すると、**通知が嘘になる。**
    public static func description(of anomaly: AnomalyKind, in stream: StreamKind) -> String {
        switch (stream, anomaly) {
        case (.mic, .clipping): return "音が割れている(入力レベルが高すぎる)"
        case (.mic, .lowLevel): return "音が小さい(相手に届きにくい可能性)"
        case (.mic, .dropout): return "音が途切れている"
        case (.output, .clipping): return "相手の音が割れている(相手側の問題)"
        case (.output, .lowLevel): return "相手の声が小さい(相手に伝えるとよい)"
        case (.output, .dropout): return "相手の音が途切れている"
        }
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

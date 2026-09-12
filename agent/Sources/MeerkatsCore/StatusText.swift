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
                lines.append(description(of: anomaly))
            }
        }
        return lines
    }

    public static func description(of anomaly: AnomalyKind) -> String {
        switch anomaly {
        case .clipping: return "音が割れている(入力レベルが高すぎる)"
        case .lowLevel: return "音が小さい(相手に届きにくい可能性)"
        case .dropout: return "音が途切れている"
        }
    }

    /// 通知の本文。何が起きているかと、次に何を見ればよいかを1行ずつ。
    public static func notificationBody(for anomaly: AnomalyKind) -> String {
        description(of: anomaly)
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

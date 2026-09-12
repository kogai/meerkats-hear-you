import Foundation
import MeerkatsCore
import UserNotifications

/// 異常を検知したときの通知(ADR-0005)。
///
/// この要件が問題になる場面で、利用者が見ているのは会議アプリであってメニューバーではない。
/// 常時表示は受動的で見落としうるため、「気づける」を実際に満たすのはこちらになる。
public enum AnomalyNotifier {
    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert]) { granted, _ in
                    continuation.resume(returning: granted)
                }
        }
    }

    public static func notify(_ anomaly: AnomalyKind, in stream: StreamKind) {
        let content = UNMutableNotificationContent()
        content.title = "音声の状態"
        content.body = StatusText.notificationBody(for: anomaly, in: stream)

        // トリガーがすでに保守的なので、ここでさらに抑制はしない。
        // 抑制を二重にかけると、どちらが効いて鳴らなかったのかが分からなくなる。
        let request = UNNotificationRequest(
            identifier: "anomaly.\(stream.rawValue).\(anomaly.rawValue).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

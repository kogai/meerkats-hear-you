import AppKit

/// エージェント本体。ADR-0005のとおり、キャプチャ・記録・表示を単一のプロセスに置く。
///
/// いまはまだ何もしない。バンドルを組んで署名し、常駐として起動するところまでを先に通す。
/// マイクの取り込み・常時表示・通知・記録の閲覧は、ここに順に載せていく。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {}
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Info.plist の LSUIElement と揃える。Dockアイコンを持たない常駐にする。
app.setActivationPolicy(.accessory)
app.run()

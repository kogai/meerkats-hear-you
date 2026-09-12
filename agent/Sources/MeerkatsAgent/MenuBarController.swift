import AppKit
import Foundation
import MeerkatsCore

/// メニューバーの常時表示(ADR-0005)。
///
/// 表示の中身は StatusText が組み立てる。ここは AppKit に載せるだけで、判断を持たない。
public final class MenuBarController {
    private let statusItem: NSStatusItem
    private let liveState: LiveState
    private var timer: Timer?
    private let refreshInterval: TimeInterval

    /// - Parameter refreshInterval: 表示の更新間隔。終日動き続けるので控えめにする。
    ///   ADR-0004で書き込み頻度を電力の観点で絞ったが、常時表示はそこに別の消費を足す。
    public init(liveState: LiveState, refreshInterval: TimeInterval = 1.0) {
        self.liveState = liveState
        self.refreshInterval = refreshInterval
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    public func start() {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.menu = NSMenu()
        refresh()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // メニューを開いている間も更新を止めない。止まると「固まった」ように見える。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// メニューから開く分析ウインドウの起動口。
    public var onOpenAnalysis: (() -> Void)?
    public var onQuit: (() -> Void)?

    private func refresh() {
        let snapshot = liveState.snapshot()
        statusItem.button?.title = StatusText.menuBarTitle(snapshot)
        rebuildMenu(snapshot)
    }

    private func rebuildMenu(_ snapshot: LiveState.Snapshot) {
        let menu = NSMenu()
        for line in StatusText.detail(snapshot) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let analysis = NSMenuItem(
            title: "記録を見る…", action: #selector(openAnalysis), keyEquivalent: ""
        )
        analysis.target = self
        menu.addItem(analysis)

        let quit = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openAnalysis() { onOpenAnalysis?() }
    @objc private func quit() { onQuit?() }
}

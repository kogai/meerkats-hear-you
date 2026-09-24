import AppKit
import Foundation
import MeerkatsCore

/// メニューバーの常時表示(ADR-0005)。
///
/// 表示の中身は StatusText が組み立てる。ここは AppKit に載せるだけで、判断を持たない。
public final class MenuBarController {
    /// 観測している1本。**種別を値に持たせる。** 文言がこれで変わるので、
    /// 2本を素の `LiveState` の配列で持つと、どちらの文言か決められなくなる。
    public struct Stream {
        public let liveState: LiveState
        public let kind: StreamKind

        public init(liveState: LiveState, kind: StreamKind) {
            self.liveState = liveState
            self.kind = kind
        }
    }

    private let statusItem: NSStatusItem
    private let streams: [Stream]
    private var timer: Timer?
    private let refreshInterval: TimeInterval

    /// - Parameter streams: 表示するストリーム。**先頭のものが題になる**(下記 `refresh`)。
    /// - Parameter refreshInterval: 表示の更新間隔。終日動き続けるので控えめにする。
    ///   ADR-0004で書き込み頻度を電力の観点で絞ったが、常時表示はそこに別の消費を足す。
    public init(streams: [Stream], refreshInterval: TimeInterval = 1.0) {
        self.streams = streams
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
        let readings = streams.map { (kind: $0.kind, snapshot: $0.liveState.snapshot()) }
        // **題に出すのは先頭の1本だけ。** メニューバーの幅は限られていて、2本ぶんの
        // 記号とレベルを並べると読み取れない。受信側に異常が出たときは、通知
        // (`AnomalyNotifier`)とメニューの中に出る。
        if let first = readings.first {
            statusItem.button?.title = StatusText.menuBarTitle(first.snapshot)
        }
        rebuildMenu(readings)
    }

    private func rebuildMenu(_ readings: [(kind: StreamKind, snapshot: LiveState.Snapshot)]) {
        let menu = NSMenu()
        let labelled = readings.count > 1
        for (index, reading) in readings.enumerated() {
            // **1本のときは見出しを出さない。** 何の見出しかが自明で、行が増えるだけになる。
            if labelled {
                let header = NSMenuItem(
                    title: StatusText.streamLabel(reading.kind), action: nil, keyEquivalent: ""
                )
                header.isEnabled = false
                menu.addItem(header)
            }
            for line in StatusText.detail(reading.snapshot, in: reading.kind) {
                let item = NSMenuItem(
                    title: labelled ? "  " + line : line, action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
            if index < readings.count - 1 { menu.addItem(.separator()) }
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

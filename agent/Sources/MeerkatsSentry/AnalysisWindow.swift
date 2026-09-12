import AppKit
import Foundation
import MeerkatsCore
import SwiftUI

/// 記録を振り返るためのウインドウ(ADR-0005)。
///
/// 常時表示がメモリから読むのに対し、こちらはSQLiteを読む。過去を見るための画面なので、
/// まとめ書きによる数秒の遅れは問題にならない。
public final class AnalysisWindowController {
    private var window: NSWindow?
    private let store: RecordingStore
    private let streamId: Int64
    private let streamKind: StreamKind
    private let frameDurationUs: Int64

    public init(
        store: RecordingStore, streamId: Int64, streamKind: StreamKind, frameDurationUs: Int64
    ) {
        self.store = store
        self.streamId = streamId
        self.streamKind = streamKind
        self.frameDurationUs = frameDurationUs
    }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AnalysisView(
            streamKind: streamKind,
            load: { [store, streamId] in
                (try? store.seconds(streamId: streamId)) ?? []
            },
            loadDetails: { [store, streamId, frameDurationUs] in
                (try? store.detailWindows(
                    streamId: streamId, frameDurationUs: frameDurationUs
                )) ?? []
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "音声レベルの記録"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct AnalysisView: View {
    let streamKind: StreamKind
    let load: () -> [SecondRecord]
    let loadDetails: () -> [DetailWindow]

    @State private var records: [SecondRecord] = []
    @State private var details: [DetailWindow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LevelChart(records: records)
                .frame(minHeight: 160)
            detailList
        }
        .padding(16)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack {
            Text("\(records.count) 秒ぶんの記録")
                .font(.headline)
            Spacer()
            Button("再読み込み", action: reload)
        }
    }

    @ViewBuilder
    private var detailList: some View {
        if details.isEmpty {
            Text("異常として記録された区間はありません")
                .foregroundStyle(.secondary)
        } else {
            Text("異常として残した区間")
                .font(.headline)
            List(Array(details.enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: window.trigger))
                    Text(
                        "\(window.startUs / 1_000_000) 秒付近 / \(window.frames.count) フレーム"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(for trigger: String) -> String {
        guard let kind = AnomalyKind(rawValue: trigger) else { return trigger }
        return StatusText.description(of: kind, in: streamKind)
    }

    private func reload() {
        records = load()
        details = loadDetails()
    }
}

/// レベルの推移。平均だけでなく最小も描くのは、1秒の中の落ち込みが平均に
/// 埋もれるのを画面上でも避けるため。
struct LevelChart: View {
    let records: [SecondRecord]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                path(for: \.minDbfs, in: geometry.size)
                    .stroke(.orange.opacity(0.6), lineWidth: 1)
                path(for: \.meanDbfs, in: geometry.size)
                    .stroke(.blue, lineWidth: 1.5)
            }
            .background(Color.primary.opacity(0.04))
        }
    }

    private func path(
        for keyPath: KeyPath<SecondRecord, Double>, in size: CGSize
    ) -> Path {
        Path { path in
            guard records.count > 1 else { return }
            let stepX = size.width / CGFloat(records.count - 1)

            for (index, record) in records.enumerated() {
                let normalized = (record[keyPath: keyPath] - Levels.floorDbfs)
                    / (0 - Levels.floorDbfs)
                let y = size.height * (1 - CGFloat(max(0, min(1, normalized))))
                let point = CGPoint(x: CGFloat(index) * stepX, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }
}

import AppKit
import Foundation
import MeerkatsCore
import SwiftUI

/// 記録を振り返るためのウインドウ(ADR-0005)。
///
/// 常時表示がメモリから読むのに対し、こちらはSQLiteを読む。過去を見るための画面なので、
/// まとめ書きによる数秒の遅れは問題にならない。
public final class AnalysisWindowController {
    /// 表示するストリーム。**種別を持たせる。** 文言も色もこれで決まる。
    public struct Stream {
        public let id: Int64
        public let kind: StreamKind

        public init(id: Int64, kind: StreamKind) {
            self.id = id
            self.kind = kind
        }
    }

    private var window: NSWindow?
    private let store: RecordingStore
    private let streams: [Stream]
    private let frameDurationUs: Int64

    public init(store: RecordingStore, streams: [Stream], frameDurationUs: Int64) {
        self.store = store
        self.streams = streams
        self.frameDurationUs = frameDurationUs
    }

    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AnalysisView(
            streams: streams.map { stream in
                AnalysisView.Series(
                    kind: stream.kind,
                    load: { [store] in (try? store.seconds(streamId: stream.id)) ?? [] },
                    loadDetails: { [store, frameDurationUs] in
                        (try? store.detailWindows(
                            streamId: stream.id, frameDurationUs: frameDurationUs
                        )) ?? []
                    }
                )
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
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
    struct Series: Identifiable {
        let kind: StreamKind
        let load: () -> [SecondRecord]
        let loadDetails: () -> [DetailWindow]

        var id: String { kind.rawValue }
        var color: Color { kind == .mic ? .blue : .orange }
    }

    let streams: [Series]

    @State private var records: [String: [SecondRecord]] = [:]
    @State private var details: [String: [DetailWindow]] = [:]

    /// **まとめ書きは10秒ごと**(`RecordingPipeline.Configuration.flushIntervalSeconds`)。
    /// それより細かく読んでも新しい行は出ない。
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            legend
            chart
            detailList
        }
        .padding(16)
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(streams) { series in
                HStack(spacing: 6) {
                    Rectangle().fill(series.color).frame(width: 14, height: 3)
                    Text(StatusText.streamLabel(series.kind))
                    Text(latestText(for: series))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Text("薄い線は同じ1秒の最小")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        LevelChart(series: streams.map { ($0.color, records[$0.id] ?? []) })
            .frame(minHeight: 200)
    }

    @ViewBuilder
    private var detailList: some View {
        let rows = streams.flatMap { series in
            (details[series.id] ?? []).map { (series, $0) }
        }
        if rows.isEmpty {
            Text("異常として記録された区間はありません")
                .foregroundStyle(.secondary)
        } else {
            Text("異常として残した区間").font(.headline)
            List(Array(rows.enumerated()), id: \.offset) { _, row in
                let (series, window) = row
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(StatusText.streamLabel(series.kind)): \(label(for: window.trigger, in: series.kind))")
                    Text("\(window.startUs / 1_000_000) 秒付近 / \(window.frames.count) フレーム")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func latestText(for series: Series) -> String {
        guard let last = records[series.id]?.last else { return "記録なし" }
        guard last.meanDbfs > Levels.floorDbfs else { return "入力なし" }
        return String(format: "%.1f dBFS", last.meanDbfs)
    }

    private func label(for trigger: String, in kind: StreamKind) -> String {
        guard let anomaly = AnomalyKind(rawValue: trigger) else { return trigger }
        return StatusText.description(of: anomaly, in: kind)
    }

    private func reload() {
        for series in streams {
            records[series.id] = series.load()
            details[series.id] = series.loadDetails()
        }
    }
}

/// レベルの推移。**濃い線が平均、薄い線が同じ1秒の最小。** 最小を別に描くのは、
/// 1秒の中の落ち込みが平均に埋もれるのを画面上でも避けるため。
struct LevelChart: View {
    let series: [(color: Color, records: [SecondRecord])]

    /// 目盛り。下端は `Levels.floorDbfs`。
    private let marks: [Double] = [0, -30, -60, -90]

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing) {
                ForEach(marks, id: \.self) { mark in
                    Text("\(Int(mark))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if mark != marks.last { Spacer() }
                }
            }
            GeometryReader { geometry in
                ZStack {
                    ForEach(marks, id: \.self) { mark in
                        Path { path in
                            let y = geometry.size.height * CGFloat(1 - normalized(mark))
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    }
                    ForEach(Array(series.enumerated()), id: \.offset) { _, entry in
                        path(for: \.minDbfs, records: entry.records, in: geometry.size)
                            .stroke(entry.color.opacity(0.35), lineWidth: 1)
                        path(for: \.meanDbfs, records: entry.records, in: geometry.size)
                            .stroke(entry.color, lineWidth: 1.5)
                    }
                }
                .background(Color.primary.opacity(0.04))
            }
        }
    }

    private func normalized(_ dbfs: Double) -> CGFloat {
        CGFloat(max(0, min(1, (dbfs - Levels.floorDbfs) / (0 - Levels.floorDbfs))))
    }

    private func path(
        for keyPath: KeyPath<SecondRecord, Double>, records: [SecondRecord], in size: CGSize
    ) -> Path {
        Path { path in
            guard records.count > 1 else { return }
            let stepX = size.width / CGFloat(records.count - 1)
            for (index, record) in records.enumerated() {
                let y = size.height * (1 - normalized(record[keyPath: keyPath]))
                let point = CGPoint(x: CGFloat(index) * stepX, y: y)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

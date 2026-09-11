// ADR-0001 / ADR-0005 の未検証部分を確かめるためのスパイク。
//
// 確かめたいこと:
//   1. Xcodeを使わず SPM + codesign で組んだ .app が、自分自身の名前でマイク権限を取れるか
//   2. その権限がリビルドをまたいで維持されるか(ad-hoc署名だと同一性が変わるため)
//   3. UIを持たない(LSUIElement)常駐プロセスとして実際に音声を取れるか
//
// 実行結果は ~/Library/Application Support/LevelSpike/report-<epoch>.json に書く。
// `open` で起動されると標準出力が拾えないため、ファイルに残す必要がある。

import AVFoundation
import Foundation

let captureSeconds = 3.0

func authStatusName(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
}

func dbfs(_ rms: Float) -> Double {
    rms <= 0 ? -90.0 : max(20.0 * log10(Double(rms)), -90.0)
}

/// dB値の単純平均は物理的に誤りなので、パワー領域で平均してからdB化する。
func powerMeanDbfs(_ levels: [Double]) -> Double? {
    guard !levels.isEmpty else { return nil }
    let mean = levels.map { pow(10.0, $0 / 10.0) }.reduce(0, +) / Double(levels.count)
    return 10.0 * log10(mean + 1e-300)
}

func reportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("LevelSpike", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

final class LevelCapture {
    private let engine = AVAudioEngine()
    private var levels: [Double] = []
    private let lock = NSLock()

    /// マイクからフレームごとのdBFSを集める。生のPCMは保持しない。
    func run(seconds: Double) throws -> (levels: [Double], sampleRate: Double, channels: UInt32) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw NSError(domain: "LevelSpike", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "入力フォーマットが不正(channels=\(format.channelCount), rate=\(format.sampleRate))。"
                    + "権限が無いか、入力デバイスが無い可能性がある。"
            ])
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            let channel = data[0]
            var sum: Float = 0
            for i in 0..<n {
                let v = channel[i]
                sum += v * v
            }
            let rms = (sum / Float(n)).squareRoot()
            self.lock.lock()
            self.levels.append(dbfs(rms))
            self.lock.unlock()
        }

        try engine.start()
        Thread.sleep(forTimeInterval: seconds)
        engine.stop()
        input.removeTap(onBus: 0)

        lock.lock()
        let collected = levels
        lock.unlock()
        return (collected, format.sampleRate, format.channelCount)
    }
}

func runSpike() -> [String: Any] {
    var report: [String: Any] = [
        "timestamp": Int(Date().timeIntervalSince1970),
        "bundle_identifier": Bundle.main.bundleIdentifier ?? "(なし: バンドルとして起動されていない)",
        "bundle_path": Bundle.main.bundlePath,
        "is_ui_element": Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false,
    ]

    // 許可を求める前の状態。2回目以降の実行でこれが authorized なら、
    // リビルドをまたいで権限が維持されたということになる。
    let before = AVCaptureDevice.authorizationStatus(for: .audio)
    report["authorization_status_before"] = authStatusName(before)
    report["prompted"] = (before == .notDetermined)

    if before == .notDetermined {
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 120)
    }

    let after = AVCaptureDevice.authorizationStatus(for: .audio)
    report["authorization_status_after"] = authStatusName(after)

    if let device = AVCaptureDevice.default(for: .audio) {
        report["input_device"] = device.localizedName
    }

    guard after == .authorized else {
        report["capture"] = ["ok": false, "reason": "権限が無いためキャプチャしていない"]
        return report
    }

    do {
        // 一時オブジェクトのまま run() を呼ぶと、タップ内の weak self が即座にnilになり
        // レベルが1フレームも集まらない。強参照で保持しておく必要がある。
        let capture = LevelCapture()
        let result = try capture.run(seconds: captureSeconds)
        let levels = result.levels
        // 全フレームがフロア値なら、権限はあるが実際には無音しか来ていない状態。
        let allAtFloor = !levels.isEmpty && levels.allSatisfy { $0 <= -89.999 }
        var capture: [String: Any] = [
            "ok": true,
            "sample_rate": result.sampleRate,
            "channels": Int(result.channels),
            "frame_count": levels.count,
            "signal_present": !levels.isEmpty && !allAtFloor,
        ]
        if let mean = powerMeanDbfs(levels) { capture["mean_dbfs"] = mean }
        if let maxLevel = levels.max() { capture["max_dbfs"] = maxLevel }
        if let minLevel = levels.min() { capture["min_dbfs"] = minLevel }
        report["capture"] = capture
    } catch {
        report["capture"] = ["ok": false, "reason": error.localizedDescription]
    }

    return report
}

func writeReport(_ report: [String: Any]) {
    let stamp = Int(Date().timeIntervalSince1970)
    let url = reportDirectory().appendingPathComponent("report-\(stamp).json")
    guard let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
    try? data.write(to: url)
}

DispatchQueue.global(qos: .userInitiated).async {
    writeReport(runSpike())
    exit(0)
}

RunLoop.main.run()

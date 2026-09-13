import AVFoundation
import Darwin
import Foundation

// ADR-0015 の「確かめること」を潰すためのスパイク。
//
// ADR-0015 は、途切れたと分かっている事象でだけ基準を打ち直すと決めた。だが**エンジンが
// 走ったまま過負荷でバッファが飛んだ場合、こちらの知っている事象は何も起きない。**
// それを拾える見込みがあるのは、音声層が報告するサンプル時刻の不連続だけである。
//
// 確かめたいのは3つ。
//
// 1. `AVAudioTime` からサンプル時刻が取れるか。取れるとして、連続しているか
// 2. バッファを落としたとき、サンプル時刻の飛びとして現れるか
// 3. ホストタイムが `mach_absolute_time` と `mach_continuous_time` のどちらの基数か
//
// 3つ目が要るのは、ADR-0003 が連続単調時計を指定しているため。ホストタイムが中断側の
// 基数なら、連続側へ移す手当てが要る。
//
// **ここで見るのはマイク側だけである。** 受信側(Core Audio のプロセスタップ)は
// 組み立てが長く、ここに写すと確かめたいことより写し間違いのほうが多くなる。
// 1〜3 が取れると分かってから、同じ形で受信側に足す。

/// 1バッファぶんの観測。
struct Sample {
    let index: Int
    let sampleTime: AVAudioFramePosition
    let frameLength: AVAudioFrameCount
    let hostTime: UInt64
    /// バッファを受け取った瞬間に読んだ `mach_absolute_time()`。
    let arrivalAbsolute: UInt64
    /// 同じ瞬間に読んだ `mach_continuous_time()`。
    let arrivalContinuous: UInt64
    let sampleTimeValid: Bool
    let hostTimeValid: Bool
}

/// ホストタイムの刻みをミリ秒に直す。差を見るので符号つきで扱う。
let timebase: (numer: Double, denom: Double) = {
    var info = mach_timebase_info_data_t()
    _ = mach_timebase_info(&info)
    return (Double(info.numer), Double(info.denom))
}()

func millis(ticks: Double) -> Double {
    ticks * timebase.numer / timebase.denom / 1_000_000
}

// MARK: - 収集

let engine = AVAudioEngine()
let input = engine.inputNode
let format = input.outputFormat(forBus: 0)

let lock = NSLock()
var samples: [Sample] = []
var index = 0

/// **わざと詰まらせるバッファ番号。** ここで寝てIOを溢れさせ、落ちたぶんが
/// サンプル時刻の飛びとして現れるかを見る。
let stallAt = 50
let stallSeconds = 0.8

print("入力フォーマット: \(format.sampleRate) Hz, \(format.channelCount) ch")
print("15秒ぶん集めます。\(stallAt) 番目のバッファで \(stallSeconds) 秒わざと詰まらせます。")
print("マイクの許可を求められたら許可してください。")
print("")

input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    // **最初に時刻を読む。** あとで読むと、この閉包の中の処理時間が混ざる。
    let absolute = mach_absolute_time()
    let continuous = mach_continuous_time()

    lock.lock()
    let current = index
    index += 1
    samples.append(
        Sample(
            index: current,
            sampleTime: time.sampleTime,
            frameLength: buffer.frameLength,
            hostTime: time.hostTime,
            arrivalAbsolute: absolute,
            arrivalContinuous: continuous,
            sampleTimeValid: time.isSampleTimeValid,
            hostTimeValid: time.isHostTimeValid
        )
    )
    lock.unlock()

    if current == stallAt {
        Thread.sleep(forTimeInterval: stallSeconds)
    }
}

do {
    try engine.start()
} catch {
    print("エンジンを開始できませんでした: \(error)")
    exit(1)
}

Thread.sleep(forTimeInterval: 15)
engine.stop()
input.removeTap(onBus: 0)

lock.lock()
let collected = samples
lock.unlock()

// MARK: - 報告

guard collected.count >= 2 else {
    print("バッファが足りません(\(collected.count) 個)。入力デバイスを確認してください。")
    exit(1)
}

print("=== 1. サンプル時刻は取れるか ===")
let allSampleTimeValid = collected.allSatisfy { $0.sampleTimeValid }
let allHostTimeValid = collected.allSatisfy { $0.hostTimeValid }
let lengths = Set(collected.map { $0.frameLength }).sorted().map { "\($0)" }
print("isSampleTimeValid: \(allSampleTimeValid ? "全バッファで true" : "false が混ざる")")
print("isHostTimeValid:   \(allHostTimeValid ? "全バッファで true" : "false が混ざる")")
print("バッファ数: \(collected.count)、frameLength: \(lengths.joined(separator: ", "))")

print("")
print("=== 2. 落ちたバッファは飛びとして現れるか ===")
// 期待するサンプル時刻は、直前の値に直前の長さを足したもの。
// 差がそれを超えていれば、その差ぶんのサンプルが落ちている。
var jumps: [(index: Int, missing: Int, seconds: Double)] = []
for pair in zip(collected, collected.dropFirst()) {
    let expected = pair.0.sampleTime + AVAudioFramePosition(pair.0.frameLength)
    let missing = Int(pair.1.sampleTime - expected)
    if missing != 0 {
        jumps.append((pair.1.index, missing, Double(missing) / format.sampleRate))
    }
}

if jumps.isEmpty {
    print("飛びなし。**わざと詰まらせたのに飛ばないなら、この手では取りこぼしを拾えない。**")
} else {
    for jump in jumps {
        let mark = jump.index == stallAt + 1 ? "  ← わざと詰まらせた直後" : ""
        let seconds = String(format: "%+.3f", jump.seconds)
        print("バッファ \(jump.index): \(jump.missing) サンプル (\(seconds) 秒)\(mark)")
    }
    let atStall = jumps.contains { $0.index == stallAt + 1 }
    print("")
    print(atStall
        ? "詰まらせた箇所が飛びとして出ている。**この手で取りこぼしを拾える。**"
        : "詰まらせた箇所には出ていない。別の場所の飛びは、それ自体が調べる対象。")
}

print("")
print("=== 3. ホストタイムはどちらの基数か ===")
// ホストタイムが `mach_absolute_time` の基数なら、到着時に読んだ絶対時刻との差は
// 1バッファぶん程度の小さな値になる。連続時刻との差は、起動以降のスリープぶんだけ開く。
let last = collected[collected.count - 1]
let vsAbsolute = millis(ticks: Double(last.arrivalAbsolute) - Double(last.hostTime))
let vsContinuous = millis(ticks: Double(last.arrivalContinuous) - Double(last.hostTime))
print("到着時の mach_absolute_time   - hostTime = \(String(format: "%+.3f", vsAbsolute)) ms")
print("到着時の mach_continuous_time - hostTime = \(String(format: "%+.3f", vsContinuous)) ms")
print("")
print("絶対時刻との差が小さく、連続時刻との差が大きければ、ホストタイムは**中断側**である。")
print("その場合、ADR-0003 の連続単調時計へ移すには、到着ごとに両方を読んで差を取る必要がある。")
print("")
print("**一度もスリープしていない機械では、どちらの差も同じに見える。**")
print("蓋を閉じて開けてから走らせると差が出る。差が出ない場合は、")
print("スリープを挟んでもう一度走らせること。")

print("")
print("=== 生の観測(先頭5件と、飛びの前後) ===")
var shown = Set(collected.prefix(5).map { $0.index })
for jump in jumps {
    shown.formUnion([jump.index - 1, jump.index])
}
for sample in collected where shown.contains(sample.index) {
    print("  \(sample.index)  sampleTime=\(sample.sampleTime)"
        + "  frames=\(sample.frameLength)  hostTime=\(sample.hostTime)")
}

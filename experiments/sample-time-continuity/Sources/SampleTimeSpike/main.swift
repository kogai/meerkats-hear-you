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

/// 詰まらせの進行。タップ側で更新し、報告時は `lock` の下で写す。
var stallCursor = 0
var firstArrivalContinuous: UInt64 = 0
var stallLog: [(position: Int, planned: Double, seconds: Double)] = []

/// **わざと詰まらせる予定。** (最初のバッファからの経過秒, 寝る秒数)。
///
/// 1回・0.8秒では**何も落ちなかった**(2026-09-24 の実測: 149バッファ = 14.900秒、
/// 窓は15秒、飛びゼロ)。タップの閉包を塞いでも、その間のバッファは溜められて
/// 後から届く。0.8秒では溜めきれる。落ちるところまで持っていかないと、
/// 「落ちたものが飛びとして現れるか」は確かめられない。
///
/// **バッファ番号ではなく経過で撃つ。** 番号で撃つと、詰まらせた直後の追いつきで
/// 番号が一気に進み、次の詰まらせがすぐ撃たれる。
let stalls: [(at: Double, seconds: Double)] = [(3.0, 1.0), (9.0, 4.0), (18.0, 12.0)]
let captureSeconds = 40.0

print("入力フォーマット: \(format.sampleRate) Hz, \(format.channelCount) ch")
print("\(Int(captureSeconds))秒ぶん集めます。途中で "
    + stalls.map { "\(Int($0.at))秒の地点で\($0.seconds)秒" }.joined(separator: "、")
    + " 詰まらせます。")
print("マイクの許可を求められたら許可してください。")
print("")

input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
    // **最初に時刻を読む。** あとで読むと、この閉包の中の処理時間が混ざる。
    let absolute = mach_absolute_time()
    let continuous = mach_continuous_time()
    var plannedStallSeconds: Double?

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
    if firstArrivalContinuous == 0 { firstArrivalContinuous = continuous }
    if stallCursor < stalls.count {
        let elapsed = millis(ticks: Double(continuous) - Double(firstArrivalContinuous)) / 1000
        if elapsed >= stalls[stallCursor].at {
            let stall = stalls[stallCursor]
            stallCursor += 1
            stallLog.append((position: current, planned: stall.at, seconds: stall.seconds))
            plannedStallSeconds = stall.seconds
        }
    }
    lock.unlock()

    // 詰まらせは閉包の中で寝る。**実装でもこの閉包が記録を書いている**ので、
    // ここが詰まることが、そのまま過負荷の形になる。
    if let plannedStallSeconds {
        Thread.sleep(forTimeInterval: plannedStallSeconds)
    }
}

do {
    try engine.start()
} catch {
    print("エンジンを開始できませんでした: \(error)")
    exit(1)
}

Thread.sleep(forTimeInterval: captureSeconds)
engine.stop()
input.removeTap(onBus: 0)

lock.lock()
let collected = samples
let recordedStalls = stallLog
lock.unlock()

// MARK: - 報告

guard collected.count >= 2 else {
    print("バッファが足りません(\(collected.count) 個)。入力デバイスを確認してください。")
    exit(1)
}

let last = collected[collected.count - 1]

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
var jumps: [(position: Int, missing: Int, seconds: Double)] = []
for (position, pair) in zip(collected, collected.dropFirst()).enumerated() {
    let expected = pair.0.sampleTime + AVAudioFramePosition(pair.0.frameLength)
    let missing = Int(pair.1.sampleTime - expected)
    if missing != 0 {
        jumps.append((position + 1, missing, Double(missing) / format.sampleRate))
    }
}

// **取りこぼしの有無を、飛びとは別に数える。** これが無いと「落ちていない」と
// 「落ちたのに飛びとして出ていない」を区別できない。**前の版はここを数えておらず、
// 何も落ちなかった回を「この手では拾えない」と読んでいた。**
//
// 受け取った音声の長さと、到着から見た窓の長さを突き合わせる。窓のほうが長ければ、
// その差は届かなかった音である。飛びとして出ているぶんを引いた残りが、
// **どこにも現れていない取りこぼし**になる。
let first = collected[0]
let received = collected.reduce(0) { $0 + Int($1.frameLength) }
let span = Int(last.sampleTime + AVAudioFramePosition(last.frameLength) - first.sampleTime)
let jumped = span - received
let arrivalSeconds =
    millis(ticks: Double(last.arrivalContinuous) - Double(first.arrivalContinuous)) / 1000
// 最初のバッファは、到着した時点で既に1つぶん埋まっている。窓はその1つぶん広い。
let windowSeconds = arrivalSeconds + Double(first.frameLength) / format.sampleRate
let unaccounted = windowSeconds - Double(span) / format.sampleRate

func seconds(_ samples: Int) -> String {
    String(format: "%.3f", Double(samples) / format.sampleRate)
}

print("受け取った音声:       \(seconds(received)) 秒 (\(collected.count) バッファ)")
print("サンプル時刻の張る幅: \(seconds(span)) 秒")
print("  うち飛び:           \(seconds(jumped)) 秒 (\(jumped) サンプル)")
print("到着から見た窓:       \(String(format: "%.3f", windowSeconds)) 秒")
print("勘定の合わない差:     \(String(format: "%+.3f", unaccounted)) 秒")
print("")

for entry in recordedStalls {
    let missing = jumps.first { $0.position == entry.position + 1 }?.missing ?? 0
    // 追いつきの束。溜めて後から届いたなら、直後のバッファが立て続けに来る。
    var burst = 0
    var k = entry.position + 1
    while k + 1 < collected.count {
        let delta = millis(
            ticks: Double(collected[k + 1].arrivalContinuous)
                - Double(collected[k].arrivalContinuous))
        if delta > 20 { break }
        burst += 1
        k += 1
    }
    let verdict: String
    if missing != 0 {
        verdict = "飛び \(missing) サンプル (\(seconds(missing)) 秒) ← 拾える"
    } else if burst >= 2 {
        verdict = "飛びなし。直後に \(burst) バッファが立て続けに届いた ← 溜めただけで落ちていない"
    } else {
        verdict = "飛びなし。追いつきの束も無い"
    }
    print("  \(Int(entry.planned))秒の地点 (バッファ \(entry.position)) で \(entry.seconds) 秒: \(verdict)")
}
print("")

// **3つに分ける。** 前の版は上2つを1つにまとめていた。
let silentLossThreshold = 2.5 * Double(first.frameLength) / format.sampleRate
let lostSilently = unaccounted > silentLossThreshold  // バッファ2.5個ぶん。端数を拾わない幅にする
if jumped != 0 {
    print("**落ちたぶんがサンプル時刻の飛びとして出ている。この手で取りこぼしを拾える。**")
    print("ADR-0015 に `RecordingGap.Reason` を1つ足して実装に入れる。")
} else if lostSilently {
    print("**落ちているのに飛びとして出ていない**(勘定の合わない差が \(String(format: "%.3f", unaccounted)) 秒)。")
    print("この手では未知の取りこぼしを拾えない。**ADR-0015 を書き換える。**")
} else {
    print("**そもそも落ちていない。** 詰まらせたぶんは溜められて後から届いている。")
    print("この回は「飛びとして現れるか」を確かめていない。詰まらせをさらに長くする必要がある。")
}

print("")
print("=== 3. ホストタイムはどちらの基数か ===")
// ホストタイムが `mach_absolute_time` の基数なら、到着時に読んだ絶対時刻との差は
// 1バッファぶん程度の小さな値になる。連続時刻との差は、起動以降のスリープぶんだけ開く。
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
    shown.formUnion([jump.position - 1, jump.position])
}
// 詰まらせた境目は、飛びが無くても見せる。**無かったことも読み取れるようにする。**
for entry in stallLog {
    shown.formUnion([entry.position, entry.position + 1])
}
for sample in collected where shown.contains(sample.index) {
    print("  \(sample.index)  sampleTime=\(sample.sampleTime)"
        + "  frames=\(sample.frameLength)  hostTime=\(sample.hostTime)")
}

import Foundation

/// 音声レベルの算出。要望書が求める記録の本体はここで作られる値であり、
/// 発話内容には一切触れない。
public enum Levels {
    /// 16bit相当の実用ダイナミックレンジ。完全な無音による -inf を避けるための下限。
    public static let floorDbfs: Double = -90.0

    public static func rmsDbfs(_ frame: [Float]) -> Double {
        guard !frame.isEmpty else { return floorDbfs }
        var sum = 0.0
        for sample in frame {
            let v = Double(sample)
            sum += v * v
        }
        let rms = (sum / Double(frame.count)).squareRoot()
        guard rms > 0 else { return floorDbfs }
        return max(20.0 * log10(rms), floorDbfs)
    }

    public static func clipRatio(_ frame: [Float], threshold: Float = 0.98) -> Double {
        guard !frame.isEmpty else { return 0 }
        var clipped = 0
        for sample in frame where abs(sample) >= threshold {
            clipped += 1
        }
        return Double(clipped) / Double(frame.count)
    }

    /// dB値の算術平均は物理的に誤り。パワー領域で平均してからdB化する。
    /// 先行する検証でこれを誤って実装し、無音フレームに平均が引きずられた経緯がある。
    public static func powerMeanDbfs(_ levels: [Double]) -> Double? {
        guard !levels.isEmpty else { return nil }
        var sum = 0.0
        for level in levels {
            sum += pow(10.0, level / 10.0)
        }
        return 10.0 * log10(sum / Double(levels.count) + 1e-300)
    }
}

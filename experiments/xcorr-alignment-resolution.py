"""
1秒集約のレベル時系列だけで、2台の記録をどこまでの精度で整合できるかを確認する。

ADR-0003は「双方のレベル時系列を相互相関にかければオフセットを実測できる」としているが、
ADR-0006で交換するのが1秒集約値だけの場合、1秒より細かいずれを復元できるのかは未検証だった。

相関ピークを放物線補間すればサンプル間隔より細かい推定ができる(サブサンプル遅延推定)ため、
1秒サンプルでも1秒より良い精度が出るはず。それを数値で確認する。
"""
import numpy as np

FINE_MS = 20          # 元の解析粒度
AGG_SEC = 1.0         # 交換する集約粒度
DURATION_SEC = 600    # 10分の記録を想定

rng = np.random.default_rng(7)


def speech_envelope(duration_sec, fine_ms):
    """発話のオン/オフが続く包絡を細かい粒度で作る。"""
    n = int(duration_sec * 1000 / fine_ms)
    env = np.zeros(n)
    t = 0
    while t < n:
        talk = int(rng.uniform(0.3, 2.5) * 1000 / fine_ms)
        pause = int(rng.uniform(0.2, 1.5) * 1000 / fine_ms)
        env[t:t + talk] = 1.0
        t += talk + pause
    return env


def shift_fractional(env, shift_sec, fine_ms):
    """細かい粒度で時間シフトする(整数サンプル単位で十分細かい)。"""
    shift_samples = int(round(shift_sec * 1000 / fine_ms))
    return np.roll(env, shift_samples)


def aggregate(env, fine_ms, agg_sec):
    """1秒ごとの発話フレーム比率に集約する(schemaのspeech_ratioに相当)。"""
    per_bin = int(agg_sec * 1000 / fine_ms)
    n_bins = len(env) // per_bin
    return env[:n_bins * per_bin].reshape(n_bins, per_bin).mean(axis=1)


def estimate_offset(a, b, agg_sec):
    """相互相関 + 放物線補間でオフセットを推定する。戻り値は秒。"""
    a = a - a.mean()
    b = b - b.mean()
    corr = np.correlate(b, a, mode="full")
    lags = np.arange(-len(a) + 1, len(b))
    k = int(np.argmax(corr))
    # 端でなければ放物線補間でサブサンプル精度を得る
    if 0 < k < len(corr) - 1:
        y0, y1, y2 = corr[k - 1], corr[k], corr[k + 1]
        denom = (y0 - 2 * y1 + y2)
        delta = 0.5 * (y0 - y2) / denom if denom != 0 else 0.0
    else:
        delta = 0.0
    return (lags[k] + delta) * agg_sec


def trial(true_offset_sec, noise_level, gain_b=0.6):
    env = speech_envelope(DURATION_SEC, FINE_MS)
    env_b = shift_fractional(env, true_offset_sec, FINE_MS)

    a = aggregate(env, FINE_MS, AGG_SEC)
    b = aggregate(env_b, FINE_MS, AGG_SEC)

    # 相手側は別の機械・別の経路なので、利得が違いノイズも乗る
    b = b * gain_b + rng.normal(0, noise_level, size=len(b))
    a = a + rng.normal(0, noise_level, size=len(a))

    est = estimate_offset(a, b, AGG_SEC)
    return est - true_offset_sec


print(f"記録長 {DURATION_SEC}s / 集約粒度 {AGG_SEC}s / 交換するのは1秒ごとの発話比率のみ\n")
print(f"{'真のずれ':>10s} {'ノイズ':>8s} {'誤差の平均':>12s} {'誤差の標準偏差':>14s} {'最大誤差':>10s}")
print("-" * 62)

for true_offset in (0.0, 0.3, 0.5, 1.7):
    for noise in (0.01, 0.05, 0.15):
        errs = [trial(true_offset, noise) for _ in range(30)]
        errs = np.array(errs)
        print(f"{true_offset:9.2f}s {noise:8.2f} {errs.mean():11.3f}s "
              f"{errs.std():13.3f}s {np.abs(errs).max():9.3f}s")

print("\n補間なし(整数ラグのみ)の場合と比較:")


def estimate_offset_no_interp(a, b, agg_sec):
    a = a - a.mean(); b = b - b.mean()
    corr = np.correlate(b, a, mode="full")
    lags = np.arange(-len(a) + 1, len(b))
    return lags[int(np.argmax(corr))] * agg_sec


def trial_no_interp(true_offset_sec, noise_level, gain_b=0.6):
    env = speech_envelope(DURATION_SEC, FINE_MS)
    env_b = shift_fractional(env, true_offset_sec, FINE_MS)
    a = aggregate(env, FINE_MS, AGG_SEC)
    b = aggregate(env_b, FINE_MS, AGG_SEC) * gain_b + rng.normal(0, noise_level, size=len(a))
    a = a + rng.normal(0, noise_level, size=len(a))
    return estimate_offset_no_interp(a, b, AGG_SEC) - true_offset_sec


for true_offset in (0.3, 0.5):
    errs = np.array([trial_no_interp(true_offset, 0.05) for _ in range(30)])
    print(f"  真のずれ {true_offset}s → 誤差の平均 {errs.mean():.3f}s / 最大 {np.abs(errs).max():.3f}s")

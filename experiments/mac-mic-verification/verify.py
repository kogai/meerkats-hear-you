#!/usr/bin/env python3
"""
実マイクによる音声レベル/発話区間検出の実機検証(macOS想定)。

`python3 verify.py` を実行すると、既定のマイクから指定秒数録音し、フレーム単位の
音声レベル(dBFS)・クリッピング・発話区間検出(VAD)を計算し、結果を
results/report-<timestamp>.json に保存する。あわせてループバック(システム出力音声)
キャプチャに使えそうなデバイスが存在するかも一覧・検出する。
"""
import argparse
import datetime
import json
import os
import platform
import sys
import time
import wave

import numpy as np

try:
    import sounddevice as sd
except ImportError:
    print("sounddevice が見つかりません。`pip install -r requirements.txt` を実行してください。",
          file=sys.stderr)
    sys.exit(1)

try:
    import webrtcvad
    HAVE_WEBRTC = True
except ImportError:
    HAVE_WEBRTC = False

SR = 16000
FRAME_MS = 20
FRAME_LEN = int(SR * FRAME_MS / 1000)
DB_FLOOR = -90.0

LOOPBACK_KEYWORDS = [
    "blackhole", "soundflower", "loopback", "aggregate",
    "multi-output", "multi output", "monitor", "virtual",
]

BASE = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(BASE, "results")


def list_devices():
    devices = sd.query_devices()
    info = []
    for i, d in enumerate(devices):
        info.append({
            "index": i,
            "name": d["name"],
            "max_input_channels": d["max_input_channels"],
            "max_output_channels": d["max_output_channels"],
            "default_samplerate": d["default_samplerate"],
        })
    return info


def find_loopback_candidates(devices):
    cands = []
    for d in devices:
        name_l = d["name"].lower()
        if d["max_input_channels"] > 0 and any(k in name_l for k in LOOPBACK_KEYWORDS):
            cands.append(d)
    return cands


def rms_dbfs(x):
    rms = np.sqrt(np.mean(x ** 2))
    if rms <= 0:
        return DB_FLOOR
    return float(max(20 * np.log10(rms), DB_FLOOR))


def power_mean_dbfs(levels_db):
    if len(levels_db) == 0:
        return None
    power = 10 ** (np.asarray(levels_db) / 10.0)
    return float(10 * np.log10(np.mean(power) + 1e-300))


def clip_ratio(x, threshold=0.98):
    return float(np.mean(np.abs(x) >= threshold))


def record(duration_sec, device=None):
    print(f"\n{duration_sec}秒間録音します。普段の会話のように話したり間を置いたりしてください。")
    for i in (3, 2, 1):
        print(i)
        time.sleep(1)
    print("録音開始...")
    audio = sd.rec(int(duration_sec * SR), samplerate=SR, channels=1,
                    dtype="float32", device=device)
    sd.wait()
    print("録音終了。")
    return audio.flatten()


def save_wav(path, sig):
    sig = np.clip(sig, -1.0, 1.0)
    pcm = (sig * 32767).astype(np.int16)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())


def energy_vad(frame_levels_db, margin_db=12.0, floor_percentile=15):
    noise_floor = float(np.percentile(frame_levels_db, floor_percentile))
    threshold = noise_floor + margin_db
    decisions = frame_levels_db > threshold
    return decisions, noise_floor, threshold


def webrtc_vad_decisions(pcm_int16_bytes, aggressiveness=2):
    vad = webrtcvad.Vad(aggressiveness)
    frame_bytes = FRAME_LEN * 2
    n_frames = len(pcm_int16_bytes) // frame_bytes
    decisions = []
    for i in range(n_frames):
        chunk = pcm_int16_bytes[i * frame_bytes:(i + 1) * frame_bytes]
        decisions.append(vad.is_speech(chunk, SR))
    return np.array(decisions)


def analyze(sig):
    n_frames = len(sig) // FRAME_LEN
    levels = np.array([rms_dbfs(sig[i * FRAME_LEN:(i + 1) * FRAME_LEN]) for i in range(n_frames)])
    clips = np.array([clip_ratio(sig[i * FRAME_LEN:(i + 1) * FRAME_LEN]) for i in range(n_frames)])

    energy_pred, noise_floor, energy_threshold = energy_vad(levels)

    result = {
        "n_frames": n_frames,
        "duration_sec": len(sig) / SR,
        "overall_dbfs": rms_dbfs(sig),
        "clip_ratio_overall": float(np.mean(clips > 0)),
        "clip_ratio_peak_frame": float(np.max(clips)) if n_frames else 0.0,
        "noise_floor_db": noise_floor,
        "energy_vad_threshold_db": energy_threshold,
        "energy_vad_speech_ratio": float(np.mean(energy_pred)),
        "mean_speech_dbfs_energy_vad": power_mean_dbfs(levels[energy_pred]) if energy_pred.any() else None,
        "mean_nonspeech_dbfs_energy_vad": power_mean_dbfs(levels[~energy_pred]) if (~energy_pred).any() else None,
        "webrtc_vad_available": HAVE_WEBRTC,
    }

    if HAVE_WEBRTC:
        pcm16 = np.clip(sig, -1.0, 1.0)
        pcm16 = (pcm16 * 32767).astype(np.int16).tobytes()
        usable_bytes = n_frames * FRAME_LEN * 2
        webrtc_pred = webrtc_vad_decisions(pcm16[:usable_bytes])
        result["webrtc_vad_speech_ratio"] = float(np.mean(webrtc_pred))
        result["mean_speech_dbfs_webrtc_vad"] = (
            power_mean_dbfs(levels[webrtc_pred]) if webrtc_pred.any() else None
        )
        # 両VADの一致率(実運用でどれだけ食い違うかの目安)
        agree = np.mean(energy_pred[:len(webrtc_pred)] == webrtc_pred)
        result["vad_agreement_ratio"] = float(agree)

    flags = []
    if result["clip_ratio_overall"] > 0.001:
        flags.append("CLIPPING(クリッピング検出: 入力ゲインが高すぎる可能性)")
    speech_ratio = result["energy_vad_speech_ratio"]
    if speech_ratio < 0.02:
        flags.append(
            "NO_SPEECH_DETECTED(発話がほぼ検出されなかった: マイク未選択/権限/無音区間のみ の可能性)"
        )
    mean_speech = result["mean_speech_dbfs_energy_vad"]
    if mean_speech is not None and mean_speech < -35:
        flags.append(f"LOW_LEVEL(発話レベルが低い: {mean_speech:.1f}dBFS)")
    if (mean_speech is not None and result["mean_nonspeech_dbfs_energy_vad"] is not None):
        snr = mean_speech - result["mean_nonspeech_dbfs_energy_vad"]
        result["snr_db_estimate"] = snr
        if snr < 10:
            flags.append(f"LOW_SNR(推定SN比{snr:.1f}dBが低い)")
    if result["overall_dbfs"] <= DB_FLOOR + 0.01:
        flags.append("SIGNAL_ABSENT(信号が全く来ていない: デバイス選択/権限/ミュートを確認)")
    if not flags:
        flags.append("NORMAL(明確な異常は検出されず)")
    result["flags"] = flags

    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=15.0, help="録音秒数(既定15秒)")
    parser.add_argument("--device", type=int, default=None,
                         help="使用する入力デバイスのインデックス(既定はシステムのデフォルト入力)")
    parser.add_argument("--list-devices", action="store_true",
                         help="オーディオデバイス一覧を表示して終了する")
    args = parser.parse_args()

    devices = list_devices()
    loopback_candidates = find_loopback_candidates(devices)

    if args.list_devices:
        print("=== オーディオデバイス一覧 ===")
        for d in devices:
            tag = " [loopback候補]" if d in loopback_candidates else ""
            print(f"[{d['index']:2d}] {d['name']}  "
                  f"(in:{d['max_input_channels']} out:{d['max_output_channels']}){tag}")
        return

    print("=== 環境情報 ===")
    print(f"OS: {platform.platform()}")
    print(f"Python: {platform.python_version()}")
    print(f"webrtcvad: {'利用可能' if HAVE_WEBRTC else '未インストール(energy VADのみで評価)'}")
    print(f"ループバック候補デバイス: "
          f"{[d['name'] for d in loopback_candidates] if loopback_candidates else 'なし'}")

    try:
        sig = record(args.duration, device=args.device)
    except Exception as e:
        print(f"\n録音に失敗しました: {e}", file=sys.stderr)
        print("macOSの場合、システム設定 > プライバシーとセキュリティ > マイク で、"
              "ターミナル(またはこのスクリプトを実行しているアプリ)にマイクアクセスを"
              "許可しているか確認してください。", file=sys.stderr)
        sys.exit(1)

    result = analyze(sig)

    print("\n=== 解析結果 ===")
    for k, v in result.items():
        if k == "flags":
            continue
        print(f"{k:36s}: {v}")
    print("--- flags ---")
    for f in result["flags"]:
        print(f" - {f}")

    os.makedirs(RESULTS_DIR, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    json_path = os.path.join(RESULTS_DIR, f"report-{ts}.json")
    wav_path = os.path.join(RESULTS_DIR, f"recording-{ts}.wav")
    save_wav(wav_path, sig)

    report = {
        "timestamp": ts,
        "environment": {
            "os": platform.platform(),
            "python_version": platform.python_version(),
            "webrtcvad_available": HAVE_WEBRTC,
            "devices": devices,
            "loopback_candidates": loopback_candidates,
            "recording_device_index": args.device,
        },
        "analysis": result,
        "wav_file": os.path.basename(wav_path),
    }
    with open(json_path, "w") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    print(f"\n結果を保存しました: {json_path}")
    print(f"録音データ(ローカルのみ、外部送信なし): {wav_path}")
    print("この report-*.json の中身をClaudeに共有してください。")


if __name__ == "__main__":
    main()

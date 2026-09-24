#!/usr/bin/env python3
"""WALが既定の自動チェックポイント閾値に達するまでの時間を測る。

ADR-0016 は「自動チェックポイントが COMMIT の中、つまり音のスレッドで走る」ことを
問題にしているが、**どれくらいの頻度で起きるかは見積もりのままだった。**
`PRAGMA wal_autocheckpoint` の既定は1000ページで、そこに達するまでの時間は
1コミットあたりWALに積まれるページ数で決まる。それはスキーマと行の大きさで決まるので、
macOS でなくても測れる。

測れないのは**チェックポイント1回の実費用**のほうで、そちらは fsync の実装に依る
(macOS の F_FULLFSYNC は他と挙動が違う)。ここでは頻度だけを出す。

エージェント側と同じスキーマ・同じ書き込みパターンを再現する:

- 常時層 `seconds` を1秒1行、`flushIntervalSeconds` ごとに1トランザクション
- 詳細層 `detail_windows` は異常に入るたびに1行。BLOB は 500フレーム × 5バイト
- アンカーは5分に1行
"""

import argparse
import os
import sqlite3
import tempfile

PAGE_SIZE = 4096
AUTOCHECKPOINT_PAGES = 1000

# agent/Sources/MeerkatsCore/RecordingStore*.swift と同じ形。
SCHEMA = """
CREATE TABLE sessions (
  id               INTEGER PRIMARY KEY,
  started_wall_us  INTEGER NOT NULL,
  ended_wall_us    INTEGER,
  agent_version    TEXT NOT NULL
);
CREATE TABLE streams (
  id           INTEGER PRIMARY KEY,
  session_id   INTEGER NOT NULL REFERENCES sessions(id),
  kind         TEXT NOT NULL,
  device_name  TEXT,
  sample_rate  INTEGER NOT NULL,
  frame_ms     INTEGER NOT NULL
);
CREATE TABLE clock_anchors (
  session_id    INTEGER NOT NULL REFERENCES sessions(id),
  monotonic_us  INTEGER NOT NULL,
  wall_us       INTEGER NOT NULL,
  PRIMARY KEY (session_id, monotonic_us)
);
CREATE TABLE seconds (
  stream_id     INTEGER NOT NULL REFERENCES streams(id),
  monotonic_us  INTEGER NOT NULL,
  mean_dbfs     REAL NOT NULL,
  min_dbfs      REAL NOT NULL,
  max_dbfs      REAL NOT NULL,
  speech_ratio  REAL NOT NULL,
  clip_ratio    REAL NOT NULL,
  frame_count   INTEGER NOT NULL,
  PRIMARY KEY (stream_id, monotonic_us)
);
CREATE TABLE gaps (
  id            INTEGER PRIMARY KEY,
  stream_id     INTEGER NOT NULL REFERENCES streams(id),
  start_us      INTEGER NOT NULL,
  end_us        INTEGER NOT NULL,
  reason        TEXT NOT NULL
);
CREATE TABLE detail_windows (
  id            INTEGER PRIMARY KEY,
  stream_id     INTEGER NOT NULL REFERENCES streams(id),
  start_us      INTEGER NOT NULL,
  frame_count   INTEGER NOT NULL,
  trigger       TEXT NOT NULL,
  frames        BLOB NOT NULL
);
"""

DETAIL_BLOB = bytes(500 * 5 + 8)  # 500フレーム × 5バイト + ヘッダ


def wal_pages(path: str) -> int:
    """WALファイルのページ数。先頭32バイトはWALヘッダ、各フレームは24バイトのヘッダを持つ。"""
    try:
        size = os.path.getsize(path + "-wal")
    except FileNotFoundError:
        return 0
    if size <= 32:
        return 0
    return (size - 32) // (24 + PAGE_SIZE)


def run(streams: int, flush_seconds: int, anomaly_every: int, hours: float) -> dict:
    directory = tempfile.mkdtemp()
    path = os.path.join(directory, "recordings.sqlite")
    db = sqlite3.connect(path, isolation_level=None)
    db.execute(f"PRAGMA page_size = {PAGE_SIZE};")
    db.execute("PRAGMA journal_mode = WAL;")
    db.execute("PRAGMA synchronous = NORMAL;")
    # **自動チェックポイントを切って測る。** 切らないと1000ページで勝手に畳まれて、
    # 「1000ページに達するまで」を測っているつもりが畳まれた後の量を見ることになる。
    db.execute("PRAGMA wal_autocheckpoint = 0;")
    db.executescript(SCHEMA)
    db.execute("INSERT INTO sessions VALUES (1, 0, NULL, '0.1');")
    for stream in range(1, streams + 1):
        db.execute(
            "INSERT INTO streams VALUES (?, 1, ?, NULL, 48000, 20);",
            (stream, "mic" if stream == 1 else "output"),
        )

    total_seconds = int(hours * 3600)
    reached = None
    commits = 0
    anomalies = 0

    for second in range(0, total_seconds, flush_seconds):
        for stream in range(1, streams + 1):
            db.execute("BEGIN;")
            for offset in range(flush_seconds):
                us = (second + offset) * 1_000_000
                db.execute(
                    "INSERT INTO seconds VALUES (?, ?, -25.0, -30.0, -20.0, 0.6, 0.0, 50);",
                    (stream, us),
                )
            db.execute("COMMIT;")
            commits += 1

            if anomaly_every and (second // flush_seconds) % anomaly_every == 0:
                db.execute("BEGIN;")
                db.execute(
                    "INSERT INTO detail_windows (stream_id, start_us, frame_count,"
                    " trigger, frames) VALUES (?, ?, 500, 'clipping', ?);",
                    (stream, second * 1_000_000, DETAIL_BLOB),
                )
                db.execute("COMMIT;")
                commits += 1
                anomalies += 1

            if second % 300 == 0:
                db.execute("BEGIN;")
                db.execute(
                    "INSERT OR REPLACE INTO clock_anchors VALUES (1, ?, ?);",
                    (second * 1_000_000, second * 1_000_000),
                )
                db.execute("COMMIT;")
                commits += 1

        if reached is None and wal_pages(path) >= AUTOCHECKPOINT_PAGES:
            reached = second

    pages = wal_pages(path)
    db.close()
    return {
        "streams": streams,
        "anomalies": anomalies,
        "commits": commits,
        "pages": pages,
        "pages_per_commit": pages / commits if commits else 0,
        "reached_seconds": reached,
    }


def describe(seconds: int | None) -> str:
    if seconds is None:
        return "達しない"
    return f"{seconds // 60}分{seconds % 60}秒"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hours", type=float, default=8.0)
    parser.add_argument("--flush-seconds", type=int, default=10)
    args = parser.parse_args()

    print(f"page_size={PAGE_SIZE}  wal_autocheckpoint={AUTOCHECKPOINT_PAGES}ページ")
    print(f"{args.hours}時間ぶん、常時層は{args.flush_seconds}秒に1トランザクション\n")

    header = f"{'ストリーム':<12}{'詳細層':<20}{'1000ページ到達':<18}{'1コミットあたり'}"
    print(header)
    print("-" * len(header) * 2)

    for streams in (1, 2):
        for anomaly_every, label in ((0, "なし"), (30, "5分に1回"), (6, "1分に1回")):
            result = run(streams, args.flush_seconds, anomaly_every, args.hours)
            print(
                f"{streams:<14}{label:<22}"
                f"{describe(result['reached_seconds']):<20}"
                f"{result['pages_per_commit']:.2f}ページ"
            )


if __name__ == "__main__":
    main()

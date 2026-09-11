# ADR-0004: 記録の保存先にSQLiteを使う

## ステータス

Accepted (2026-09-11)

## 背景

[ADR-0002](0002-hybrid-recording-granularity.md)により、保存されるのは1秒ごとの集約値(常時層)と、
異常区間の20msフレーム値(詳細層)の2種類になる。[ADR-0003](0003-monotonic-clock-with-wall-clock-anchor.md)
により、時刻は連続単調時計のオフセットと定期的な実時刻アンカーで持つ。

分析側は「この時間帯どうだったか」という時間範囲の問い合わせを行う。また要望書はクラウドにデータを
送らないことを求めており、保存先はローカルに閉じる。

### インストール作業は発生しない

macOSは `libsqlite3` を標準で同梱しているため、SQLiteの採用によって利用者にも開発者にも
インストール作業は生じない。Swiftからは `import SQLite3` でOS同梱のものを直接使えるほか、
GRDB.swift等のラッパーを使う場合もSPMで取得するソースパッケージであり、リンク先は結局OS同梱の
SQLiteである。[ADR-0001](0001-swift-macos-only-agent.md)で決めた「Xcodeを使わずSPMとCLIで完結」
という構成は崩れない。

### 2つの層はアクセスパターンが異なる

スキーマを具体化する過程で、常時層と詳細層で必要な性質が違うことが分かった。

- **常時層**は条件付きの範囲問い合わせを受ける。「この時間帯の秒を並べる」「最小レベルが落ち込んだ
  秒を探す」といった使い方をするため、SQLの行として持つ必要がある。
- **詳細層**は常に「その異常区間をまるごと取り出す」という読まれ方しかしない。フレーム単位で条件検索
  する場面が存在しない。行として持ってもSQLの利点が働かない一方、行数とインデックスの負担だけが残る。

20msフレームを1行ずつ持つと、10秒の区間で500行・約30KBを消費する。同じ内容を1フレーム5バイト
(Float32のdBFS + フラグ1バイト)のパック配列としてBLOBに収めれば約2.5KBで済み、**1桁以上小さくなる。**

### 常時の書き込み頻度はバッテリーに効く

常駐エージェントはノートPC上で終日動く。1秒ごとに個別のトランザクションを張ると毎時3600回の
コミットが発生し、ディスクとCPUを起こし続けることになる。記録内容そのものは軽量でも、
**書き込みの頻度は電力消費として現れる。**

## 決定

SQLiteを使う。データベースファイルはユーザーのアプリケーションサポートディレクトリ配下に置く。

### スキーマ

```sql
-- エージェントの1回の連続稼働。時計はセッション単位で共有する。
CREATE TABLE sessions (
  id               INTEGER PRIMARY KEY,
  started_wall_us  INTEGER NOT NULL,   -- UTCエポック マイクロ秒
  ended_wall_us    INTEGER,
  agent_version    TEXT NOT NULL
);

-- ADR-0003の実時刻アンカー。数分間隔で追加される。
CREATE TABLE clock_anchors (
  session_id    INTEGER NOT NULL REFERENCES sessions(id),
  monotonic_us  INTEGER NOT NULL,
  wall_us       INTEGER NOT NULL,
  PRIMARY KEY (session_id, monotonic_us)
);

-- 1セッション内の音声ストリーム。自分のマイクと受信音声で別レコードになる。
CREATE TABLE streams (
  id           INTEGER PRIMARY KEY,
  session_id   INTEGER NOT NULL REFERENCES sessions(id),
  kind         TEXT NOT NULL,          -- 'mic' | 'output'
  device_name  TEXT,
  sample_rate  INTEGER NOT NULL,
  frame_ms     INTEGER NOT NULL
);

-- 常時層。
CREATE TABLE seconds (
  stream_id     INTEGER NOT NULL REFERENCES streams(id),
  monotonic_us  INTEGER NOT NULL,
  mean_dbfs     REAL NOT NULL,
  min_dbfs      REAL NOT NULL,
  max_dbfs      REAL NOT NULL,
  speech_ratio  REAL NOT NULL,
  clip_ratio    REAL NOT NULL,
  PRIMARY KEY (stream_id, monotonic_us)
);

-- 詳細層。frames は1フレーム5バイトのパック配列。
CREATE TABLE detail_windows (
  id            INTEGER PRIMARY KEY,
  stream_id     INTEGER NOT NULL REFERENCES streams(id),
  start_us      INTEGER NOT NULL,
  frame_count   INTEGER NOT NULL,
  trigger       TEXT NOT NULL,          -- 何を検知して残したか
  frames        BLOB NOT NULL
);
```

時計(`clock_anchors`)をセッション単位、音声のパラメータ(`streams`)をストリーム単位に分けている。
自分のマイクと受信音声は同じ機械の同じ時計で観測されるため、**アンカーを二重に持つ必要がない。**
`kind` 列は[ADR-0006](0006-file-exchange-before-p2p.md)で後回しにした受信音声側の受け皿であり、
今入れておくコストはゼロに等しい。

### 運用パラメータ

- `journal_mode = WAL` — 分析側が読んでいる間もエージェントの書き込みが止まらない。
- `synchronous = NORMAL` — WALモードではコミットごとのfsyncが行われなくなる。OSのクラッシュや
  電源断で直近のコミットを失う可能性があるが、失うのは数秒分のレベル値にすぎない。
- 常時層の書き込みは**メモリ上に貯めて数秒ごとにまとめてコミットする。**

## 影響

- 時間範囲での問い合わせが素直に書けるため、分析側の実装が単純になる。
- 単一ファイルでサーバープロセスが不要。クラウドに送らないという要件と自然に整合する。
- 常時層の保存量は1時間あたり約320KB、1日8時間の利用で約2.6MB、**1年でも1GB弱**にとどまる。
  この規模なら保持期間の方針を最初から決める必要はなく、問題になってから考えればよい。
- 詳細層をBLOBにしたことで、**フレーム単位のSQL検索ができなくなる。** 将来「全区間から特定パターンの
  フレームを探す」という要求が出たら、この決定を見直す必要がある。現時点の用途(異常区間を後から見る)
  では不都合はない。
- BLOBの中身はスキーマではなくアプリケーション側の取り決めになるため、**フォーマットの版管理が必要**に
  なる。フレームあたりのバイト数を変える変更は、過去のデータを読めなくしうる。
- まとめてコミットする方式のため、**クラッシュ時に直近数秒の記録を失う。** 常時稼働のバッテリー消費と
  引き換えに受け入れる。
- 突合用の持ち出しには変換処理が必要になる。SQLiteのファイルをそのまま渡すのではなく、必要な時間範囲を
  抽出して交換用の形式に変換する([ADR-0006](0006-file-exchange-before-p2p.md))。

## 検討した代替案

### 追記専用のJSONL / 独自バイナリ

書き込みは最も単純になるが、分析側が毎回全体を読んで絞り込むことになる。範囲問い合わせが主な用途で
あることを考えると、インデックスを自前で持つか毎回走査するかの選択を迫られ、結局SQLiteの再実装に
近づく。採用しない。

### Core Data / SwiftData

Apple純正でSwiftから宣言的に書ける。ただし本件の主たるデータは1秒ごとに追記され続ける時系列であり、
オブジェクトグラフの管理や関係の追跡を必要としない。抽象化の層が増える分、書き込み頻度と
バッテリー消費の制御が見えにくくなる。素直にSQLiteを直接扱うほうが挙動を読みやすい。採用しない。

# スパイク: Xcodeなしでの .app バンドル・署名・マイク権限

[ADR-0001](../../docs/adr/0001-swift-macos-only-agent.md)と
[ADR-0005](../../docs/adr/0005-single-app-bundle.md)は、どちらも次の前提に乗っている。

> Xcodeを使わずに `.app` バンドルを組み立て、署名し、TCCの許可を得て維持する

**この前提は一度も確かめていない。** ここが崩れると、影響はADR-0001の「Xcodeを使わない」という判断
にまで及ぶ。設計に残っている最大の不確実性であり、それを潰すのがこのスパイクの目的。

## 確かめること

1. SPM + `codesign` で組んだ `.app` が、**アプリ自身の名前で**マイク権限を取れるか
   — 実機検証ではPythonスクリプトの権限がターミナルに紐づいていた。常駐エージェントが
   ターミナルの権限に相乗りするのは成立しないため、ここが分かれ目になる。
2. その権限が**リビルドをまたいで維持されるか**
   — ad-hoc署名はビルドのたびに同一性が変わりうる。毎回許可を求め直す羽目になるなら、
   開発中は安定した自己署名証明書が要る。
3. UIを持たない(`LSUIElement`)プロセスとして、実際に音声が取れるか

## 実行方法

```bash
mise run spike
```

初回はマイクアクセスの許可ダイアログが出る。許可すること。

## 結果の読み方

`~/Library/Application Support/LevelSpike/report-<epoch>.json` に書き出される。

| フィールド | 見るべき点 |
|---|---|
| `bundle_identifier` | `dev.meerkats.levelspike` になっていること。`(なし)` ならバンドルとして起動できていない |
| `authorization_status_before` | **2回目以降の実行での値が本題**(下記) |
| `prompted` | ダイアログを出したかどうか |
| `capture.signal_present` | `true` なら実際に音が来ている。`false` は権限はあるが無音しか来ていない状態 |
| `capture.mean_dbfs` | 話しかけていれば -50dBFS より大きい値になるはず |

## 権限が維持されるかの確認手順

**2回実行して、2回目の `authorization_status_before` を見る。**

```bash
mise run spike   # 1回目: notDetermined → ダイアログが出る
mise run spike   # 2回目: リビルドされた状態で再実行
```

- 2回目が `authorized` で `prompted` が `false` → **リビルドをまたいで権限が維持された。**
  ad-hoc署名のままで開発できる。
- 2回目が `notDetermined` で再びダイアログが出た → 権限が失われている。安定した署名の同一性が必要。
  `SPIKE_SIGN_IDENTITY` に自己署名証明書を指定して再検証する。

```bash
SPIKE_SIGN_IDENTITY="My Self-Signed Cert" mise run spike
```

`build.sh` が毎回 `CDHash` を表示するので、リビルド前後で値が変わっているかもあわせて確認できる。

## うまくいかないとき

アプリが起動直後に落ちてレポートが出ない場合:

```bash
log show --last 5m --predicate 'process == "LevelSpike"' --info
```

`NSMicrophoneUsageDescription` が無いとマイク要求の時点でプロセスが落ちるが、`build.sh` が生成する
Info.plistには含めてある。

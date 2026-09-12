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

## どこまでCIで確認できるか

上記3点のうち、**CIで確認できるのは限られる。**

| | CI (GitHub Actions) | Mac実機 |
|---|---|---|
| Swiftのコンパイル | ○ | ○ |
| バンドル組み立て・署名・`plutil`/`codesign` の検証 | ○ | ○ |
| CDHashがリビルドで変わるか | ○ | ○ |
| **マイク権限をアプリ自身の名前で取れるか** | **×** | ○ |
| **権限がリビルドをまたいで維持されるか** | **×** | ○ |
| 実際に音声が取れるか | × | ○ |

ホストランナーにはGUIセッションが無いため許可ダイアログに応答する人間がおらず、マイクという
入力デバイスも存在しない。したがって**本題である権限まわりは実機でしか答えが出ない。**

ただしCDHashの比較はCIでできるため、権限が維持されるかどうかの**機序**は部分的に分かる。
ad-hoc署名でリビルドのたびにCDHashが変われば、TCCから見て別のアプリになり許可を失う可能性が高い。
これは [`.github/workflows/spike-bundle.yml`](../../.github/workflows/spike-bundle.yml) が
初回ビルド・変更なしの再ビルド・変更ありの再ビルドの3つを比較する形で確認している。

## CIで分かったこと(2026-09-11)

ワークフローの初回実行で以下が確認できた。

**ビルドとバンドルは通る。** SPMでのコンパイル、`.app` の組み立て、ad-hoc署名、`plutil -lint`、
`codesign --verify --strict`(`satisfies its Designated Requirement`)がすべて成功した。
`LSUIElement` も `true` として効いている。Xcodeを使わない構成そのものは成立している。

**ad-hoc署名では、コードを変えるたびに同一性が変わる。**

| | CDHash |
|---|---|
| A: 初回ビルド | `1acdb2b2…` |
| B: 変更なしで再ビルド | `1acdb2b2…`(Aと同じ) |
| C: コードを変えて再ビルド | `546f1448…`(異なる) |

変更していなければ再ビルドしても同一性は変わらないが、**1行変えただけで別の同一性になる。**
TCCがこの同一性で許可を紐づけているなら、開発中はコードを変えるたびに許可を求め直すことになる。
実機検証に入る前に、安定した自己署名証明書を用意しておくほうが早い可能性が高い。

ただしこれはCDHashの挙動からの推測であり、**TCCが実際にどう振る舞うかは実機でしか分からない。**

## 実行方法(実機)

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

**3回実行する。** 「再ビルド」と「コード変更」は別物なので、2回では足りない。ソースが変わらなければ
`swift build` は何もせずバイナリも同一になるため、2回目だけでは変更時の挙動を確かめられない。

```bash
mise run spike   # 1回目: notDetermined → ダイアログが出る
mise run spike   # 2回目: 変更なしで再ビルド
sed -i '' 's/let captureSeconds = 3.0/let captureSeconds = 3.5/' Sources/LevelSpike/main.swift
mise run spike   # 3回目: コードを変えて再ビルド
```

各回の `authorization_status_before` と `prompted` を見る。`build.sh` が毎回 `CDHash` を表示するので、
同一性の変化と対応づけられる。

### 実測済みの結果(ad-hoc署名、2026-09-11)

| 実行 | `authorization_status_before` | `prompted` | CDHash |
|---|---|---|---|
| 1回目 | `notDetermined` | `true` | A |
| 2回目(変更なし) | `authorized` | `false` | A(同じ) |
| 3回目(変更あり) | `notDetermined` | `true` | B(異なる) |

**コードを変えると許可が失われる。** 3回目が `denied` ではなく `notDetermined` に戻るのは、TCCが
変更後のバイナリをまったく別の未知のアプリとして扱っているため。詳細は
[検証レポート](../../docs/experiments/macos-app-bundle-spike-result.md)。

したがって**開発中は安定した署名の同一性が必要**になる。自己署名証明書を用意して指定する。

```bash
SPIKE_SIGN_IDENTITY="My Self-Signed Cert" mise run spike
```

なおこの構成で許可が実際に維持されるかは未検証。

## うまくいかないとき

アプリが起動直後に落ちてレポートが出ない場合:

```bash
log show --last 5m --predicate 'process == "LevelSpike"' --info
```

`NSMicrophoneUsageDescription` が無いとマイク要求の時点でプロセスが落ちるが、`build.sh` が生成する
Info.plistには含めてある。

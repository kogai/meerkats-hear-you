# マイク実機検証(macOS)

実マイクからの音声レベル・発話区間検出(VAD)が、あなたのMac上で実際に機能するかを確認するための
ツール。1コマンドで録音〜解析〜結果出力まで行う。

## 実行方法

### mise を使う場合(推奨)

[mise](https://mise.jdx.dev/) が入っていれば、Pythonのバージョン管理・依存インストール・実行を
1コマンドで行える(タスク定義はリポジトリルートの `.mise.toml` にあるので、リポジトリ内のどこからでも実行可能)。

```bash
mise run verify
```

- 初回はマイクアクセスの許可ダイアログが出ることがあります。許可してください。
- 既定では15秒間録音します(秒数を変えたい場合は `mise run verify -- --duration 20`)。
- 録音中は普段の会話のように、話したり間を置いたりしてください。

デバイス一覧だけ確認したい場合:

```bash
mise run list-devices
```

特定のデバイス(例: BlackHoleなどのループバックデバイス)から録音したい場合:

```bash
mise run verify -- --device <一覧で表示されたインデックス番号>
```

### mise を使わない場合

```bash
cd experiments/mac-mic-verification
bash run.sh
```

オプションは同様に `bash run.sh --list-devices` / `bash run.sh --device <番号>` などで指定できる。

## 出力

実行すると `results/` ディレクトリに以下が保存されます(いずれもローカルのみ、外部送信なし)。

- `report-<timestamp>.json` — 環境情報・デバイス一覧・音声レベル/VAD解析結果
- `recording-<timestamp>.wav` — 録音した生データ(結果が想定と違う場合に自分で聞いて確認するため)

`report-<timestamp>.json` の内容をそのまま共有してもらえれば、それをもとに実現可能性レポートを作成する。

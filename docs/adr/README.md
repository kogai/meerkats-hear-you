# Architecture Decision Records

本プロジェクトの設計判断の記録。

## ステータスの意味

- **Accepted** — 議論のうえ決定済み。
- **Proposed** — 提案段階。実装着手前にレビューが必要。
- **Superseded** — 後続のADRによって置き換えられた。

## 一覧

| # | タイトル | ステータス |
|---|---|---|
| [0001](0001-swift-macos-only-agent.md) | エージェントはSwiftで実装し、macOS専用とする | Accepted |
| [0002](0002-hybrid-recording-granularity.md) | 記録はハイブリッド粒度で保存する | Accepted |
| [0003](0003-monotonic-clock-with-wall-clock-anchor.md) | 記録は連続単調時計と定期的な実時刻アンカーで時刻を持つ | Accepted |
| [0004](0004-sqlite-storage.md) | 記録の保存先にSQLiteを使う | Accepted |
| [0005](0005-single-app-bundle.md) | エージェントとUIを単一の .app バンドルにまとめ、メニューバーに常駐させる | Accepted |
| [0006](0006-file-exchange-before-p2p.md) | 突合は初期版ではファイル交換で行い、P2Pは後回しにする | Accepted |
| [0007](0007-signed-release-from-ci.md) | 配布用バイナリはCIで署名済みとして作り、タグで公開する | Accepted |
| [0008](0008-process-tap-for-received-audio.md) | 受信音声はCore Audioのプロセスタップで取得し、会議アプリに限定する | Accepted |
| [0010](0010-recording-floor-broadband-only.md) | 記録・送付する水準を Bolthole と定め、帯域を分けない | Accepted |

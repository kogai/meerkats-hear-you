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
| [0005](0005-headless-app-bundle.md) | エージェントはUIを持たない .app バンドルとして常駐させる | Accepted |
| [0006](0006-file-exchange-before-p2p.md) | 突合は初期版ではファイル交換で行い、P2Pは後回しにする | Proposed |

# ADR-0001: エージェントはSwiftで実装し、macOS専用とする

## ステータス

Accepted

## 背景

要望書([audio-level-monitoring.md](../requirements/audio-level-monitoring.md))はエージェントの
常駐を前提としており、以下が必要になる。

- マイク入力の継続的なキャプチャ
- 将来的に、相手の声がこちら側でどう鳴っているか(受信音声/ループバック)のキャプチャ
- 常時表示UI(気づくため)と分析UI(振り返るため)

実機検証([mac-mic-verification-result.md](../experiments/mac-mic-verification-result.md))により、
マイク入力側はPython + sounddeviceでも追加のネイティブインストールなしに取得できることが確認済み。
つまりマイク側は言語選択の決め手にならない。決め手は、残っている受信音声側にある。

macOS 13以降のScreenCaptureKitはシステム音声のキャプチャに対応し、14.4以降はCoreAudioの
プロセスタップも利用できる。これらが使えれば、BlackHole等の仮想オーディオデバイスのインストールを
利用者に要求せずに受信音声を取得できる。前回レポートで「macOSの主な障壁」として挙げた依存が
そこで解消される。いずれもApple純正フレームワークであり、Swift/Objective-Cからは直接、
RustやPythonからはブリッジ越しの利用になる。

また、突合の相手側も含め、参加者は全員macOSであることが確認されている。

## 決定

エージェントをSwiftで実装し、macOS専用とする。
開発にXcodeは使わず、Swift Package Managerと `swift build` によるCLIで完結させる。

## 影響

- 受信音声のキャプチャで純正フレームワークを直接利用できるため、仮想オーディオデバイスへの依存が
  解消される見込み。ただしScreenCaptureKit/プロセスタップの実挙動は未検証であり、着手時の確認が必要。
- 常時表示UIはNSStatusItem、分析UIはSwiftUIで、追加のUIスタックを持ち込まずに実装できる。
- **エージェントはmacOS専用になる。** 参加者にmacOS以外が加わった時点で、その環境用の実装が別途必要になる。
- **Xcodeを使わない代償として、ビルドスクリプトを自前で抱えることになる。** `.app` バンドルの組み立て
  (Info.plist、メニューバー常駐のためのLSUIElement、NSMicrophoneUsageDescription等)は通常Xcodeが
  担う部分であり、これをスクリプト化する必要がある。
- **開発中は安定した署名の同一性が事実上必須になる。**
  [スパイクで検証済み](../experiments/macos-app-bundle-spike-result.md)。ad-hoc署名では同一性が
  CDHashそのものであるため、**コードを1行変えるだけでTCCから見て別のアプリになり、許可を求め直される。**
  実機では変更後の状態が `denied` ではなく `notDetermined` に戻った(＝まったく未知のアプリ扱い)。
  ad-hocのままでは変更のたびにダイアログが出て開発ループが成立しないため、自己署名証明書を用意して
  署名の同一性を固定する必要がある。
- 検証に使ったPython実装(`experiments/mac-mic-verification/`)は役目を終え、以降は参照用とする。

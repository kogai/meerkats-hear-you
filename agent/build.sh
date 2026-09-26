#!/usr/bin/env bash
# SPM でビルドし、.app バンドルを組み立てて署名する。Xcodeは使わない(ADR-0001)。
#
# スパイクで確認済みの手順をそのまま使う。ad-hoc署名ではコードを1行変えるだけで
# TCCの許可を失うため、開発中は SIGN_IDENTITY に自己署名証明書を指定すること。
# 詳細は docs/experiments/macos-app-bundle-spike-result.md を参照。
#
# 環境変数:
#   SIGN_IDENTITY  署名に使う identity。未指定ならad-hoc(許可を失う。ADR-0007)
#   VERSION        CFBundleShortVersionString。リリースではタグから渡す
#   BUILD          CFBundleVersion。同じ VERSION でも作り直すたびに増やす
#   UNIVERSAL      1 なら arm64 と x86_64 の両方を含むバイナリにする
#   HARDENED       1 なら hardened runtime + entitlement + タイムスタンプで署名する。
#                  公証に出すならこれが要る。既定で切ってあるのは、実機で確認済みの
#                  開発時の署名の条件を、こちら側の都合で変えないため
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Meerkats"
EXECUTABLE="MeerkatsSentry"
BUNDLE_ID="dev.meerkats.agent"
APP_DIR="build/${APP_NAME}.app"
ENTITLEMENTS="build/${APP_NAME}.entitlements"
VERSION="${VERSION:-0.1}"
BUILD="${BUILD:-1}"

# 配布物は universal にする。ランナーは arm64 だが、受け取る側がIntelでない保証はない。
BUILD_ARGS=(-c release --product "$EXECUTABLE")
if [ "${UNIVERSAL:-0}" = "1" ]; then
	BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "=== SPM でビルド (${VERSION} build ${BUILD}) ==="
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/${EXECUTABLE}"

echo "=== .app バンドルを組み立て ==="
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "$BIN" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Xcodeが生成してくれる部分を自前で用意する。
# LSUIElement: Dockアイコンを持たないメニューバー常駐にする (ADR-0005)
# NSMicrophoneUsageDescription: これが無いとマイク要求の時点でプロセスが落ちる。
#   「会話中の」と書いていたが、実装は起動から終了までマイクを回し続けている。嘘だった。
#   受信側だけ「常時」と正直に書くと、落差でマイク側は会議中だけだと読まれる。両方揃える。
#
#   **「自分の声が相手に届きにくいこと」とは書かない。** マイクのレベルから分かるのは
#   入力が小さいことまでで、相手に届いたかどうかは分からない (ADR-0008 の冒頭)。
#   分かるのは原因の候補であって、結果ではない
# NSAudioCaptureUsageDescription: プロセスタップ (ADR-0008) に要る。マイクとは別の鍵で、
#   こちらが無いと受信音声のタップが張れない。
#   文面は「会議アプリの音」ではなく「このMacで鳴っている音」と書く。プロセスで限定しない
#   (ADR-0013) ので、会議アプリに限ると書くと嘘になる。
#   「何を」だけでなく「いつ」も書く。書かないと、会議中だけだと読まれる。
#
#   **目的は書いてよい。** 「相手の声が聞き取りづらいことに気づけるように」は何のために
#   録るかの話で、ある瞬間に鳴っているのが相手の声だという主張ではない。表示の文言から
#   「相手」を外した (原因を名指しできないため) のとは、別の話になる
cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.4</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>マイクが拾う音のレベルを、会議中かどうかによらず常時記録し、入力が小さすぎるなど相手に届きにくくなる原因に気づけるようにします。音声の内容は記録しません。</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>このMacで鳴っている音のレベルを、会議中かどうかによらず常時記録し、相手の声が聞き取りづらいことに気づけるようにします。音声の内容は記録しません。</string>
</dict>
</plist>
PLIST

# 公証には hardened runtime が要る。そしてその下では、この entitlement が無いと
# マイクをまったく取れない。付け忘れると、署名も公証も通ったうえで無音だけが録れる。
cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY" --identifier "$BUNDLE_ID")
if [ "${HARDENED:-0}" = "1" ]; then
	# タイムスタンプは外部サーバに問い合わせる。開発ビルドで既定にすると、
	# オフラインのときにビルドごと失敗する。
	SIGN_ARGS+=(--options runtime --entitlements "$ENTITLEMENTS" --timestamp)
fi

echo "=== 署名 (identity: ${IDENTITY}) ==="
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --strict "$APP_DIR" && echo "署名の検証: OK"


codesign -dvvv "$APP_DIR" 2>&1 | grep -Ei "^(Identifier|CDHash|Signature)" || true
echo
echo "バンドル: ${APP_DIR}"
echo "起動: open ${APP_DIR}"

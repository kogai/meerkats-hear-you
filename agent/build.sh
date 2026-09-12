#!/usr/bin/env bash
# SPM でビルドし、.app バンドルを組み立てて署名する。Xcodeは使わない(ADR-0001)。
#
# スパイクで確認済みの手順をそのまま使う。ad-hoc署名ではコードを1行変えるだけで
# TCCの許可を失うため、開発中は SIGN_IDENTITY に自己署名証明書を指定すること。
# 詳細は docs/experiments/macos-app-bundle-spike-result.md を参照。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Meerkats"
EXECUTABLE="MeerkatsAgent"
BUNDLE_ID="dev.meerkats.agent"
APP_DIR="build/${APP_NAME}.app"

echo "=== SPM でビルド ==="
swift build -c release --product "$EXECUTABLE"
BIN="$(swift build -c release --show-bin-path)/${EXECUTABLE}"

echo "=== .app バンドルを組み立て ==="
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "$BIN" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Xcodeが生成してくれる部分を自前で用意する。
# LSUIElement: Dockアイコンを持たないメニューバー常駐にする (ADR-0005)
# NSMicrophoneUsageDescription: これが無いとマイク要求の時点でプロセスが落ちる
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
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>会話中の音声レベルを記録し、聞き取りづらさに気づけるようにします。音声の内容は記録しません。</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:--}"
echo "=== 署名 (identity: ${IDENTITY}) ==="
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --strict "$APP_DIR" && echo "署名の検証: OK"

if [ "$IDENTITY" = "-" ]; then
	echo
	echo "注意: ad-hoc署名です。コードを変えて再ビルドするとTCCの許可を失い、"
	echo "      マイクの許可ダイアログが再び出ます。開発を続けるなら自己署名証明書を用意し、"
	echo "      SIGN_IDENTITY に指定してください。"
fi

codesign -dvvv "$APP_DIR" 2>&1 | grep -Ei "^(Identifier|CDHash|Signature)" || true
echo
echo "バンドル: ${APP_DIR}"
echo "起動: open ${APP_DIR}"

#!/usr/bin/env bash
# SPM でビルドし、.app バンドルを組み立てて署名する。Xcodeは使わない。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LevelSpike"
BUNDLE_ID="dev.meerkats.levelspike"
APP_DIR="build/${APP_NAME}.app"

echo "=== SPM でビルド ==="
swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "=== .app バンドルを組み立て ==="
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "$BIN" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Xcodeが生成してくれる部分を自前で用意する。
# LSUIElement: Dockアイコンを持たない常駐プロセスにする (ADR-0005)
# NSMicrophoneUsageDescription: これが無いとマイク要求時にプロセスが落ちる
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
	<string>音声レベルの記録が可能かを検証します。音声の内容は記録しません。</string>
</dict>
</plist>
PLIST

# 署名。SPIKE_SIGN_IDENTITY を指定すればその同一性で署名する。
# 未指定なら ad-hoc 署名 ("-") になり、ビルドのたびに同一性が変わりうる。
# この違いがTCCの許可の維持に効くかどうかが、このスパイクの検証対象。
IDENTITY="${SPIKE_SIGN_IDENTITY:--}"
echo "=== 署名 (identity: ${IDENTITY}) ==="
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
codesign --verify --strict "$APP_DIR" && echo "署名の検証: OK"

echo "=== 署名の同一性 ==="
# CDHash がリビルド前後で変われば、TCCから見て別のアプリになりうる。
codesign -dvvv "$APP_DIR" 2>&1 | grep -Ei "^(Identifier|TeamIdentifier|Authority|Signature|CDHash)" || true

echo
echo "バンドル: ${APP_DIR}"

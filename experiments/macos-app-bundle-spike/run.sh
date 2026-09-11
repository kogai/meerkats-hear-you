#!/usr/bin/env bash
# ビルドして .app を起動し、書き出されたレポートを表示する。
#
# ターミナルから中の実行ファイルを直接叩くと、TCCの権限はターミナルに紐づいてしまう
# (実機検証でPythonスクリプトがそうなった)。アプリ自身の名前で権限を取れるかを見たいので、
# 必ず `open` 経由で起動する。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LevelSpike"
APP_DIR="build/${APP_NAME}.app"
REPORT_DIR="${HOME}/Library/Application Support/${APP_NAME}"

./build.sh

mkdir -p "$REPORT_DIR"
MARKER="$(mktemp)"   # これより新しいレポートだけを今回の結果とみなす
sleep 1

echo
echo "=== .app を open 経由で起動 ==="
echo "初回はマイクアクセスの許可を求めるダイアログが出ます。許可してください。"
open -W "$APP_DIR"

echo
echo "=== 今回の実行結果 ==="
LATEST="$(find "$REPORT_DIR" -name 'report-*.json' -newer "$MARKER" -print0 2>/dev/null \
          | xargs -0 ls -t 2>/dev/null | head -1 || true)"
rm -f "$MARKER"

if [[ -z "$LATEST" ]]; then
	echo "レポートが書き出されていません。アプリが起動直後に落ちた可能性があります。" >&2
	echo "以下で原因を確認してください:" >&2
	echo "  log show --last 5m --predicate 'process == \"${APP_NAME}\"' --info" >&2
	exit 1
fi

cat "$LATEST"
echo
echo "(${LATEST})"

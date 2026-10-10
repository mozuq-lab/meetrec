#!/bin/bash
# メニューバー常駐版 MeetRec.app をビルドして build/MeetRec.app に作る。
#
# 署名には次の順で最初に見つかったものを使う:
#   1. 環境変数 SIGN_IDENTITY（例: SIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)"）
#   2. キーチェーンにある "Apple Development" 証明書
#   3. ad-hoc 署名（ビルドし直すたびに権限の再設定が必要になる）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MeetRecMenuBar
BIN_DIR=$(swift build -c release --show-bin-path)

APP=build/MeetRec.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/MeetRecMenuBar" "$APP/Contents/MacOS/MeetRec"
cp App/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development[^"]*)".*/\1/p' | head -n 1)
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "注意: 署名用の証明書がないため ad-hoc 署名にします。ビルドし直すたびに、MeetRec の権限を設定し直す必要があります。" >&2
fi
codesign --force --sign "$IDENTITY" "$APP"

echo "作成しました: ${APP}（署名: ${IDENTITY}）"

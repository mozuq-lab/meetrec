#!/bin/bash
# メニューバー常駐版 MeetRec.app をビルドして build/MeetRec.app に作る。
#
# 使い方:
#   scripts/build-app.sh              ビルドして署名する
#   scripts/build-app.sh --notarize   さらに公証を受け、配布用の build/MeetRec.zip を作る
#
# 署名には次の順で最初に見つかったものを使う:
#   1. 環境変数 SIGN_IDENTITY（証明書の名前の一部、または SHA-1 ハッシュ。"-" なら ad-hoc 署名）
#   2. キーチェーンにある "Developer ID Application" 証明書（配布用。公証にはこれが必要）
#   3. キーチェーンにある "Apple Development" 証明書（自分の Mac で使う用）
#   4. ad-hoc 署名（ビルドし直すたびに権限の再設定が必要になる）
#
# 公証には notarytool のキーチェーンプロファイルを使う（環境変数 NOTARY_PROFILE。既定は meetrec-notary）。
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    -h | --help) sed -nE '2,14s/^# ?//p' "$0"; exit 0 ;;
    *) echo "不明なオプション: ${arg}（--help で使い方を表示）" >&2; exit 64 ;;
  esac
done
NOTARY_PROFILE="${NOTARY_PROFILE:-meetrec-notary}"

APP=build/MeetRec.app
ZIP=build/MeetRec.zip
ENTITLEMENTS=App/MeetRec.entitlements

# --- 署名に使う証明書を決める（ビルドの前に決めて、公証できない組み合わせを早めに止める） ---

IDENTITIES=$(security find-identity -v -p codesigning)

# 指定した文字列（名前の一部またはハッシュ）を含む最初の証明書を「ハッシュ 名前」の形で返す
lookup_identity() {
  sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$/\1 \2/p' <<<"$IDENTITIES" | grep -F -m 1 -- "$1" || true
}

FOUND=""
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
  FOUND=$(lookup_identity "$SIGN_IDENTITY")
  if [[ -z "$FOUND" ]]; then
    echo "エラー: SIGN_IDENTITY に合う証明書がキーチェーンにありません: $SIGN_IDENTITY" >&2
    exit 1
  fi
elif [[ -z "${SIGN_IDENTITY:-}" ]]; then
  FOUND=$(lookup_identity "Developer ID Application")
  [[ -n "$FOUND" ]] || FOUND=$(lookup_identity "Apple Development")
fi

if [[ -n "$FOUND" ]]; then
  # 同じ名前の証明書が複数あっても迷わないよう、ハッシュで指定する
  IDENTITY=${FOUND%% *}
  IDENTITY_NAME=${FOUND#* }
else
  IDENTITY="-"
  IDENTITY_NAME="ad-hoc"
fi

DEVELOPER_ID=0
[[ "$IDENTITY_NAME" == "Developer ID Application:"* ]] && DEVELOPER_ID=1

if ((NOTARIZE && !DEVELOPER_ID)); then
  echo "エラー: 公証には Developer ID Application 証明書での署名が必要です（いまの署名: ${IDENTITY_NAME}）" >&2
  exit 1
fi

# --- ビルドして .app を組み立てる ---

swift build -c release --product MeetRecMenuBar
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/MeetRecMenuBar" "$APP/Contents/MacOS/MeetRec"
cp App/Info.plist "$APP/Contents/Info.plist"

# --- 署名する ---

# hardened runtime は公証の条件。マイクを使うための許可は entitlements に書いてある
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
if ((DEVELOPER_ID)); then
  # 証明書の期限が切れた後も署名が有効であり続けるよう、Apple のタイムスタンプを付ける（公証の条件）
  SIGN_ARGS+=(--timestamp)
fi
if [[ "$IDENTITY" == "-" ]]; then
  echo "注意: 署名用の証明書がないため ad-hoc 署名にします。ビルドし直すたびに、MeetRec の権限を設定し直す必要があります。" >&2
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
echo "作成しました: ${APP}（署名: ${IDENTITY_NAME}）"

# --- 公証する ---

if ((NOTARIZE)); then
  echo "公証を申請しています。結果が出るまで数分かかります…"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if ! RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json); then
    echo "$RESULT" >&2
    echo "エラー: 公証を申請できませんでした。キーチェーンプロファイル ${NOTARY_PROFILE} を確認してください。" >&2
    rm -f "$ZIP"
    exit 1
  fi
  STATUS=$(plutil -extract status raw - <<<"$RESULT" 2>/dev/null || true)
  SUBMISSION_ID=$(plutil -extract id raw - <<<"$RESULT" 2>/dev/null || true)
  if [[ "$STATUS" != "Accepted" ]]; then
    echo "エラー: 公証に通りませんでした（結果: ${STATUS:-不明}、提出 ID: ${SUBMISSION_ID:-不明}）" >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    rm -f "$ZIP"
    exit 1
  fi

  # 公証の結果を .app に埋め込み、ネットにつながっていない Mac でも確認できるようにする
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type exec -vv "$APP"

  # 申請に使った zip には埋め込み前の .app が入っているので、埋め込み後の .app で作り直す
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "公証を受けました。配布用: ${ZIP}（提出 ID: ${SUBMISSION_ID}）"
fi

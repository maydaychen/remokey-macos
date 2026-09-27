#!/bin/bash
# make-dmg.sh — 把 dist/RemoKey.app 组装成 DMG。
#
# 默认只接受团队 3YT2ZK3Z94 的 Developer ID Application 正式签名。
# --unsigned 仅用于 CI／开发预览，产物名带 -unsigned，不得对外分发。

set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${REMOKEY_TEAM_ID:-3YT2ZK3Z94}"
DIST="dist"
APP="$DIST/RemoKey.app"
VOL_NAME="RemoKey"
ALLOW_UNSIGNED=0

case "${1:-}" in
    "") ;;
    --unsigned) ALLOW_UNSIGNED=1 ;;
    *) echo "用法：$0 [--unsigned]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "用法：$0 [--unsigned]" >&2; exit 2; }

[ -d "$APP" ] || { echo "❌ 找不到 ${APP}，先运行 scripts/package.sh --distribution。" >&2; exit 1; }

if [ "$ALLOW_UNSIGNED" = "0" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
    SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
    echo "$SIGNATURE_DETAILS" | grep -q '^Authority=Developer ID Application:' \
        || { echo "❌ 正式 DMG 只接受 Developer ID Application 签名。" >&2; exit 1; }
    echo "$SIGNATURE_DETAILS" | grep -q "^TeamIdentifier=${TEAM_ID}$" \
        || { echo "❌ App 签名团队不是 $TEAM_ID。" >&2; exit 1; }
    echo "$SIGNATURE_DETAILS" | grep -q '^Runtime Version=' \
        || { echo "❌ App 未启用 Hardened Runtime。" >&2; exit 1; }
    echo "$SIGNATURE_DETAILS" | grep -q '^Timestamp=' \
        || { echo "❌ App 缺少安全时间戳。" >&2; exit 1; }
else
    echo "⚠️  --unsigned：跳过正式签名校验，产物仅供开发预览，切勿分发。"
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info-app.plist)"
SUFFIX=""
[ "$ALLOW_UNSIGNED" = "1" ] && SUFFIX="-unsigned"
DMG="$DIST/RemoKey-$SHORT_VERSION$SUFFIX.dmg"

echo "-- 版本: $SHORT_VERSION"
echo "-- 目标: $DMG"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/RemoKey.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/README.txt" <<'TXT'
遥键 RemoKey 安装说明
==================

1. 把 RemoKey.app 拖到本窗口里的「Applications」文件夹。
2. 在「应用程序」中双击 RemoKey.app 启动。
3. 按 App 的向导授予「蓝牙」「输入监控」「辅助功能」三项权限。

正式发布前，开发者必须完成 Apple Developer ID 签名、公证与票据附加。如系统提示
无法验证开发者，请不要绕过 Gatekeeper，并到项目 Releases 页面重新下载安装包。

语音打字需要额外安装 BlackHole 2ch 虚拟声卡与兼容输入法，详见项目 README。

项目主页：https://github.com/maydaychen/remokey-macos
TXT

rm -f "$DMG"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

if [ "$ALLOW_UNSIGNED" = "0" ]; then
    SIGNING_IDENTITY="$(echo "$SIGNATURE_DETAILS" | sed -n 's/^Authority=Developer ID Application:/Developer ID Application:/p' | head -1)"
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
fi

echo "✅ 完成: $DMG"
if [ "$ALLOW_UNSIGNED" = "0" ]; then
    echo "➡️  下一步：NOTARY_PROFILE=<钥匙串配置名> ./scripts/notarize.sh"
fi

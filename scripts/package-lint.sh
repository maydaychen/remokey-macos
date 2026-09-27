#!/bin/bash
# package-lint.sh — 验收 Developer ID 签名并已公证的 RemoKey 分发产物。

set -euo pipefail
cd "$(dirname "$0")/.."

[ "$#" -eq 0 ] || { echo "用法：$0" >&2; exit 2; }

TEAM_ID="${REMOKEY_TEAM_ID:-3YT2ZK3Z94}"
APP="dist/RemoKey.app"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info-app.plist)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info-app.plist)"
ZIP="dist/RemoKey-$SHORT_VERSION.zip"
DMG="dist/RemoKey-$SHORT_VERSION.dmg"
FAIL=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1" >&2; FAIL=1; }

[ -d "$APP" ] || { echo "❌ 找不到 $APP，请先完成正式打包与公证。" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "❌ 找不到 $ZIP，请先完成正式打包与公证。" >&2; exit 1; }
[ -f "$DMG" ] || { echo "❌ 找不到 $DMG，请先完成正式打包与公证。" >&2; exit 1; }

if codesign --verify --deep --strict --verbose=2 "$APP" 2>/dev/null; then
    pass "codesign 严格验签"
else
    fail "codesign 严格验签"
fi

if codesign --verify --strict "$DMG" 2>/dev/null; then
    pass "DMG 严格验签"
else
    fail "DMG 缺少有效签名"
fi
DMG_DETAILS="$(codesign -d --verbose=4 "$DMG" 2>&1 || true)"
echo "$DMG_DETAILS" | grep -q '^Authority=Developer ID Application:' \
    && pass "DMG Developer ID Application 身份" || fail "DMG 签名身份错误"
echo "$DMG_DETAILS" | grep -q "^TeamIdentifier=${TEAM_ID}$" \
    && pass "DMG 签名团队 $TEAM_ID" || fail "DMG 签名团队错误"
echo "$DMG_DETAILS" | grep -q '^Timestamp=' \
    && pass "DMG 安全时间戳" || fail "DMG 缺少安全时间戳"

DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
echo "$DETAILS" | grep -q '^Authority=Developer ID Application:' \
    && pass "Developer ID Application 身份" || fail "签名身份不是 Developer ID Application"
echo "$DETAILS" | grep -q "^TeamIdentifier=${TEAM_ID}$" \
    && pass "签名团队 $TEAM_ID" || fail "签名团队不是 $TEAM_ID"
echo "$DETAILS" | grep -q '^Runtime Version=' \
    && pass "Hardened Runtime" || fail "缺少 Hardened Runtime"
echo "$DETAILS" | grep -q '^Timestamp=' \
    && pass "安全时间戳" || fail "缺少安全时间戳"

PLIST="$APP/Contents/Info.plist"
if plutil -lint "$PLIST" >/dev/null 2>&1; then
    pass "Info.plist 格式"
else
    fail "Info.plist 格式"
fi
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
[ "$BID" = "com.remokey.controller" ] \
    && pass "Bundle ID 为 com.remokey.controller" || fail "Bundle ID 漂移：${BID:-<空>}"
APP_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
[ "$APP_SHORT_VERSION" = "$SHORT_VERSION" ] \
    && pass "版本号为 $SHORT_VERSION" || fail "版本号漂移：${APP_SHORT_VERSION:-<空>}"
APP_BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
[ "$APP_BUILD_VERSION" = "$BUILD_VERSION" ] \
    && pass "build 为 $BUILD_VERSION" || fail "build 漂移：${APP_BUILD_VERSION:-<空>}"

if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    pass "App 公证票据"
else
    fail "App 缺少有效公证票据"
fi
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    pass "DMG 公证票据"
else
    fail "DMG 缺少有效公证票据"
fi

if spctl --assess --type execute --verbose=2 "$APP" >/dev/null 2>&1; then
    pass "Gatekeeper 接受 App"
else
    fail "Gatekeeper 拒绝 App"
fi
if spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" >/dev/null 2>&1; then
    pass "Gatekeeper 接受 DMG"
else
    fail "Gatekeeper 拒绝 DMG"
fi

ROUNDTRIP="$(mktemp -d)"
MOUNT_PATH=""
cleanup() {
    [ -z "$MOUNT_PATH" ] || hdiutil detach "$MOUNT_PATH" >/dev/null 2>&1 || true
    rm -rf "$ROUNDTRIP"
}
trap cleanup EXIT

ditto -x -k "$ZIP" "$ROUNDTRIP"
if codesign --verify --deep --strict "$ROUNDTRIP/RemoKey.app" 2>/dev/null \
    && xcrun stapler validate "$ROUNDTRIP/RemoKey.app" >/dev/null 2>&1; then
    pass "ZIP 往返后签名与公证票据有效"
else
    fail "ZIP 往返后签名或公证票据无效"
fi

if hdiutil verify "$DMG" >/dev/null 2>&1; then
    pass "DMG 校验和"
else
    fail "DMG 校验和"
fi
ATTACH_INFO="$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null || true)"
MOUNT_PATH="$(echo "$ATTACH_INFO" | grep -o '/Volumes/.*' | head -1)"
if [ -n "$MOUNT_PATH" ] && [ -d "$MOUNT_PATH" ]; then
    pass "DMG 可挂载"
    [ -d "$MOUNT_PATH/RemoKey.app" ] && pass "卷内含 RemoKey.app" || fail "卷内缺少 RemoKey.app"
    [ "$(readlink "$MOUNT_PATH/Applications" 2>/dev/null)" = "/Applications" ] \
        && pass "卷内含 Applications 软链" || fail "卷内缺少 Applications 软链"
    if codesign --verify --deep --strict "$MOUNT_PATH/RemoKey.app" 2>/dev/null \
        && xcrun stapler validate "$MOUNT_PATH/RemoKey.app" >/dev/null 2>&1; then
        pass "卷内 App 签名与公证票据有效"
    else
        fail "卷内 App 签名或公证票据无效"
    fi
else
    fail "DMG 挂载失败"
fi

if [ "$FAIL" = "0" ]; then
    echo "✅ 正式分发产物验收通过"
else
    echo "❌ 正式分发产物存在失败项" >&2
fi
exit "$FAIL"

# 遥键 RemoKey 正式发布操作卡

`build.sh` 分别编译 arm64 与 x86_64 并合并 Universal 二进制；正式产物验收必须确认两个架构均存在。Intel 真机蓝牙、语音和权限行为仍需单独验收。

正式站外分发只接受 Apple 官方链路：`Developer ID Application` 签名、Hardened Runtime、安全时间戳、Apple 公证与 stapling。自签名、`Apple Development` 和 ad-hoc 产物都不能上传到 GitHub Release。

## 0. 一次性准备

### 0.1 检查证书

```bash
./scripts/setup-signing.sh --distribution
```

需要同时满足：

- 团队 ID 为 `3YT2ZK3Z94`。
- 钥匙串中存在带私钥的 `Developer ID Application` 身份。
- Bundle ID 保持 `com.remokey.controller`。

如果缺少 Developer ID 证书，由 Account Holder 在 [Apple Developer Certificates](https://developer.apple.com/account/resources/certificates/add) 创建 `Developer ID Application`，并把证书及对应私钥安装到登录钥匙串。不要创建或继续使用 `RemoKey Dev` 自签名证书。

### 0.2 选择公证凭据

已配置 ASC CLI 时，可以直接复用其 API Key。先执行 `asc notarization list --limit 1` 验证公证接口访问权限；无需另建 App 专用密码，也不改变 ASC 默认认证配置。使用此方式时，执行第 2 节的 ASC 流程。

使用现有 `scripts/notarize.sh` 时，则按下面步骤保存 `notarytool` 钥匙串配置。

凭据只保存到 macOS 钥匙串，不写入仓库、脚本或终端历史。任选一种方式：

```bash
# App Store Connect API Key。命令执行时替换本机私钥路径、Key ID 和 Issuer ID。
xcrun notarytool store-credentials "RemoKey-Notary" \
  --key "/path/to/AuthKey_KEYID.p8" \
  --key-id "KEYID" \
  --issuer "ISSUER_UUID"

# 或 Apple ID + App 专用密码。省略 --password 后由 notarytool 安全提示输入。
xcrun notarytool store-credentials "RemoKey-Notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "3YT2ZK3Z94"
```

## 1. 本机开发包

```bash
./scripts/setup-signing.sh
./scripts/package.sh
```

默认使用团队 `3YT2ZK3Z94` 的 `Apple Development` 身份，生成 `dist/RemoKey.app` 和带 `-development` 后缀的 ZIP。它用于本机开发与真机验收，不得作为公开 Release。

## 2. 正式签名、公证与验收

```bash
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info-app.plist)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info-app.plist)"
VER="v$APP_VERSION"
echo "准备发布 $VER (build $BUILD_VERSION)"
git tag "$VER"                    # tag 必须与 Info-app.plist 中的版本一致
./scripts/package.sh --distribution
NOTARY_PROFILE="RemoKey-Notary" ./scripts/notarize.sh
./scripts/package-lint.sh
```

流程会依次完成：

1. 使用 Developer ID Application 签名 App，并启用 Hardened Runtime 与安全时间戳。
2. 提交 App 到 Apple notary service，等待结果并把票据 staple 到 App。
3. 重新生成包含已附票据 App 的 ZIP。
4. 生成 DMG，再次提交公证并把票据 staple 到 DMG。
5. 使用 `codesign`、`stapler`、`spctl`、ZIP 往返和 DMG 挂载执行最终验收。

任一步失败都停止发布。公证失败时先读取 `notarytool` 返回的 submission ID 和日志，不上传未通过产物。

### 使用 ASC 完成公证

完成 `./scripts/package.sh --distribution` 后，依次执行：

```bash
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info-app.plist)"
asc notarization submit --file "dist/RemoKey-$APP_VERSION.zip" --wait
# 必须确认状态为 Accepted，再附加票据。
xcrun stapler staple dist/RemoKey.app
xcrun stapler validate dist/RemoKey.app
ditto -c -k --keepParent dist/RemoKey.app "dist/RemoKey-$APP_VERSION.zip"
./scripts/make-dmg.sh
asc notarization submit --file "dist/RemoKey-$APP_VERSION.dmg" --wait
# DMG 同样必须为 Accepted。
xcrun stapler staple "dist/RemoKey-$APP_VERSION.dmg"
./scripts/package-lint.sh
```

## 3. 创建 GitHub Release

先核对版本标签是否指向本次构建的源码提交。已有同名历史标签时，不直接推送或覆盖，先处理标签冲突。

只有 `./scripts/package-lint.sh` 全绿后才能执行：

```bash
git push origin "$VER"
gh release create "$VER" \
  "dist/RemoKey-${VER}.dmg" \
  "dist/RemoKey-${VER}.zip" \
  --title "RemoKey $VER" \
  --notes-file RELEASE_NOTES.md
```

应用版本与 build 号以 `Resources/Info-app.plist` 为唯一事实源，分发文件名使用应用版本号。执行发布前先核对 `dist/` 中的准确名称，不要使用可能夹带 `-development` 或 `-unsigned` 的宽泛通配符。

## 4. GitHub Actions 边界

`.github/workflows/release.yml` 只验证 tag 对应源码并保存短期的 ad-hoc 预览 artifact，不创建公开 Release。正式 Developer ID 私钥与公证凭据尚未配置为 GitHub Secrets 前，公开发布必须在受控 Mac 上按第 2、3 节完成。

## 5. 禁止项

- 不上传文件名含 `-development` 或 `-unsigned` 的产物。
- 不使用 `Apple Development`、`Apple Distribution`、自签名证书或 ad-hoc 签名替代 Developer ID Application。
- 不把 `.p8`、`.p12`、证书密码、Apple ID 密码、App 专用密码或 Notary 凭据写入仓库。
- 不用“右键打开”或“仍要打开”绕过正式包的 Gatekeeper 失败；出现该情况视为发布验收失败。

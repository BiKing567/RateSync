#!/bin/bash
# 生成 RateSync「拖拽安装」风格 DMG（适配自 make-dmg-dragdrop.sh）
# create-dmg 8.1.0（node 版，内部用 appdmg，自带 660x422 浅灰底+深灰箭头背景）
# 自动 patch macos-alias：修复 APFS 挂载卷 getVolumeName() 返回空串、
# 导致 .DS_Store 中 backgroundImageAlias 卷名为空、Finder 背景不显示的问题。
# 用法：./make-dmg-losslessswitcher.sh [输出.dmg 路径]（默认工程目录 RateSync-3.0.dmg）
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RateSync"
VERSION="3.1.0"
BUILD="11"
OUT="${1:-$PROJ_DIR/RateSync-$VERSION.dmg}"

BUILD_STAGING="$(mktemp -d /tmp/lossless-dragdrop-build-XXXXXX)"
trap 'rm -rf "$BUILD_STAGING"' EXIT

APP="$BUILD_STAGING/Applications/$APP_NAME.app"

# create-dmg 固定工作目录（含 package.json 与 node_modules，复用 Moongate 已装好的 8.1.0）
DMG_TOOL_DIR="/Users/manfred/code/projects/Moon/tools/dmg"

# ---- 1. 构建 App（Release，staging，不触碰本机 /Applications）----
echo "==> 构建 ${APP_NAME}（Release）到 staging"
mkdir -p "$BUILD_STAGING/Applications"
xcodebuild -project "$PROJ_DIR/Quality.xcodeproj" -scheme RateSync -configuration Release \
  -derivedDataPath "$BUILD_STAGING/DerivedData" \
  CODE_SIGNING_ALLOWED=NO -disableAutomaticPackageResolution build > "$BUILD_STAGING/build.log" 2>&1
cp -R "$BUILD_STAGING/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP"

# ---- 2. 校验 build 产物 ----
if [[ ! -d "$APP" ]]; then
    echo "==> 错误：build 产物不存在：$APP" >&2
    exit 1
fi

# ---- 2.5 证书签名（稳定 TCC 授权身份）----
# 未签名/ad-hoc 签名 app 的辅助功能授权绑定二进制指纹，每次重新构建
# 都会失效（表现为"每次重启权限都掉"）。使用固定的自签名证书签名后，
# 授权按证书身份 + bundle id 记录，重新构建/更新不再丢失。
# 证书：自签名 "RateSync Developer"（已导入本机登录钥匙串）
SIGN_IDENTITY="${RATESYNC_SIGN_IDENTITY:-RateSync Developer}"
echo "==> 证书签名 ${APP_NAME}（身份：${SIGN_IDENTITY}）"
codesign --force --deep -s "$SIGN_IDENTITY" "$APP" || { echo "==> 错误：签名失败" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep -E "Signature|Authority" | head -3

# ---- 3. 检查 node / npm ----
echo "==> 检查 node / npm 环境"
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "==> 错误：create-dmg 需要 node 与 npm，请先安装 Node.js" >&2
    exit 1
fi

# ---- 4. 初始化 create-dmg 工作目录并安装依赖（缺失时才装）----
echo "==> 检查 create-dmg 工作目录：$DMG_TOOL_DIR"
if [[ ! -f "$DMG_TOOL_DIR/package.json" ]]; then
    mkdir -p "$DMG_TOOL_DIR"
    cat > "$DMG_TOOL_DIR/package.json" <<'JSON'
{
  "name": "lossless-dmg",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "create-dmg": "^8.1.0"
  }
}
JSON
fi
if [[ ! -d "$DMG_TOOL_DIR/node_modules" ]]; then
    echo "==> 安装 create-dmg 依赖（npm install）"
    (cd "$DMG_TOOL_DIR" && npm install --no-fund --no-audit)
fi

# ---- 5. patch macos-alias（幂等）：修复 APFS 卷名为空导致 Finder 背景不显示 ----
PATCH_FILE="$DMG_TOOL_DIR/node_modules/macos-alias/lib/create.js"
if grep -q '|| path.basename(volumePath)' "$PATCH_FILE"; then
    echo "==> macos-alias 已包含卷名修复（无需 patch）"
else
    echo "==> patch macos-alias：修复 APFS 卷名为空导致 Finder 背景不显示"
    perl -pi -e 's/name: addon\.getVolumeName\(volumePath\),/name: addon.getVolumeName(volumePath) || path.basename(volumePath),/' "$PATCH_FILE"
    if ! grep -q '|| path.basename(volumePath)' "$PATCH_FILE"; then
        echo "==> 错误：macos-alias patch 失败（未找到待替换代码）" >&2
        exit 1
    fi
fi

# ---- 6. 确保卷名不冲突（避免 hdiutil 自动改名导致 alias 卷名不匹配）----
if [[ -d "/Volumes/$APP_NAME" ]]; then
    echo "==> 卸载已挂载的 /Volumes/${APP_NAME}（避免卷名冲突）"
    hdiutil detach "/Volumes/$APP_NAME" || diskutil eject "/Volumes/$APP_NAME"
fi

# ---- 7. 用 create-dmg 打包 ----
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"
echo "==> 生成 DMG（create-dmg，卷名 ${APP_NAME}）"
"$DMG_TOOL_DIR/node_modules/.bin/create-dmg" --overwrite --no-code-sign --dmg-title="$APP_NAME" "$APP" "$OUT_DIR"

# ---- 8. 重命名为目标名 ----
DMG_CREATED="$OUT_DIR/$APP_NAME $VERSION.dmg"
if [[ -f "$DMG_CREATED" && "$DMG_CREATED" != "$OUT" ]]; then
    echo "==> 重命名为：$OUT"
    rm -f "$OUT"
    mv "$DMG_CREATED" "$OUT"
fi

echo "==> 完成：$OUT"
echo "    （分发到其他 Mac：首次打开需右键 → 打开，或先执行"
echo "      xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\"）"

# ── Sparkle 签名（应用内更新）────────────────────────────
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-/tmp/sparkle-tools/Build/Products/Release/sign_update}"
if [ -x "$SIGN_UPDATE" ]; then
    SIG_OUT="$("$SIGN_UPDATE" "$OUT")"
    SIG="$(printf '%s' "$SIG_OUT" | sed -E 's/^sparkle:edSignature="([^"]+)".*/\1/')"
    LEN="$(printf '%s' "$SIG_OUT" | sed -E 's/.*length="([0-9]+)".*/\1/')"
    echo ""
    echo "==> Sparkle 签名完成，请将以下 <item> 追加到仓库根目录 appcast.xml："
    SPARKLE_VERSION="$BUILD"
    SPARKLE_SHORTVERSION="$VERSION"
    cat <<EOF
        <item>
            <title>Version $VERSION (构建 $BUILD)</title>
            <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
            <sparkle:minimumSystemVersion>15.4</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/BiKing567/RateSync/releases/download/v$VERSION/$(basename "$OUT")" sparkle:version="$SPARKLE_VERSION" sparkle:shortVersionString="$SPARKLE_SHORTVERSION" sparkle:edSignature="$SIG" length="$LEN" type="application/octet-stream"/>
        </item>
EOF
else
    echo "==> 未找到 sign_update（可设 SPARKLE_SIGN_UPDATE 指向该工具），跳过 Sparkle 签名输出"
fi

#!/bin/bash
# 生成 RateSync「拖拽安装」风格 DMG（适配自 make-dmg-dragdrop.sh）
# create-dmg 8.1.0（node 版，内部用 appdmg，自带 660x422 浅灰底+深灰箭头背景）
# 自动 patch macos-alias：修复 APFS 挂载卷 getVolumeName() 返回空串、
# 导致 .DS_Store 中 backgroundImageAlias 卷名为空、Finder 背景不显示的问题。
# 用法：./make-dmg-losslessswitcher.sh [输出.dmg 路径]（默认工程目录 RateSync-3.0.dmg）
set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RateSync"
VERSION="3.2.5"
BUILD="35"
OUT="${1:-$PROJ_DIR/RateSync-$VERSION.dmg}"

BUILD_STAGING="$(mktemp -d /tmp/lossless-dragdrop-build-XXXXXX)"
trap 'rm -rf "$BUILD_STAGING"' EXIT

APP="$BUILD_STAGING/Applications/$APP_NAME.app"
BUILD_PRODUCT="$BUILD_STAGING/DerivedData/Build/Products/Release/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# create-dmg 必须来自显式指定或工程内的受信任目录，避免执行固定用户目录下的依赖。
DMG_TOOL_DIR="${RATESYNC_DMG_TOOL_DIR:-$PROJ_DIR/.dmg-tools}"
SOURCE_PACKAGES_DIR="${RATESYNC_SOURCE_PACKAGES_DIR:-}"
if [[ -z "$SOURCE_PACKAGES_DIR" ]]; then
    echo "==> 错误：打包必须显式设置 RATESYNC_SOURCE_PACKAGES_DIR" >&2
    exit 1
fi
if [[ ! -d "$SOURCE_PACKAGES_DIR" ]]; then
    echo "==> 错误：找不到 Swift Package 缓存，请设置 RATESYNC_SOURCE_PACKAGES_DIR" >&2
    exit 1
fi

# ---- 1. 构建 App（Release，staging，不触碰本机 /Applications）----
echo "==> 构建 ${APP_NAME}（Release）到 staging"
mkdir -p "$BUILD_STAGING/Applications"
xcodebuild -project "$PROJ_DIR/Quality.xcodeproj" -scheme RateSync -configuration Release \
  -derivedDataPath "$BUILD_STAGING/DerivedData" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" \
  CODE_SIGNING_ALLOWED=NO -disableAutomaticPackageResolution build > "$BUILD_STAGING/build.log" 2>&1
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$BUILD_PRODUCT" >/dev/null 2>&1 || true
fi
cp -R "$BUILD_PRODUCT" "$APP"

# ---- 2. 校验 build 产物 ----
if [[ ! -d "$APP" ]]; then
    echo "==> 错误：build 产物不存在：$APP" >&2
    exit 1
fi

# ---- 2.5 证书签名（稳定 TCC 授权身份）----
# 未签名/ad-hoc 签名 app 的辅助功能授权绑定二进制指纹，每次重新构建
# 都会失效（表现为"每次重启权限都掉"）。使用固定的自签名证书签名后，
# 授权按证书身份 + bundle id 记录，重新构建/更新不再丢失。
# 发布签名必须显式指定；本地测试可用 RATESYNC_SKIP_SIGNING=1 生成带 entitlement 的 ad-hoc DMG。
SIGN_IDENTITY="${RATESYNC_SIGN_IDENTITY:-}"
SKIP_SIGNING="${RATESYNC_SKIP_SIGNING:-0}"
NOTARY_PROFILE="${RATESYNC_NOTARY_PROFILE:-}"
SKIP_NOTARIZATION="${RATESYNC_SKIP_NOTARIZATION:-0}"
WIDGET_EXTENSION="$APP/Contents/PlugIns/RateSyncWidget.appex"

if [[ ! -d "$WIDGET_EXTENSION" ]]; then
    echo "==> 错误：缺少 RateSyncWidget.appex" >&2
    exit 1
fi

sign_nested_code() {
    local codesign_args=("$@")
    if [[ -d "$APP/Contents/Frameworks" ]]; then
        # Sign every nested Mach-O first (Sparkle includes Autoupdate, Updater,
        # and XPC helpers), then sign the framework bundles from the inside out.
        while IFS= read -r -d "" embedded_code; do
            if file "$embedded_code" | rg -q "Mach-O"; then
                codesign --force "${codesign_args[@]}" "$embedded_code" || {
                    echo "==> 错误：内嵌 Mach-O 签名失败：$embedded_code" >&2
                    exit 1
                }
            fi
        done < <(find "$APP/Contents/Frameworks" -type f -print0)
        while IFS= read -r -d "" embedded_framework; do
            codesign --force "${codesign_args[@]}" "$embedded_framework" || {
                echo "==> 错误：内嵌框架签名失败：$embedded_framework" >&2
                exit 1
            }
        done < <(find "$APP/Contents/Frameworks" -depth -type d -name "*.framework" -print0)
    fi
}

verify_entitlement_value() {
    local bundle_path="$1"
    local expected_value="$2"
    if ! codesign -d --entitlements - "$bundle_path" 2>/dev/null | rg -qF -- "$expected_value"; then
        echo "==> 错误：$bundle_path 缺少签名 entitlement：$expected_value" >&2
        exit 1
    fi
}

if [[ "$SKIP_SIGNING" == "1" ]]; then
    echo "==> 本机测试签名 ${APP_NAME}（ad-hoc，保留 WidgetKit entitlement）"
    sign_nested_code --sign -
    codesign --force --sign - \
        --entitlements "$PROJ_DIR/RateSyncWidget/RateSyncWidget.entitlements" \
        "$WIDGET_EXTENSION" || { echo "==> 错误：Widget 扩展本机签名失败" >&2; exit 1; }
    codesign --force --sign - \
        --entitlements "$PROJ_DIR/Quality/Quality.entitlements" \
        "$APP" || { echo "==> 错误：App 本机签名失败" >&2; exit 1; }
    verify_entitlement_value "$WIDGET_EXTENSION" "[Key] com.apple.security.app-sandbox"
    codesign --verify --deep --strict "$APP"
else
    if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "==> 错误：发布打包必须设置 RATESYNC_SIGN_IDENTITY；测试包才可设置 RATESYNC_SKIP_SIGNING=1" >&2
        exit 1
    fi
    IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if ! printf "%s\n" "$IDENTITY_LIST" | rg -qF -- "$SIGN_IDENTITY"; then
        echo "==> 错误：签名身份不可用：$SIGN_IDENTITY" >&2
        printf "%s\n" "$IDENTITY_LIST" >&2
        exit 1
    fi
    MATCHED_IDENTITY="$(printf "%s\n" "$IDENTITY_LIST" | rg -F -- "$SIGN_IDENTITY" | sed -n "1p" || true)"
    if ! printf "%s\n" "$MATCHED_IDENTITY" | rg -q "Developer ID Application:|Apple Development:"; then
        echo "==> 错误：发布包必须使用 Developer ID Application 或 Apple Development 证书" >&2
        printf "%s\n" "$MATCHED_IDENTITY" >&2
        exit 1
    fi
    echo "==> 证书签名 ${APP_NAME}（身份：${SIGN_IDENTITY}）"
    sign_nested_code --options runtime --timestamp -s "$SIGN_IDENTITY"
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" \
        --entitlements "$PROJ_DIR/RateSyncWidget/RateSyncWidget.entitlements" \
        "$WIDGET_EXTENSION" || { echo "==> 错误：Widget 扩展签名失败" >&2; exit 1; }
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" \
        --entitlements "$PROJ_DIR/Quality/Quality.entitlements" \
        "$APP" || { echo "==> 错误：App 签名失败" >&2; exit 1; }
    codesign -dv "$APP" 2>&1 | grep -E "Signature|Authority" | head -3
    verify_entitlement_value "$WIDGET_EXTENSION" "[Key] com.apple.security.app-sandbox"
    codesign --verify --deep --strict "$APP"
    if ! codesign -d --verbose=4 "$APP" 2>&1 | rg -q "flags=.*runtime"; then
        echo "==> 错误：发布 App 未启用 Hardened Runtime" >&2
        exit 1
    fi
fi

# ---- 3. 检查 node / npm ----
echo "==> 检查 node / npm 环境"
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "==> 错误：create-dmg 需要 node 与 npm，请先安装 Node.js" >&2
    exit 1
fi

# ---- 4. 检查 create-dmg 工作目录（不自动安装依赖）----
echo "==> 检查 create-dmg 工作目录：$DMG_TOOL_DIR"
if [[ ! -f "$DMG_TOOL_DIR/package.json" || ! -x "$DMG_TOOL_DIR/node_modules/.bin/create-dmg" ]]; then
    echo "==> 错误：找不到受信任的 create-dmg，请设置 RATESYNC_DMG_TOOL_DIR 指向已安装且锁定依赖的目录" >&2
    exit 1
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
    echo "==> 错误：/Volumes/${APP_NAME} 已被占用，为避免误卸载外部磁盘，请先手动卸载后重试" >&2
    exit 1
fi

# ---- 7. 用 create-dmg 打包 ----
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"
DMG_CREATED="$OUT_DIR/$APP_NAME $VERSION.dmg"
touch "$DMG_CREATED"
echo "==> 生成 DMG（create-dmg，卷名 ${APP_NAME}）"
"$DMG_TOOL_DIR/node_modules/.bin/create-dmg" --overwrite --no-code-sign --dmg-title="$APP_NAME" "$APP" "$OUT_DIR"

# ---- 8. 重命名为目标名 ----
if [[ -f "$DMG_CREATED" && "$DMG_CREATED" != "$OUT" ]]; then
    echo "==> 重命名为：$OUT"
    rm -f "$OUT"
    mv "$DMG_CREATED" "$OUT"
fi

# ---- 8.5 校验最终 DMG 内的 App（防止打包工具或复制流程破坏签名）----
verify_packaged_app() {
    local dmg_path="$1"
    (
        set -e
        local mount_point
        mount_point="$(mktemp -d "${TMPDIR:-/tmp}/ratesync-dmg-verify.XXXXXX")"
        trap 'hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true; rmdir "$mount_point" 2>/dev/null || true' EXIT

        hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null

        local packaged_app="$mount_point/$APP_NAME.app"
        if [[ ! -d "$packaged_app" ]]; then
            packaged_app="$(find "$mount_point" -maxdepth 2 -type d -name "$APP_NAME.app" -print -quit)"
        fi
        if [[ -z "$packaged_app" || ! -d "$packaged_app" ]]; then
            echo "==> 错误：DMG 内找不到 $APP_NAME.app" >&2
            exit 1
        fi

        local packaged_widget="$packaged_app/Contents/PlugIns/RateSyncWidget.appex"
        if [[ ! -d "$packaged_widget" ]]; then
            echo "==> 错误：DMG 内缺少 RateSyncWidget.appex" >&2
            exit 1
        fi

        codesign --verify --deep --strict "$packaged_app"
        verify_entitlement_value "$packaged_widget" "[Key] com.apple.security.app-sandbox"
        echo "==> DMG 内 App 与 Widget 签名校验通过"
    )
}

verify_packaged_app "$OUT"

if [[ "$SKIP_SIGNING" != "1" ]]; then
    if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
        echo "==> 警告：RATESYNC_SKIP_NOTARIZATION=1，仅生成已签名但未公证的测试包"
    else
        if [[ -z "$NOTARY_PROFILE" ]]; then
            echo "==> 错误：发布打包必须设置 RATESYNC_NOTARY_PROFILE，或显式设置 RATESYNC_SKIP_NOTARIZATION=1 生成测试包" >&2
            exit 1
        fi
        echo "==> 提交 Apple 公证：$OUT"
        xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$OUT"
        xcrun stapler validate "$OUT"
    fi
fi

echo "==> 完成：$OUT"
if [[ "$SKIP_SIGNING" == "1" || "$SKIP_NOTARIZATION" == "1" ]]; then
    echo "    当前为本机测试包，不适合直接分发"
else
    echo "    已完成 Developer ID 签名、Hardened Runtime 和 Apple 公证"
fi

# ── Sparkle 签名（应用内更新）────────────────────────────
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
if [[ -n "$SIGN_UPDATE" && -x "$SIGN_UPDATE" ]]; then
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

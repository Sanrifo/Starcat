#!/usr/bin/env bash
#
# run-debug-self.sh — 本机自用 Debug：ad-hoc 签名并启动 StarcatDirect。
#
# 给没有正式团队证书的开源构建使用。不替换 scripts/run-debug-direct.sh：
# 那条入口仍用 Apple Development 和 StarcatDirect.entitlements。
#
# 关键约束：
# - CODE_SIGN_IDENTITY=-，不传正式 Team ID，也不申请描述文件。
# - 受限制 entitlement（associated-domains、application-groups）不能出现在产物里，
#   否则 ad-hoc 签名会被系统拒绝。本地模型因此落到 Application Support。
# - 不注册 Widget，屏保也不是启动条件。桌面小组件和 starcat.ink 回跳在此构建不可用。
# - 显式关闭 ENABLE_DEBUG_DYLIB，避免需要构建后 deep re-sign。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/debug-build-environment.sh"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-Self"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/Starcat.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Starcat"
WIDGET_EXTENSION_PATH="$APP_PATH/Contents/PlugIns/StarcatDirectWidgets.appex"
SAVER_PATH="$APP_PATH/Contents/Resources/StarcatScreensaver.saver"
SELF_ENTITLEMENTS="$PROJECT_ROOT/Starcat/StarcatDirectSelf.entitlements"
LOCAL_AI_APP_GROUP="8WCUMGCWMB.com.starcat.app.localai"
DIRECT_DEBUG_BUNDLE_ID="com.starcat.app.direct.debug"
DIRECT_RELEASE_BUNDLE_ID="com.starcat.app.direct"
DIRECT_DEBUG_WIDGET_BUNDLE_ID="com.starcat.app.direct.debug.widgets"
# ad-hoc。不用正式团队的 Apple Development 身份。
DEBUG_SIGN_IDENTITY="-"

RUN_MODE="run"
case "${1:-}" in
  "")
    ;;
  --build-only)
    RUN_MODE="build-only"
    ;;
  *)
    echo "用法：$0 [--build-only]"
    exit 2
    ;;
esac

COMMAND_LOG="$(mktemp "${TMPDIR:-/tmp}/starcat-self-build.XXXXXX")"
trap 'rm -f "$COMMAND_LOG"' EXIT

run_with_failure_log() {
  local stage="$1"
  shift
  local exit_code

  if "$@" >"$COMMAND_LOG" 2>&1; then
    return 0
  else
    exit_code=$?
    printf 'ERROR: %s失败（exit code: %s），完整日志如下：\n' "$stage" "$exit_code" >&2
    cat "$COMMAND_LOG" >&2
    return "$exit_code"
  fi
}

# 自用构建同样固定稳定版 Xcode，避免继承到未装 Metal Toolchain 的 Beta。
starcat_select_stable_xcode
starcat_prepare_debug_derived_data "$PROJECT_ROOT" "$DERIVED_DATA" "self-debug"

# 与 Direct Debug 共用时间戳 build 号，避免 Sparkle 把本地包判成比线上旧。
BUILD_VERSION="${STARCAT_DIRECT_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
if ! [[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: 自用 Debug build version 必须是纯数字，当前: ${BUILD_VERSION:-<empty>}"
  exit 1
fi

# 自用包和正式 Direct Debug 共用 bundle id，必须先关掉旧实例，否则会抢同一份本地数据。
running_direct_pids() {
  /usr/bin/osascript -l JavaScript -e "
ObjC.import('AppKit');
var bundleIdentifiers = ['$DIRECT_DEBUG_BUNDLE_ID', '$DIRECT_RELEASE_BUNDLE_ID'];
var processIdentifiers = [];
bundleIdentifiers.forEach(function(bundleIdentifier) {
  $.NSRunningApplication
    .runningApplicationsWithBundleIdentifier(bundleIdentifier)
    .js
    .forEach(function(app) {
      processIdentifiers.push(Number(app.processIdentifier));
    });
});
processIdentifiers.join('\n');
"
}

running_target_pids() {
  local bundle_pids executable_pids
  bundle_pids="$(running_direct_pids)" || return 1
  executable_pids="$(pgrep -f -x "$APP_EXECUTABLE" || true)"
  printf '%s\n%s\n' "$bundle_pids" "$executable_pids" \
    | awk 'NF' \
    | sort -u
}

reject_restricted_entitlements() {
  local label="$1"
  local entitlements="$2"
  if grep -q "com.apple.security.app-sandbox" <<<"$entitlements"; then
    echo "ERROR: ${label} 带有沙箱 entitlement，自用非沙箱构建拒绝继续。"
    exit 1
  fi
  if grep -Fq "com.apple.developer.associated-domains" <<<"$entitlements"; then
    echo "ERROR: ${label} 带有 associated-domains，ad-hoc 自用签名不能携带。"
    exit 1
  fi
  if grep -Fq "com.apple.security.application-groups" <<<"$entitlements" \
    || grep -Fq "$LOCAL_AI_APP_GROUP" <<<"$entitlements"; then
    echo "ERROR: ${label} 带有 App Group，ad-hoc 自用签名不能携带。"
    exit 1
  fi
}

cd "$PROJECT_ROOT"

if [ "$RUN_MODE" = "run" ]; then
  echo "==> 关闭已运行的 StarcatDirect（如有）..."
  if ! DIRECT_PIDS="$(running_target_pids)"; then
    echo "ERROR: 无法查询 Direct bundle id / executable 进程，拒绝继续。"
    exit 1
  fi
  if [ -n "$DIRECT_PIDS" ]; then
    while IFS= read -r pid; do
      if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
      fi
    done <<<"$DIRECT_PIDS"
  fi

  for _ in {1..100}; do
    if ! DIRECT_PIDS="$(running_target_pids)"; then
      echo "ERROR: 无法查询 Direct bundle id / executable 进程，拒绝继续启动。"
      exit 1
    fi
    if [ -z "$DIRECT_PIDS" ]; then
      break
    fi
    sleep 0.1
  done
  if [ -n "$DIRECT_PIDS" ]; then
    echo "ERROR: 等待旧 StarcatDirect 退出超时，拒绝启动新实例。"
    echo "       Direct PID:"
    while IFS= read -r pid; do
      printf '       %s\n' "$pid"
    done <<<"$DIRECT_PIDS"
    exit 1
  fi
fi

echo "==> 生成 Xcode 工程..."
run_with_failure_log "生成 Xcode 工程" xcodegen generate

echo "==> 构建 StarcatDirect Debug（本机自用 / ad-hoc）..."
# DEVELOPMENT_TEAM 显式置空，盖掉 Secrets.xcconfig 里可能写下的正式团队。
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO：不注入 application-identifier，
# 否则没有描述文件时 ad-hoc 签不过。
# CODE_SIGN_ENTITLEMENTS 覆盖全部 target，避免 Widget / 屏保仍带受限制 entitlement。
run_with_failure_log "构建自用 Debug" xcodebuild \
  -scheme StarcatDirect \
  -configuration Debug \
  -sdk macosx \
  -arch arm64 \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_ENTITLEMENTS="$SELF_ENTITLEMENTS" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
  STARCAT_BUILD_VERSION_OVERRIDE="$BUILD_VERSION" \
  ENABLE_DEBUG_DYLIB=NO \
  build

echo "==> 校验自用构建产物..."
if [ ! -d "$WIDGET_EXTENSION_PATH" ]; then
  echo "ERROR: 自用构建产物缺少 StarcatDirectWidgets.appex。"
  exit 1
fi
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_BUNDLE_ID" != "$DIRECT_DEBUG_BUNDLE_ID" ]; then
  echo "ERROR: 自用 Debug bundle id 应为 ${DIRECT_DEBUG_BUNDLE_ID}，当前为 ${ACTUAL_BUNDLE_ID:-<missing>}。"
  exit 1
fi
ACTUAL_WIDGET_BUNDLE_ID=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleIdentifier" \
  "$WIDGET_EXTENSION_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_WIDGET_BUNDLE_ID" != "$DIRECT_DEBUG_WIDGET_BUNDLE_ID" ]; then
  echo "ERROR: 自用 Debug Widget bundle id 应为 ${DIRECT_DEBUG_WIDGET_BUNDLE_ID}，当前为 ${ACTUAL_WIDGET_BUNDLE_ID:-<missing>}。"
  exit 1
fi

ACTUAL_APP_BUILD=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
ACTUAL_WIDGET_BUILD=$(/usr/libexec/PlistBuddy \
  -c "Print :CFBundleVersion" \
  "$WIDGET_EXTENSION_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$ACTUAL_APP_BUILD" != "$BUILD_VERSION" ]; then
  echo "ERROR: 自用 Debug App build version 应为 ${BUILD_VERSION}，当前为 ${ACTUAL_APP_BUILD:-<missing>}。"
  exit 1
fi
if [ "$ACTUAL_WIDGET_BUILD" != "$BUILD_VERSION" ]; then
  echo "ERROR: 自用 Debug Widget build version 应为 ${BUILD_VERSION}，当前为 ${ACTUAL_WIDGET_BUILD:-<missing>}。"
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  echo "ERROR: Direct Info.plist 缺少 SUFeedURL。"
  exit 1
fi
LICENSE_API_ENV=$(/usr/libexec/PlistBuddy -c "Print :STARCAT_LICENSE_API_ENVIRONMENT" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
if [ "$LICENSE_API_ENV" != "test" ]; then
  echo "ERROR: 自用 Debug 必须连接测试 License API，当前 STARCAT_LICENSE_API_ENVIRONMENT=$LICENSE_API_ENV"
  exit 1
fi
if [ ! -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
  echo "ERROR: 自用构建产物缺少 Sparkle.framework。"
  exit 1
fi

echo "==> 固定 Sparkle 更新 UI 为英文..."
bash "$SCRIPT_DIR/strip-sparkle-non-english-localizations.sh" "$APP_PATH"
SPARKLE_FRAMEWORK_PATH="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_CURRENT_PATH="$SPARKLE_FRAMEWORK_PATH/Versions/Current"
SPARKLE_NESTED_CODE=(
  "$SPARKLE_CURRENT_PATH/XPCServices/Downloader.xpc"
  "$SPARKLE_CURRENT_PATH/XPCServices/Installer.xpc"
  "$SPARKLE_CURRENT_PATH/Updater.app"
  "$SPARKLE_CURRENT_PATH/Autoupdate"
)
for COMPONENT_PATH in "${SPARKLE_NESTED_CODE[@]}"; do
  if [ -e "$COMPONENT_PATH" ]; then
    codesign --force --sign "$DEBUG_SIGN_IDENTITY" --timestamp=none "$COMPONENT_PATH" >/dev/null
  fi
done
codesign --force --sign "$DEBUG_SIGN_IDENTITY" --timestamp=none "$SPARKLE_FRAMEWORK_PATH" >/dev/null

# 内嵌件先于主 App 换签。Widget 改挂空的自用 entitlements，去掉 App Group。
# .saver 是 MH_BUNDLE，不能写入 entitlement，只做 ad-hoc 签名。
codesign --force --sign "$DEBUG_SIGN_IDENTITY" --timestamp=none \
  --entitlements "$SELF_ENTITLEMENTS" "$WIDGET_EXTENSION_PATH" >/dev/null
if [ -d "$SAVER_PATH" ]; then
  codesign --force --sign "$DEBUG_SIGN_IDENTITY" --timestamp=none "$SAVER_PATH" >/dev/null
fi
codesign --force --sign "$DEBUG_SIGN_IDENTITY" --timestamp=none \
  --entitlements "$SELF_ENTITLEMENTS" "$APP_PATH" >/dev/null

if ! codesign --verify --deep --strict "$APP_PATH"; then
  echo "ERROR: 自用 App 签名校验失败。"
  exit 1
fi

FINAL_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
reject_restricted_entitlements "自用 App" "$FINAL_ENTITLEMENTS"
WIDGET_ENTITLEMENTS="$(codesign -d --entitlements :- "$WIDGET_EXTENSION_PATH" 2>/dev/null || true)"
reject_restricted_entitlements "自用 Widget" "$WIDGET_ENTITLEMENTS"
SIGNATURE_INFO="$(codesign -dv "$APP_PATH" 2>&1 || true)"
if ! grep -q "Signature=adhoc" <<<"$SIGNATURE_INFO"; then
  echo "ERROR: 自用构建不是 ad-hoc 签名。"
  echo "$SIGNATURE_INFO"
  exit 1
fi

echo "==> 签名摘要:"
printf '%s\n' "$SIGNATURE_INFO" | sed -n '1,12p'
echo "==> 当前模式: self"
echo "    build version: $BUILD_VERSION"
echo "    widget: 已嵌入，不注册（ad-hoc 无 App Group）"
echo "    license api: test"
echo "    local ai models: ~/Library/Application Support/com.starcat.app/LocalAI/v1/models"
echo "    preferences: ~/Library/Preferences/${DIRECT_DEBUG_BUNDLE_ID}.plist"
echo "    data: ~/Library/Application Support/com.starcat.app"
echo "    app: $APP_PATH"

if [ "$RUN_MODE" = "build-only" ]; then
  echo "==> 自用 Debug 构建与产物校验成功（build-only，未停止或启动应用）"
  exit 0
fi

echo "==> 启动自用 StarcatDirect..."
if ! open "$APP_PATH"; then
  echo "ERROR: LaunchServices 拒绝启动自用 StarcatDirect。"
  echo "       app: $APP_PATH"
  exit 1
fi

DIRECT_PID=""
for _ in {1..100}; do
  DIRECT_PID="$(pgrep -f -x "$APP_EXECUTABLE" | head -n 1 || true)"
  if [ -n "$DIRECT_PID" ]; then
    break
  fi
  sleep 0.1
done

if [ -z "$DIRECT_PID" ]; then
  echo "ERROR: LaunchServices 未建立目标自用 StarcatDirect 进程。"
  echo "       executable: $APP_EXECUTABLE"
  exit 1
fi

for _ in {1..20}; do
  if ! kill -0 "$DIRECT_PID" 2>/dev/null; then
    echo "ERROR: 自用 StarcatDirect 进程在启动后提前退出（PID: ${DIRECT_PID}）。"
    exit 1
  fi
  sleep 0.1
done

if ! DIRECT_PIDS="$(running_target_pids)"; then
  echo "ERROR: 无法执行启动后的单实例校验。"
  exit 1
fi
DIRECT_PID_COUNT="$(printf '%s\n' "$DIRECT_PIDS" | awk 'NF { count += 1 } END { print count + 0 }')"
if [ "$DIRECT_PID_COUNT" -ne 1 ] || [ "$DIRECT_PIDS" != "$DIRECT_PID" ]; then
  echo "ERROR: 自用 StarcatDirect 启动后不是唯一目标实例，拒绝报告成功。"
  echo "       expected PID: $DIRECT_PID"
  echo "       detected PID:"
  while IFS= read -r pid; do
    if [ -n "$pid" ]; then
      printf '       %s\n' "$pid"
    fi
  done <<<"$DIRECT_PIDS"
  exit 1
fi

echo "==> 自用 StarcatDirect 已稳定启动（PID: ${DIRECT_PID}，方式: LaunchServices，单实例）"
exit 0

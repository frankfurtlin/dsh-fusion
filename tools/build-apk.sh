#!/usr/bin/env bash
# 一键构建 dshgo-fusion 的 Android APK（工具链路径已内置，不依赖外部 env.sh）。
#
#   tools/build-apk.sh                                  # debug，产物同时拷到 dist/
#   tools/build-apk.sh --release
#   tools/build-apk.sh --target-platform android-arm64   # 单 ABI，最快（现为默认）
#   tools/build-apk.sh --all-abis                        # arm64 + x86_64 都构建（慢一倍）
#   tools/build-apk.sh --keep-daemon                     # 构建完保留 Gradle daemon
#   tools/build-apk.sh --target lib/main.dart
#   tools/build-apk.sh --pub-get-only                    # 只解析依赖
#   tools/build-apk.sh --detach                          # 丢 systemd 后台跑（agent 环境推荐）
#   tools/build-apk.sh [PROJECT_DIR]                     # 默认 /root/workspace/dshgo-fusion/app
#
# 日志：<repo>/dist/build-<mode>.log（同时打印到终端）
set -o pipefail

# ---------------------------------------------------------------- toolchain ---
JDK_HOME=/root/toolchain/jdk
ANDROID_SDK=/root/toolchain/android
FLUTTER_HOME=/root/toolchain/flutter

export JAVA_HOME="$JDK_HOME"
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export FLUTTER_ROOT="$FLUTTER_HOME"
export GRADLE_USER_HOME=/root/.gradle
export PATH="$JDK_HOME/bin:$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:$FLUTTER_HOME/bin:$PATH"
# 国内镜像：flutter 引擎产物 + pub 包（pub.dev 直连约 38KB/s）
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export HOME="${HOME:-/root}"
# 跳过 flutter 的 git 版本探测（github 不通时会卡 ~136s）
FLUTTER="command flutter --no-version-check"

# ------------------------------------------------------------------- flags ---
MODE=debug
# AGP 9.1.0 与 Flutter 3.50.0 要求的最低 9.1.1 只差一个 patch，先旁路这个校验拿基线，
# 等桥功能跑通后再统一升级 AGP/Gradle（见 docs/toolchain.md「版本矩阵」）。
SKIP_VALIDATION=1
TARGET=""
# 2026-11-20：默认只构建 arm64。实测两个 ABI 各跑一次 assembleRelease，
# 在本机 2 vCPU 上串行耗时 22 + 46 分钟；arm64 已覆盖真机，x86_64 只在模拟器用。
# 需要两个 ABI 时显式传 --all-abis。
TARGET_PLATFORM=android-arm64
PUB_GET_ONLY=0
DETACH=0
# --fast: skip R8 (minify + resource shrinking). Roughly 3-5x faster, APK ~30-50% bigger.
FAST=0
KEEP_DAEMON=0
PROJECT_ARG=""
SCRIPT_PATH="$(readlink -f "$0")"
SELF_DIR="$(dirname "$SCRIPT_PATH")"

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) MODE=debug ;;
    --release) MODE=release ;;
    --target) TARGET="$2"; shift ;;
    --target-platform) TARGET_PLATFORM="$2"; shift ;;
    --all-abis) TARGET_PLATFORM="" ;;
    --keep-daemon) KEEP_DAEMON=1 ;;
    --fast) FAST=1 ;;
    --skip-validation) SKIP_VALIDATION=1 ;;
    --strict-validation) SKIP_VALIDATION=0 ;;
    --pub-get-only) PUB_GET_ONLY=1 ;;
    --detach) DETACH=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) PROJECT_ARG="$1" ;;
  esac
  shift
done

PROJECT="${PROJECT_ARG:-/root/workspace/dshgo-fusion/app}"
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd || true)"
[ -n "$PROJECT" ] && [ -f "$PROJECT/pubspec.yaml" ] || {
  echo "error: no pubspec.yaml under '${PROJECT_ARG:-/root/workspace/dshgo-fusion/app}'" >&2; exit 2; }

REPO_DIR="$(dirname "$PROJECT")"
DIST="$REPO_DIR/dist"
mkdir -p "$DIST"
LOG="$DIST/build-$MODE.log"

if [ "$DETACH" = 1 ]; then
  UNIT="build-apk-$(date +%s)"
  systemctl reset-failed "$UNIT" 2>/dev/null
  fwd=( "--$MODE" "$PROJECT" )
  [ -n "$TARGET" ] && fwd+=( --target "$TARGET" )
  [ -n "$TARGET_PLATFORM" ] && fwd+=( --target-platform "$TARGET_PLATFORM" )
  [ "$SKIP_VALIDATION" = 0 ] && fwd+=( --strict-validation )
  # 2026-11-20：给构建单独一个内存上限，别让它把宿主 agent 拖进 D 状态。
  systemd-run --unit="$UNIT" --collect -p MemoryHigh=3G -p MemoryMax=4G \
    --setenv=HOME=/root --setenv=PUB_HOSTED_URL="$PUB_HOSTED_URL" \
    --setenv=FLUTTER_STORAGE_BASE_URL="$FLUTTER_STORAGE_BASE_URL" \
    "$SCRIPT_PATH" "${fwd[@]}" >/dev/null 2>&1 || { echo "systemd-run failed" >&2; exit 1; }
  echo "started unit: $UNIT"
  echo "follow:       journalctl -u $UNIT -f ; systemctl is-active $UNIT"
  echo "log:          $LOG"
  exit 0
fi

log() { echo "$@" | tee -a "$LOG"; }
: > "$LOG"
# 本次构建的时间戳，用来判断 APK 是不是这一轮产出的（旧文件不算）。
STAMP="$DIST/.build-start-$MODE"
rm -f "$STAMP"; : > "$STAMP"

log "=== build-apk.sh  mode=$MODE  $(date '+%F %T')"
log "project:  $PROJECT"
log "JDK:      $JAVA_HOME"
log "SDK:      $ANDROID_SDK"
log "flutter:  $FLUTTER_HOME"
log "pub:      $PUB_HOSTED_URL"
log ""

cd "$PROJECT" || exit 1

# 0. Gradle wrapper 发行版从国内镜像预置，避免卡在 services.gradle.org
if [ -f android/gradle/wrapper/gradle-wrapper.properties ] && [ -x "$SELF_DIR/seed-gradle-dist.sh" ]; then
  "$SELF_DIR/seed-gradle-dist.sh" "$PROJECT/android" 2>&1 | tail -3 | tee -a "$LOG"
  log ""
fi

# 1. flutter --version
log "=== 1/3 flutter --version ==="
$FLUTTER --version 2>&1 | tee -a "$LOG"
log ""

# 2. pub get
log "=== 2/3 flutter pub get ==="
$FLUTTER pub get 2>&1 | tail -30 | tee -a "$LOG"
PUBGET_RC=${PIPESTATUS[0]}
log "pub_get_rc=$PUBGET_RC"
if [ "$PUBGET_RC" != 0 ]; then log "pub get FAILED"; exit "$PUBGET_RC"; fi
if [ "$PUB_GET_ONLY" = 1 ]; then log "pub-get-only: stop."; exit 0; fi
log ""

# 3. build
build_args=( build apk "--$MODE" )
[ -n "$TARGET" ] && build_args+=( --target "$TARGET" )
[ -n "$TARGET_PLATFORM" ] && build_args+=( --target-platform "$TARGET_PLATFORM" )
# 旁路 Flutter 对 AGP/Gradle 最低版本的硬校验（默认开，--strict-validation 可关）
[ "$SKIP_VALIDATION" = 1 ] && build_args+=( --android-skip-build-dependency-validation )
[ "$FAST" = 1 ] && build_args+=( -PfastBuild )
log "=== 3/3 flutter ${build_args[*]} ==="
$FLUTTER "${build_args[@]}" 2>&1 | tee -a "$LOG" | tail -50
BUILD_RC=${PIPESTATUS[0]}

# Flutter 3.5x emits per-ABI outputs (app-arm64-debug.apk …) even without --split-per-abi and then
# reports "Gradle build failed to produce an .apk file" because it looked for app-<mode>.apk.
# 2026-11-20：判据改成「本轮构建之后产出的 APK」（对 STAMP 做 -newer），旧文件不再误判为成功。
APK_DIR="$PROJECT/build/app/outputs/flutter-apk"
FRESH_APKS=()
if [ -d "$APK_DIR" ]; then
  while IFS= read -r f; do FRESH_APKS+=( "$f" ); done < <(find "$APK_DIR" -maxdepth 1 -name '*.apk' -newer "$STAMP" 2>/dev/null)
fi

log ""
log "build_rc=$BUILD_RC  fresh_apks=${#FRESH_APKS[@]}  $(date '+%F %T')"

if [ "$BUILD_RC" != 0 ] && [ "${#FRESH_APKS[@]}" -gt 0 ]; then
  log "NOTE: flutter 返回非 0（per-ABI 输出路径的老问题），但本轮确实产出了 ${#FRESH_APKS[@]} 个 APK，按成功处理。"
fi

if [ "$BUILD_RC" = 0 ] || [ "${#FRESH_APKS[@]}" -gt 0 ]; then
  log "=== artifacts in $APK_DIR ==="
  ls -l "$APK_DIR" 2>/dev/null | tee -a "$LOG"
  for f in "${FRESH_APKS[@]}"; do
    cp -f "$f" "$DIST/" && log "copied -> $DIST/$(basename "$f") ($(stat -c%s "$f") bytes)"
  done
  RESULT=0
else
  log "build FAILED — full log: $LOG"
  RESULT=1
fi

# 2026-11-20：构建结束顺手停掉 Gradle daemon。它在 2C8G 上会常驻 3.5GB，
# 之前就是它把整机内存和 swap 占满，拖得 DSH 进 D 状态。
if [ "$KEEP_DAEMON" != 1 ] && [ -x "$PROJECT/android/gradlew" ]; then
  ( cd "$PROJECT/android" && ./gradlew --stop >/dev/null 2>&1 || true )
  log "gradle daemon stopped"
fi

rm -f "$STAMP"
exit "$RESULT"

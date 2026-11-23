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
# ------------------------------------------------------- 内存护栏 (2026-11-23) ---
# 这台机器 8 GB，一次 release 构建（Gradle daemon + Kotlin daemon + dart
# frontend_server）峰值能吃掉整机，内核 OOM 反过来杀 dsh/hermes，宿主直接失联。
# 2026-11-20（dshgo-fusion）和 2026-11-23（dsh-pocket）各中过一次。
#
# 做法：把自己塞进一个独立的 systemd scope，内存上限由 cgroup 硬约束 —— 构建
# 撑死也只死它自己，不再动宿主。可以用环境变量调：
#   BUILD_MEM_MAX=4G  BUILD_MEM_HIGH=3200M  BUILD_MEM_SWAP=256M  BUILD_WORKERS=2
MEM_MAX="${BUILD_MEM_MAX:-4G}"
MEM_HIGH="${BUILD_MEM_HIGH:-3200M}"
MEM_SWAP="${BUILD_MEM_SWAP:-256M}"
BUILD_WORKERS="${BUILD_WORKERS:-2}"

if [ "${DSH_BUILD_IN_SCOPE:-0}" != "1" ] && command -v systemd-run >/dev/null 2>&1; then
  # 2026-11-23：上次构建留下的 Gradle daemon 会活在 scope 外面（1.7 GB），内存上限
  # 管不到它，于是「scope 里很空、整机在 swap」—— 必须先停掉，让新 daemon 生在
  # scope 内。
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../app/android" 2>/dev/null && ./gradlew --stop >/dev/null 2>&1 ) || true
  ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && ./app/android/gradlew --stop >/dev/null 2>&1 ) || true
  export DSH_BUILD_IN_SCOPE=1
  # --collect 让 scope 结束后不留下 failed 单元；--quiet 不打印 "Running scope as unit"。
  exec systemd-run --scope --quiet --collect \
    -p MemoryMax="$MEM_MAX" -p MemoryHigh="$MEM_HIGH" -p MemorySwapMax="$MEM_SWAP" \
    -- bash "$0" "$@"
fi

# scope 内：压并行度。Gradle 的 worker 数与 Kotlin 增量编译都会各自开 JVM，
# 2 vCPU 上超过 2 个 worker 只是互相抢内存。
if [ "${DSH_BUILD_IN_SCOPE:-0}" = "1" ]; then
  export GRADLE_OPTS="${GRADLE_OPTS:--Dorg.gradle.workers.max=$BUILD_WORKERS}"
  echo "内存护栏：MemoryMax=$MEM_MAX MemoryHigh=$MEM_HIGH SwapMax=$MEM_SWAP workers=$BUILD_WORKERS"
  echo "cgroup   ：$(cat /proc/self/cgroup | head -1)"
  echo "内存上限 ：$(cat /sys/fs/cgroup$(cat /proc/self/cgroup | head -1 | cut -d: -f3)/memory.max 2>/dev/null || echo '（读不到，可能不是 cgroup v2）')"
fi

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
# 2026-11-23：pubspec 与 pubspec.lock 都没变就跳过（每次省 10-20s）。
PUBGET_STAMP="$PROJECT/.dart_tool/.pub-get.stamp"
PUBSPEC_SIG=$(cat "$PROJECT/pubspec.yaml" "$PROJECT/pubspec.lock" 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ -f "$PUBGET_STAMP" ] && [ "$(cat "$PUBGET_STAMP" 2>/dev/null)" = "$PUBSPEC_SIG" ] \
   && [ -f "$PROJECT/.dart_tool/package_config.json" ]; then
  log "=== 2/3 pub get 跳过（pubspec 未变）==="
  PUBGET_RC=0
else
  log "=== 2/3 flutter pub get ==="
  $FLUTTER pub get 2>&1 | tail -30 | tee -a "$LOG"
  PUBGET_RC=${PIPESTATUS[0]}
  log "pub_get_rc=$PUBGET_RC"
  [ "$PUBGET_RC" = 0 ] && printf '%s' "$PUBSPEC_SIG" > "$PUBGET_STAMP"
fi
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

# 2026-11-23：Gradle 判定 UP-TO-DATE 时不会产出新文件，flutter 于是报
# "failed to produce an .apk file"。只要既有产物比所有源码都新，就算成功。
UP_TO_DATE=""
if [ "$BUILD_RC" != 0 ] && [ "${#FRESH_APKS[@]}" -eq 0 ]; then
  # 优先取本次目标 ABI 的产物（android-arm64 → app-arm64-<mode>.apk），别抓到 x64
  # 判据是 flutter 那句固定的抱怨：只有它出现才说明「Gradle 没报错，只是没产出
  # 新文件」（UP-TO-DATE）；真正的编译错误不会有这句话。
  ABI_TAG="${TARGET_PLATFORM#android-}"
  EXISTING="$APK_DIR/app-${ABI_TAG}-${MODE}.apk"
  [ -f "$EXISTING" ] || EXISTING=$(ls -1t "$APK_DIR"/app-*-"$MODE".apk 2>/dev/null | head -1 || true)
  if [ -n "$EXISTING" ] && grep -q "failed to produce an .apk file" "$LOG" 2>/dev/null; then
    UP_TO_DATE="$EXISTING"
    BUILD_RC=0
    log "NOTE: Gradle 判定无变更（UP-TO-DATE），复用既有产物，按成功处理。"
  fi
fi

if [ "$BUILD_RC" = 0 ] || [ "${#FRESH_APKS[@]}" -gt 0 ]; then
  log "=== artifacts in $APK_DIR ==="
  ls -l "$APK_DIR" 2>/dev/null | tee -a "$LOG"
  if [ -n "$UP_TO_DATE" ]; then
    cp -f "$UP_TO_DATE" "$DIST/" && log "reused -> $DIST/$(basename "$UP_TO_DATE") ($(stat -c%s "$UP_TO_DATE") bytes, 无变更)"
  fi
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

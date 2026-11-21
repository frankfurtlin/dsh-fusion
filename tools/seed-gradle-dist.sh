#!/usr/bin/env bash
# Pre-seed a Gradle wrapper distribution from a China mirror so the wrapper never
# talks to services.gradle.org.
# usage: seed-gradle-dist.sh <project-android-dir>   (dir containing gradle/wrapper/gradle-wrapper.properties)
set -euo pipefail
ANDROID_DIR="${1:?usage: seed-gradle-dist.sh <android-dir>}"
PROPS="$ANDROID_DIR/gradle/wrapper/gradle-wrapper.properties"
[ -f "$PROPS" ] || { echo "no gradle-wrapper.properties in $ANDROID_DIR" >&2; exit 1; }

DIST_URL=$(grep -E '^distributionUrl=' "$PROPS" | sed 's/^distributionUrl=//; s/\\:/:/g')
DIST_NAME=${DIST_URL##*/}          # gradle-9.5.0-all.zip
DIST_BASE=${DIST_NAME%.zip}        # gradle-9.5.0-all
GRADLE_VER=$(echo "$DIST_NAME" | sed -E 's/^gradle-([0-9.]+)-.*/\1/')

GRADLE_USER_HOME="${GRADLE_USER_HOME:-/root/.gradle}"
export GRADLE_USER_HOME

# Gradle's PathAssembler: base36(md5(distributionUrl as bytes))
HASH=$(python3 - "$DIST_URL" <<'PY'
import hashlib, sys
n = int.from_bytes(hashlib.md5(sys.argv[1].encode()).digest(), 'big')
d = "0123456789abcdefghijklmnopqrstuvwxyz"; s = ""
while n: s = d[n % 36] + s; n //= 36
print(s or "0")
PY
)
DEST="$GRADLE_USER_HOME/wrapper/dists/$DIST_BASE/$HASH"
if [ -x "$DEST/$DIST_BASE/bin/gradle" ] && [ -f "$DEST/$DIST_NAME.ok" ]; then
  echo "gradle $GRADLE_VER already seeded at $DEST"; exit 0
fi

mkdir -p "$DEST"
ZIP="$DEST/$DIST_NAME"
if [ ! -s "$ZIP" ]; then
  echo "downloading $DIST_NAME (mirror)"
  curl -fL --retry 3 -o "$ZIP.part" "https://mirrors.cloud.tencent.com/gradle/$DIST_NAME" \
    || curl -fL --retry 3 -o "$ZIP.part" "https://mirrors.huaweicloud.com/gradle/$DIST_NAME"
  mv "$ZIP.part" "$ZIP"
fi
(cd "$DEST" && unzip -q -o "$ZIP")
touch "$DEST/$DIST_NAME.ok"
echo "seeded gradle $GRADLE_VER -> $DEST"

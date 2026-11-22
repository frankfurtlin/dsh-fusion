#!/usr/bin/env bash
# 本地构建 → 上传 COS → 打印直链。开发阶段默认发 debug 包。
#
#   tools/pocket/publish_local.sh            # debug
#   tools/pocket/publish_local.sh release    # release
#
# 前提：先跑过 tools/build-apk.sh（本脚本不会替你构建，避免误跑一小时）。
set -euo pipefail

MODE="${1:-debug}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APK="$REPO/app/build/app/outputs/flutter-apk/app-arm64-${MODE}.apk"

[ -f "$APK" ] || { echo "没有 $APK，先跑：tools/build-apk.sh $REPO/app${MODE:+$( [ "$MODE" = release ] && echo ' --release')}"; exit 1; }

VERSION=$(grep -m1 '^version:' "$REPO/app/pubspec.yaml" | awk '{print $2}')   # 1.0.2+3
GIT_SHA=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo local)
NAME="dsh-pocket-${VERSION/+/-}-arm64-${MODE}-${GIT_SHA}.apk"

MODE="$MODE" NAME="$NAME" APK="$APK" REPO="$REPO" python3 - <<'PY'
import hashlib, json, os, time

for path in (os.environ.get('COS_ENV_FILE', '/root/.secrets/cos.env'),):
    try:
        for line in open(path, encoding='utf-8'):
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError:
        raise SystemExit(f'缺少 {path}')

from qcloud_cos import CosConfig, CosS3Client

apk = os.environ['APK']
name = os.environ['NAME']
mode = os.environ['MODE']
size = os.path.getsize(apk)
h = hashlib.sha256()
with open(apk, 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
        h.update(chunk)
digest = h.hexdigest()

client = CosS3Client(CosConfig(Region=os.environ['COS_REGION'],
                               SecretId=os.environ['COS_SECRET_ID'],
                               SecretKey=os.environ['COS_SECRET_KEY']))
bucket = os.environ['COS_BUCKET']
eo = os.environ['COS_EO_DOMAIN'].rstrip('/')
key = f'pocket/apk/{name}'
t = time.time()
with open(apk, 'rb') as body:
    client.put_object(Bucket=bucket, Key=key, Body=body, ContentLength=str(size),
                      ContentType='application/vnd.android.package-archive',
                      CacheControl='public, max-age=31536000, immutable')

# 开发阶段的包不进 update.json（那是正式发布通道），只给直链。
print()
print(f'{mode} 包已上传（{size / 1048576:.1f} MB，{time.time() - t:.1f}s）')
print(f'  直链  {eo}/{key}')
print(f'  字节  {size}')
print(f'  sha256 {digest}')
print()
print('  手机装完可以核对字节数；对不上就是没下全。')
PY

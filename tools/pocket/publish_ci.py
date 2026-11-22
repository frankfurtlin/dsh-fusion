#!/usr/bin/env python3
"""CI 里运行：把构建好的 APK 传到 COS，并更新 `pocket/update.json`。

在 GitHub Actions 的 release 任务里跑，凭据来自仓库 secrets：
    COS_SECRET_ID / COS_SECRET_KEY / COS_BUCKET / COS_REGION / COS_EO_DOMAIN

发布布局（App 的 app/lib/update/update_config.dart 按这个取）：
    pocket/apk/dsh-pocket-<version>-arm64-<sha>.apk   ← 不可变缓存
    pocket/update.json                                ← 60 秒缓存，App 每次检查都取这个

清单格式跟 app/lib/update/release.dart 的 parseUpdateManifest 对齐（schema 1）。
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone, timedelta

TZ = timezone(timedelta(hours=8))
PREFIX = 'pocket'


def fail(msg: str) -> None:
    print(f'::error::{msg}')
    sys.exit(1)


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def release_asset(tag: str, apk: str, asset_name: str) -> str:
    """把 APK 传到 GitHub Release 并返回浏览器可下载的地址。"""
    import subprocess
    repo = os.environ.get('GITHUB_REPOSITORY', 'frankfurtlin/dsh-fusion')
    subprocess.run(['gh', 'release', 'view', tag, '-R', repo], capture_output=True)
    view = subprocess.run(['gh', 'release', 'view', tag, '-R', repo], capture_output=True, text=True)
    if view.returncode != 0:
        subprocess.run(['gh', 'release', 'create', tag, '-R', repo,
                        '--title', tag, '--notes', os.environ.get('COMMIT_TITLE', '') or f'DSH Pocket {tag}',
                        '--target', os.environ.get('GITHUB_SHA', 'main')],
                       check=True, capture_output=True)
    # `path#name`：不指定的话 gh 用本地文件名（app-arm64-release.apk），
    # 和清单里的带版本名字对不上，下载会 404。
    subprocess.run(['gh', 'release', 'upload', tag, f'{apk}#{asset_name}',
                    '--clobber', '-R', repo], check=True, capture_output=True)
    return f'https://github.com/{repo}/releases/download/{tag}/{asset_name}'


def main() -> int:
    app_dir = os.environ.get('APP_DIR', 'app')
    apk = os.path.join('out', 'app-arm64-release.apk')
    if not os.path.isfile(apk):
        fail(f'找不到 {apk}')

    version_line = re.search(r'^version:\s*(\S+)', open(os.path.join(app_dir, 'pubspec.yaml'), encoding='utf-8').read(), re.M)
    if not version_line:
        fail('pubspec.yaml 里没有 version')
    version = version_line.group(1)                     # 1.0.0+1

    sha = (os.environ.get('GITHUB_SHA') or '')[:7] or 'local'
    asset_name = f'dsh-pocket-{version.replace("+", "-")}-arm64-{sha}.apk'
    key = f'{PREFIX}/apk/{asset_name}'
    size = os.path.getsize(apk)
    digest = sha256(apk)

    from qcloud_cos import CosConfig, CosS3Client
    cfg = CosConfig(
        Region=os.environ['COS_REGION'],
        SecretId=os.environ['COS_SECRET_ID'],
        SecretKey=os.environ['COS_SECRET_KEY'],
    )
    client = CosS3Client(cfg)
    bucket = os.environ['COS_BUCKET']
    eo = os.environ['COS_EO_DOMAIN'].rstrip('/')

    # APK 不放 COS：GitHub runner → 广州 COS 的 66MB 上传实测会卡死（25 分钟未完成），
    # 而本机到 COS 是 86 MB/s —— 说明是跨云链路问题，不是 COS。改成把 APK 挂在
    # GitHub Release 上（同一云，快），App 侧用仓库里已有的加速镜像下载并校验 sha256；
    # COS/EO 只托管这份几 KB 的清单。
    tag = f'v{version.split("+")[0]}'
    asset_url = release_asset(tag, apk, asset_name)
    print(f'Release 资产：{asset_url}')

    manifest = {
        'schema': 1,
        'version': version,
        'tag': f'v{version.split("+")[0]}',
        'assets': {
            'arm64': {
                'name': asset_name,
                'url': asset_url,
                'size': size,
                'sha256': digest,
            },
        },
        'notes': os.environ.get('COMMIT_TITLE', ''),
        'publishedAt': datetime.now(TZ).isoformat(),
    }
    mp = 'out/update.json'
    with open(mp, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    with open(mp, 'rb') as body:
        client.put_object(
            Bucket=bucket, Key=f'{PREFIX}/update.json', Body=body,
            ContentType='application/json', CacheControl='public, max-age=60',
        )
    print(f'完成：{eo}/{PREFIX}/update.json')
    return 0


if __name__ == '__main__':
    sys.exit(main())

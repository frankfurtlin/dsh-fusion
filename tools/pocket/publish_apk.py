#!/usr/bin/env python3
"""把 CI 构建好的 APK 发布到 COS，并更新 `pocket/update.json`。

跑法（cron，或手动）：

    python3 tools/pocket/publish_apk.py            # 有新构建就发，没有就退出
    python3 tools/pocket/publish_apk.py --force    # 无视已发布记录，重发当前版本

发布物：
    COS  pocket/apk/dsh-pocket-<version>-arm64-<sha>.apk
    COS  pocket/update.json        ← App 的自动更新清单

为什么在这里发而不是在 GitHub Actions 里发：COS 的密钥只放在这台机器的
/root/.secrets/cos.env（0600），不进 GitHub Secrets，也不进任何仓库。

清单格式由 App 的 app/lib/update/release.dart 决定（schema 1）：
    {schema, version, tag, assets: {arm64: {name,url,size,sha256}}, notes, publishedAt}
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone, timedelta

REPO = 'frankfurtlin/dsh-pocket'
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATE = os.path.join(ROOT, 'tools', 'pocket', '.publish-state.json')
PUBSPEC = os.path.join(ROOT, 'app', 'pubspec.yaml')
COS_PREFIX = 'pocket'
TZ = timezone(timedelta(hours=8))


def env() -> dict:
    path = os.environ.get('COS_ENV_FILE', '/root/.secrets/cos.env')
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError:
        sys.exit(f'缺少 {path}（COS 凭据）')
    return os.environ


def cos_client(cfg):
    from qcloud_cos import CosConfig, CosS3Client
    return CosS3Client(CosConfig(
        Region=cfg['COS_REGION'],
        SecretId=cfg['COS_SECRET_ID'],
        SecretKey=cfg['COS_SECRET_KEY'],
    ))


def sh(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def app_version() -> str:
    text = open(PUBSPEC, encoding='utf-8').read()
    m = re.search(r'^version:\s*(\S+)', text, re.M)
    if not m:
        sys.exit('pubspec.yaml 里没有 version')
    return m.group(1)                      # 1.0.0+1


def latest_release_run() -> dict:
    out = sh('gh', 'run', 'list', '-R', REPO, '--workflow', 'android-apk.yml',
             '--limit', '20', '--json', 'databaseId,headSha,conclusion,createdAt,displayTitle')
    runs = json.loads(out)
    ok = [r for r in runs if r['conclusion'] == 'success']
    if not ok:
        sys.exit('没有成功的构建')
    return ok[0]


def load_state() -> dict:
    try:
        return json.load(open(STATE, encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(data: dict) -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=1)


def download(apk_run_id: int, workdir: str) -> str:
    sh('gh', 'run', 'download', str(apk_run_id), '-R', REPO, '-D', workdir)
    for base, _dirs, files in os.walk(workdir):
        for name in files:
            if name == 'app-arm64-release.apk':
                return os.path.join(base, name)
    sys.exit('产物里没有 app-arm64-release.apk')


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def put(client, bucket: str, key: str, path: str, content_type: str, cache: str) -> None:
    client.upload_file(
        Bucket=bucket, Key=key, LocalFilePath=path,
        ContentType=content_type, CacheControl=cache,
        EnableMD5=False, MAXThread=2,
    )


def main() -> int:
    cfg = env()
    version = app_version()
    run = latest_release_run()
    sha = run['headSha']
    state = load_state()
    force = '--force' in sys.argv

    if not force and state.get('headSha') == sha:
        print(f'已发布过 {sha[:7]}，跳过')
        return 0

    client = cos_client(cfg)
    bucket = cfg['COS_BUCKET']
    eo = cfg['COS_EO_DOMAIN'].rstrip('/')

    with tempfile.TemporaryDirectory() as tmp:
        apk = download(run['databaseId'], tmp)
        digest = sha256(apk)
        size = os.path.getsize(apk)
        asset_name = f'dsh-pocket-{version.replace("+", "-")}-arm64-{sha[:7]}.apk'
        key = f'{COS_PREFIX}/apk/{asset_name}'
        print(f'上传 {asset_name}（{size / 1048576:.1f} MB）…')
        put(client, bucket, key, apk, 'application/vnd.android.package-archive',
            'public, max-age=31536000, immutable')

        notes = run.get('displayTitle') or ''
        manifest = {
            'schema': 1,
            'version': version,
            'tag': f'v{version.split("+")[0]}',
            'assets': {
                'arm64': {
                    'name': asset_name,
                    'url': f'{eo}/{key}',
                    'size': size,
                    'sha256': digest,
                },
            },
            'notes': notes,
            'publishedAt': datetime.now(TZ).isoformat(),
        }
        mp = os.path.join(tmp, 'update.json')
        with open(mp, 'w', encoding='utf-8') as f:
            json.dump(manifest, f, ensure_ascii=False, indent=1)
        put(client, bucket, f'{COS_PREFIX}/update.json', mp, 'application/json',
            'public, max-age=60')

    save_state({
        'headSha': sha,
        'runId': run['databaseId'],
        'version': version,
        'key': key,
        'sha256': digest,
        'publishedAt': manifest['publishedAt'],
    })
    print(f'完成：{eo}/{COS_PREFIX}/update.json')
    return 0


if __name__ == '__main__':
    sys.exit(main())

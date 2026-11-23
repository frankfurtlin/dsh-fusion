#!/usr/bin/env python3
"""一条命令把「本地构建好的 release 包」发布到所有对外位置。

设计目标只有一个：**发布不靠记忆**。每次构建之后跑这一个脚本，下面这些东西同时
变成最新，任何一步失败就整体中止，不会出现「Release 更新了但清单没更新」这种
半发布状态：

    CHANGELOG.md        版本段必须存在，否则拒绝发布（Release 说明直接取自它）
    COS 上的 APK        pocket/apk/dsh-pocket-<ver>-<build>-arm64.apk（不可变缓存）
    GitHub Release      v<ver>，说明取 CHANGELOG 对应段
    COS 上的清单        pocket/update.json —— App 的自动检查读的就是它

清单里的下载地址指向 **COS**（国内直连快），GitHub Release 作为归档与来源记录。
APK 一旦上传就不再覆盖：路径里带版本号与 build 号，清单更新只是换一个指针。

用法：

    tools/build-apk.sh --release /root/workspace/dsh-pocket/app
    python3 tools/pocket/release.py                 # 发布
    python3 tools/pocket/release.py --dry-run       # 只检查与打印，不写任何远程
    python3 tools/pocket/release.py --skip-github   # 只发 COS + 清单

前置：`app/pubspec.yaml` 的 version 与 `app/lib/state/app_info.dart` 一致，
CHANGELOG.md 里有这个版本的段落，`/root/.secrets/cos.env` 可读，`gh` 已登录。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, 'app')
APK = os.path.join(APP, 'build/app/outputs/flutter-apk/app-arm64-release.apk')
APK_FALLBACK = os.path.join(ROOT, 'dist/app-arm64-release.apk')
CHANGELOG = os.path.join(ROOT, 'CHANGELOG.md')
PUBSPEC = os.path.join(APP, 'pubspec.yaml')
APP_INFO = os.path.join(APP, 'lib/state/app_info.dart')

COS_ENV = '/root/.secrets/cos.env'
PREFIX = 'pocket'
REPO = 'frankfurtlin/dsh-pocket'
SIGNER = 'CN=DSH Fusion'
TZ = timezone(timedelta(hours=8))


class Fail(Exception):
    """A precondition the release must not skip past."""


def sh(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, capture_output=True, text=True, cwd=ROOT)
    if check and result.returncode != 0:
        raise Fail(f'命令失败：{" ".join(args)}\n{result.stderr.strip()[:400]}')
    return result


def read_version() -> tuple[str, str, str]:
    """(完整版本 1.1.0+5, 名字 1.1.0, build 5)"""
    text = open(PUBSPEC, encoding='utf-8').read()
    match = re.search(r'^version:\s*(\S+)\s*$', text, re.M)
    if not match:
        raise Fail('pubspec.yaml 里找不到 version')
    full = match.group(1)
    name, _, build = full.partition('+')
    if not build:
        raise Fail(f'version 缺少 build 号：{full}')

    info = open(APP_INFO, encoding='utf-8').read()
    if f"defaultValue: '{full}'" not in info:
        raise Fail(
            f'app/lib/state/app_info.dart 的默认版本不是 {full}；'
            '两处必须一致，否则「关于」页和 APK 会打架'
        )
    return full, name, build


def changelog_section(name: str) -> str:
    """CHANGELOG.md 里 `## <name> · …` 那一段（不含标题行）。"""
    text = open(CHANGELOG, encoding='utf-8').read()
    lines = text.split('\n')
    start = None
    for index, line in enumerate(lines):
        if re.match(rf'^##\s+{re.escape(name)}(\s|·|$)', line):
            start = index
            break
    if start is None:
        raise Fail(f'CHANGELOG.md 里没有 {name} 的段落；先在 CHANGELOG 里写清变化再发布')
    body: list[str] = []
    for line in lines[start + 1:]:
        if line.startswith('## '):
            break
        body.append(line)
    section = '\n'.join(body).strip()
    if not section:
        raise Fail(f'CHANGELOG.md 的 {name} 段落是空的')
    return section


def verify_apk(path: str, name: str, build: str) -> None:
    if not os.path.exists(path):
        raise Fail(f'没有 release 包：{path}\n先跑 tools/build-apk.sh --release {APP}')

    build_tools = sorted(
        (os.path.join('/root/toolchain/android/build-tools', d)
         for d in os.listdir('/root/toolchain/android/build-tools')),
        key=lambda p: [int(x) for x in re.findall(r'\d+', os.path.basename(p)) or [0]],
    )
    if not build_tools:
        raise Fail('找不到 Android build-tools')
    aapt = os.path.join(build_tools[-1], 'aapt')
    apksigner = os.path.join(build_tools[-1], 'apksigner')
    java = '/root/toolchain/jdk/bin'

    env = {**os.environ, 'PATH': f'{java}:{os.environ.get("PATH", "")}'}
    badging = subprocess.run([aapt, 'dump', 'badging', path], capture_output=True, text=True, env=env).stdout
    if f"versionName='{name}'" not in badging:
        raise Fail(f'APK 的 versionName 不是 {name}：\n{badging.splitlines()[:1]}')
    if f"versionCode='{build}'" not in badging:
        raise Fail(f'APK 的 versionCode 不是 {build}（pubspec 的 +{build}）')
    if "native-code: 'arm64-v8a'" not in badging:
        raise Fail('这个包不是 arm64-v8a')

    certs = subprocess.run([apksigner, 'verify', '--print-certs', path],
                           capture_output=True, text=True, env=env)
    if certs.returncode != 0 or SIGNER not in certs.stdout:
        raise Fail(f'签名不对（应为 {SIGNER}）：\n{certs.stdout[:300]}{certs.stderr[:200]}')


def digest_of(path: str) -> tuple[str, int]:
    hasher = hashlib.sha256()
    with open(path, 'rb') as body:
        for chunk in iter(lambda: body.read(1 << 20), b''):
            hasher.update(chunk)
    return hasher.hexdigest(), os.path.getsize(path)


def cos_client():
    for line in open(COS_ENV, encoding='utf-8'):
        line = line.strip()
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            os.environ.setdefault(key.strip(), value.strip())
    from qcloud_cos import CosConfig, CosS3Client

    client = CosS3Client(CosConfig(Region=os.environ['COS_REGION'],
                                   SecretId=os.environ['COS_SECRET_ID'],
                                   SecretKey=os.environ['COS_SECRET_KEY']))
    return client, os.environ['COS_BUCKET'], os.environ['COS_EO_DOMAIN'].rstrip('/')


def upload_apk(client, bucket: str, eo: str, path: str, key: str) -> str:
    size = os.path.getsize(path)
    with open(path, 'rb') as body:
        client.put_object(
            Bucket=bucket, Key=key, Body=body, ContentLength=str(size),
            ContentType='application/vnd.android.package-archive',
            # 路径里带版本号，内容永不变：浏览器与 CDN 都可以长缓存。
            CacheControl='public, max-age=31536000, immutable',
        )
    return f'{eo}/{key}'


def github_release(name: str, apk: str, asset: str, notes: str, tag: str, dry: bool) -> str:
    # gh 用本地文件名当资产名，所以先复制成目标名字再传（改名的 CDN 路径会 404）。
    named = f'/tmp/{asset}'
    if not dry:
        import shutil
        shutil.copyfile(apk, named)
    apk = named if not dry else apk
    existing = sh('gh', 'release', 'view', tag, '-R', REPO, check=False)
    if existing.returncode != 0:
        if dry:
            return f'（dry-run）将创建 Release {tag}'
        sh('gh', 'release', 'create', tag, apk, '-R', REPO,
           '--title', f'DSH Pocket {name}', '--notes-file', '/tmp/dsh-release-notes.md',
           '--latest')
        return f'Release {tag} 已创建'

    if dry:
        return f'（dry-run）Release {tag} 已存在，将更新说明与资产'
    sh('gh', 'release', 'edit', tag, '-R', REPO,
       '--title', f'DSH Pocket {name}', '--notes-file', '/tmp/dsh-release-notes.md', '--latest')
    sh('gh', 'release', 'upload', tag, f'{apk}#{asset}', '-R', REPO, '--clobber')
    return f'Release {tag} 已更新'


def write_manifest(client, bucket: str, eo: str, full: str, name: str,
                   url: str, asset: str, size: int, digest: str, notes: str) -> str:
    manifest = {
        'schema': 1,
        'version': full,
        'tag': f'v{name}',
        'assets': {'arm64': {'name': asset, 'url': url, 'size': size, 'sha256': digest}},
        'notes': notes,
        'publishedAt': datetime.now(TZ).isoformat(timespec='seconds'),
    }
    body = json.dumps(manifest, ensure_ascii=False, indent=1).encode()
    client.put_object(Bucket=bucket, Key=f'{PREFIX}/update.json', Body=body,
                      ContentType='application/json', CacheControl='public, max-age=60')
    return f'{eo}/{PREFIX}/update.json'


def verify_public(url: str, expect_bytes: int | None = None) -> None:
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            status = response.status
            length = response.headers.get('Content-Length')
    except Exception as error:  # noqa: BLE001 — a failing check should read like one
        raise Fail(f'发布后无法访问 {url}：{error}') from error
    if status != 200:
        raise Fail(f'{url} 返回 {status}')
    if expect_bytes is not None and length and int(length) != expect_bytes:
        raise Fail(f'{url} 的大小是 {length}，应为 {expect_bytes}')


def main() -> int:
    parser = argparse.ArgumentParser(description='发布 DSH Pocket 的 release 包')
    parser.add_argument('--dry-run', action='store_true', help='只检查，不写任何远程')
    parser.add_argument('--skip-github', action='store_true', help='不创建/更新 GitHub Release')
    parser.add_argument('--skip-cos', action='store_true', help='只发 GitHub Release（清单写 GitHub 地址）')
    args = parser.parse_args()

    full, name, build = read_version()
    notes = changelog_section(name)
    apk = APK if os.path.exists(APK) else APK_FALLBACK
    print(f'版本      {full}')
    print(f'APK       {apk}')

    verify_apk(apk, name, build)
    digest, size = digest_of(apk)
    print(f'尺寸      {size / 1048576:.1f} MB')
    print(f'sha256    {digest}')
    print(f'说明      CHANGELOG 的 {name} 段（{len(notes.splitlines())} 行）')

    asset = f'dsh-pocket-{name}-{build}-arm64.apk'
    tag = f'v{name}'
    notes_file = '/tmp/dsh-release-notes.md'
    with open(notes_file, 'w', encoding='utf-8') as handle:
        handle.write(notes + '\n\n')
        handle.write('## Install\n\n```bash\n')
        handle.write(f'curl -LO https://static.frankfurtlin.top/{PREFIX}/apk/{asset}\n')
        handle.write('```\n\nAndroid 8.0+, arm64. In-place upgrade keeps settings.\n')

    client, bucket, eo = cos_client()
    url = f'{eo}/{PREFIX}/apk/{asset}'
    if not args.skip_cos:
        if args.dry_run:
            print(f'（dry-run）将上传 {PREFIX}/apk/{asset}')
        else:
            url = upload_apk(client, bucket, eo, apk, f'{PREFIX}/apk/{asset}')
            print(f'COS 上传  {url}')

    manifest_url = ''
    if not args.skip_cos:
        if args.dry_run:
            manifest_url = f'{eo}/{PREFIX}/update.json'
            print(f'（dry-run）将写清单 {manifest_url}')
        else:
            manifest_url = write_manifest(client, bucket, eo, full, name, url, asset, size, digest, notes)
            print(f'清单      {manifest_url}')

    if not args.skip_github:
        print(github_release(name, apk, asset, notes, tag, args.dry_run))

    if not args.dry_run:
        verify_public(url, size)
        print(f'校验      {url} 可访问')
        if manifest_url:
            with urllib.request.urlopen(manifest_url, timeout=30) as response:
                published = json.loads(response.read())
            if published.get('version') != full:
                raise Fail(f'清单里的版本是 {published.get("version")}，应为 {full}')
            print(f'校验      清单版本 {published["version"]} ✓')

    print('\n发布完成。')
    print(f'  安装包  {url}')
    print(f'  版本    {full}')
    print(f'  字节    {size}')
    print(f'  sha256  {digest}')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Fail as failure:
        print(f'\n中止：{failure}', file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""把 CNB 构建出的**未签名** APK 取回来、用 release 密钥签名、放进 dist/。

配合 `.cnb.yml`（方案 B）：CNB 只负责编译并把未签名包作为**提交附件**回传，
签名密钥和 COS 凭据都不进 CI。本脚本补上「下载 → 签名 → 校验」这一段，
之后直接跑 `release.py` 发布即可（它优先读 app/build/...，不存在时读
dist/app-arm64-release.apk）。

用法：

    python3 tools/pocket/cnb_fetch_sign.py                # 取 main 最新构建的附件
    python3 tools/pocket/cnb_fetch_sign.py --commit <sha> # 取指定提交
    python3 tools/pocket/cnb_fetch_sign.py --url <直链>   # 已有直链时跳过查找

为什么单独一个脚本而不是塞进 release.py：SCM 侧的产物获取方式（附件 / 制品库）
会变，构建侧（build-apk.sh）和发布侧（release.py）不该跟着变。
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APK_OUT = os.path.join(ROOT, 'dist/app-arm64-release.apk')
KEY_PROPS = os.path.join(ROOT, 'app/android/key.properties')
BUILD_TOOLS = '/root/toolchain/android/build-tools/36.0.0'
TOKEN_FILE = '/root/.secrets/cnb-token.env'

# CNB 提交附件的下载地址（2026-11-24 实测）
ATTACHMENT_URL = 'https://cnb.cool/frankslin/frankfurtlin/dsh-pocket/-/commit/{commit}/attachments/{name}'
REPO_SLUG = 'frankslin/frankfurtlin/dsh-pocket'
DEFAULT_ASSET = 'app-release-unsigned.apk'


class Fail(Exception):
    """不该被跳过的前置条件。"""


def sh(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise Fail(f'命令失败：{" ".join(args)}\n{result.stdout}\n{result.stderr}')
    return result


def key_props() -> dict[str, str]:
    """读 app/android/key.properties（本机 0600，不进仓库）。"""
    if not os.path.exists(KEY_PROPS):
        raise Fail(f'缺少 {KEY_PROPS}：签名需要 release 密钥')
    props: dict[str, str] = {}
    with open(KEY_PROPS, encoding='utf-8') as handle:
        for line in handle:
            line = line.strip()
            if line == '' or line.startswith('#') or '=' not in line:
                continue
            key, value = line.split('=', 1)
            props[key.strip()] = value.strip()
    missing = [k for k in ('storeFile', 'storePassword', 'keyAlias', 'keyPassword') if k not in props]
    if missing:
        raise Fail(f'key.properties 缺字段：{", ".join(missing)}')
    return props


def current_commit() -> str:
    return sh('git', '-C', ROOT, 'rev-parse', 'HEAD').stdout.strip()


def auth_token() -> str:
    """CNB 访问令牌；附件下载需要登录态。"""
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, encoding='utf-8') as handle:
            for line in handle:
                if line.startswith('CNB_TOKEN='):
                    return line.split('=', 1)[1].strip()
    raise Fail(
        f'缺少 {TOKEN_FILE}（内容一行 `CNB_TOKEN=<令牌>`）。\n'
        '令牌在 https://cnb.cool/profile/token 创建，勾 repo-code 只读即可。',
    )


def download(url: str, dest: str) -> int:
    """下载附件；带 CNB 令牌，避免落到登录页。"""
    request = urllib.request.Request(url, headers={'Authorization': f'Bearer {auth_token()}'})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if not data.startswith(b'PK'):
        snippet = data[:80].decode('utf-8', 'replace').replace('\n', ' ')
        raise Fail(f'下载到的不是 APK（前 80 字节：{snippet}）')
    with open(dest, 'wb') as handle:
        handle.write(data)
    return len(data)


def sign(unsigned: str, props: dict[str, str]) -> None:
    """用 release 密钥签名，并校验签名者与版本号。"""
    os.makedirs(os.path.dirname(APK_OUT), exist_ok=True)
    shutil.copyfile(unsigned, APK_OUT)
    apksigner = os.path.join(BUILD_TOOLS, 'apksigner')
    if not os.path.exists(apksigner):
        raise Fail(f'找不到 apksigner：{apksigner}')
    sh(
        apksigner, 'sign',
        '--ks', props['storeFile'],
        '--ks-key-alias', props['keyAlias'],
        '--ks-pass', f'pass:{props["storePassword"]}',
        '--key-pass', f'pass:{props["keyPassword"]}',
        '--v1-signing-enabled', 'true',
        '--v2-signing-enabled', 'true',
        '--v3-signing-enabled', 'true',
        APK_OUT,
    )


def verify(props: dict[str, str], version_name: str) -> str:
    """签名者必须是 CN=DSH Fusion，版本号必须与 pubspec 一致。"""
    apksigner = os.path.join(BUILD_TOOLS, 'apksigner')
    shown = sh(apksigner, 'verify', '--print-certs', APK_OUT).stdout
    if 'CN=DSH Fusion' not in shown:
        raise Fail(f'签名者不对：\n{shown}')
    aapt = os.path.join(BUILD_TOOLS, 'aapt2')
    badging = sh(aapt, 'dump', 'badging', APK_OUT).stdout
    found = re.search(r"versionName='([^']+)'", badging)
    if found is None:
        raise Fail('读不出版本号')
    if found.group(1) != version_name:
        raise Fail(f'APK 版本 {found.group(1)} 与 pubspec 的 {version_name} 不一致')
    return found.group(1)


def read_version() -> str:
    with open(os.path.join(ROOT, 'app/pubspec.yaml'), encoding='utf-8') as handle:
        for line in handle:
            if line.startswith('version:'):
                return line.split(':', 1)[1].strip().split('+')[0]
    raise Fail('pubspec.yaml 里没有 version')


def main() -> int:
    parser = argparse.ArgumentParser(description='取回 CNB 的未签名 APK 并签名')
    parser.add_argument('--commit', help='取这个提交的附件（默认 HEAD）')
    parser.add_argument('--url', help='直接给附件下载地址，跳过拼 URL')
    parser.add_argument('--asset', default=DEFAULT_ASSET, help=f'附件文件名（默认 {DEFAULT_ASSET}）')
    parser.add_argument('--unsigned', help='本地已有的未签名 APK，跳过下载')
    args = parser.parse_args()

    props = key_props()
    version = read_version()
    unsigned = args.unsigned or os.path.join('/tmp', 'dsh-pocket-unsigned.apk')

    if args.unsigned is None:
        commit = args.commit or current_commit()
        url = args.url or ATTACHMENT_URL.format(commit=commit, name=args.asset)
        print(f'提交      {commit}')
        print(f'下载      {url}')
        size = download(url, unsigned)
        print(f'尺寸      {size / 1048576:.1f} MB（未签名）')

    if not os.path.exists(unsigned):
        raise Fail(f'找不到未签名包：{unsigned}')

    sign(unsigned, props)
    print(f'签名      {APK_OUT}')
    shown = verify(props, version)
    digest = sh('sha256sum', APK_OUT).stdout.split()[0]
    size = os.path.getsize(APK_OUT)
    print(f'版本      {shown}')
    print(f'生成时间  {sh("date", "-r", APK_OUT, "+%Y-%m-%d %H:%M:%S").stdout.strip()}')
    print(f'sha256    {digest}')
    print(f'字节      {size}')
    print(f'\n下一步：python3 tools/pocket/release.py')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Fail as error:
        print(f'失败：{error}', file=sys.stderr)
        sys.exit(1)

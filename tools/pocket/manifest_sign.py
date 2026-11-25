#!/usr/bin/env python3
"""给 `update.json` 加 Ed25519 签名：改得了包、也要改得了清单才能骗过 App。

为什么需要它：sha256 与 APK 签名只保护「下载下来的安装包」，保护不了清单本身。
一份被换掉的清单可以把设备指向别的 APK，或者让版本比较读到旧数据（降级）。
App 侧（`app/lib/update/manifest_signature.dart`）内置公钥，对「去掉 signature 后的
规范化 JSON」验签；这里签的就是同一串字节。

规范化规则（两侧必须一致，改动要两边一起改）：
  json.dumps(payload 去掉 signature, sort_keys=True, separators=(',', ':'),
             ensure_ascii=False).encode('utf-8')
  —— 键按字典序、无空白、非 ASCII 原样输出；清单里只用整数，不用浮点。

私钥：`/root/.secrets/pocket-update-key.pem`（0600，只在本机，不进 CI/仓库）。
公钥：`PUBLIC_KEY_B64`（32 字节 raw），同时写死在 App 里。

用法：
    python3 manifest_sign.py --public-key          # 打印内置公钥（重新生成密钥时抄进 Dart）
    python3 manifest_sign.py --check update.json   # 校验一份清单
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile

#: 内置公钥（32 字节 raw base64），与 app/lib/update/manifest_signature.dart 一致。
PUBLIC_KEY_B64 = 'mbPz2/mRA9Cc+MknoWQvpyFed1ZQdAzNN1TAbh+Txx8='

KEY_FILE = os.environ.get('POCKET_UPDATE_KEY', '/root/.secrets/pocket-update-key.pem')

#: Ed25519 SubjectPublicKeyInfo 的固定前缀（RFC 8410），后面接 32 字节 raw key。
_SPKI_PREFIX = bytes.fromhex('302a300506032b6570032100')


class SignError(Exception):
    """清单签不出来/验不过：发布必须中止。"""


def canonical_bytes(payload: dict) -> bytes:
    """签什么就是什么：去掉 signature、键排序、无空白的 UTF-8。"""
    body = {key: value for key, value in payload.items() if key != 'signature'}
    return json.dumps(body, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def sign(payload: dict, key_file: str = KEY_FILE) -> dict:
    """返回带 `signature` 的新 payload（不改入参）。"""
    if not os.path.exists(key_file):
        raise SignError(f'缺少清单签名私钥：{key_file}')
    message = canonical_bytes(payload)
    with tempfile.NamedTemporaryFile(suffix='.json') as message_file:
        message_file.write(message)
        message_file.flush()
        run = subprocess.run(
            ['openssl', 'pkeyutl', '-sign', '-inkey', key_file, '-rawin', '-in', message_file.name],
            capture_output=True,
        )
    if run.returncode != 0:
        raise SignError(f'openssl 签名失败：{run.stderr.decode("utf-8", "replace")[:300]}')
    return {**payload, 'signature': base64.b64encode(run.stdout).decode('ascii')}


def verify(payload: dict, public_key_b64: str = PUBLIC_KEY_B64) -> bool:
    """验一份清单（自检/`--check` 用；App 里是同一套字节）。"""
    signature = payload.get('signature')
    if not isinstance(signature, str) or not signature:
        return False
    try:
        raw = base64.b64decode(signature, validate=True)
        public_key = base64.b64decode(public_key_b64, validate=True)
    except Exception:  # noqa: BLE001 — 坏的非 base64 就是验不过
        return False
    if len(raw) != 64 or len(public_key) != 32:
        return False
    with tempfile.TemporaryDirectory() as tmp:
        der = os.path.join(tmp, 'public.der')
        message = os.path.join(tmp, 'message.json')
        sig = os.path.join(tmp, 'signature.bin')
        with open(der, 'wb') as handle:
            handle.write(_SPKI_PREFIX + public_key)
        with open(message, 'wb') as handle:
            handle.write(canonical_bytes(payload))
        with open(sig, 'wb') as handle:
            handle.write(raw)
        run = subprocess.run(
            ['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', der, '-keyform', 'DER',
             '-rawin', '-in', message, '-sigfile', sig],
            capture_output=True,
        )
    return run.returncode == 0


def main() -> int:
    args = sys.argv[1:]
    if args == ['--public-key']:
        print(PUBLIC_KEY_B64)
        return 0
    if len(args) == 2 and args[0] == '--check':
        with open(args[1], encoding='utf-8') as handle:
            payload = json.load(handle)
        ok = verify(payload)
        print(f'{"签名有效" if ok else "签名无效"}：{args[1]}')
        return 0 if ok else 1
    print(__doc__.strip().splitlines()[-3].strip(), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())

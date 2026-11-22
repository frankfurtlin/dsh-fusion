#!/usr/bin/env python3
"""把本机收到的 App 操作日志打包上传到 COS，并清理过期文件。

跑法（cron，每 6 小时）：

    python3 tools/pocket/upload_logs.py

布局：
    本地  /root/logs/pocket/app/<device>-<YYYYMMDD>.jsonl     （接收端写入）
    COS   pocket/logs/<YYYY>/<MM>/<device>-<YYYYMMDD>.jsonl.gz （归档，供随时分析）

只上传"今天之前"的文件（正在写的当天文件不动），上传成功后删掉本地副本；
30 天前的本地残留直接删（COS 里已有）。
"""
from __future__ import annotations

import gzip
import os
import re
import shutil
import sys
import tempfile
from datetime import date, datetime, timedelta

LOCAL_DIR = os.environ.get('POCKET_LOG_DIR', '/root/logs/pocket/app')
PREFIX = 'pocket/logs'
KEEP_DAYS = 30


def load_cos():
    path = os.environ.get('COS_ENV_FILE', '/root/.secrets/cos.env')
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError:
        sys.exit(f'缺少 {path}')
    from qcloud_cos import CosConfig, CosS3Client
    return (
        CosS3Client(CosConfig(Region=os.environ['COS_REGION'],
                              SecretId=os.environ['COS_SECRET_ID'],
                              SecretKey=os.environ['COS_SECRET_KEY'])),
        os.environ['COS_BUCKET'],
    )


def day_of(name: str) -> date | None:
    m = re.search(r'-(\d{8})\.jsonl$', name)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), '%Y%m%d').date()
    except ValueError:
        return None


def main() -> int:
    if not os.path.isdir(LOCAL_DIR):
        print('没有日志目录，跳过')
        return 0
    files = sorted(f for f in os.listdir(LOCAL_DIR) if f.endswith('.jsonl'))
    if not files:
        print('没有待上传日志')
        return 0

    client, bucket = load_cos()
    today = date.today()
    uploaded = 0
    for name in files:
        day = day_of(name)
        if day is None:
            continue
        path = os.path.join(LOCAL_DIR, name)
        if (today - day).days > KEEP_DAYS:
            os.remove(path)                      # COS 里已有，本地过期
            continue
        if day >= today:
            continue                             # 当天可能还在写
        key = f'{PREFIX}/{day:%Y}/{day:%m}/{name}.gz'
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, name + '.gz')
            with open(path, 'rb') as src, gzip.open(out, 'wb') as dst:
                shutil.copyfileobj(src, dst)
            client.upload_file(
                Bucket=bucket, Key=key, LocalFilePath=out,
                ContentType='application/gzip',
                CacheControl='private, max-age=0',
                EnableMD5=False, MAXThread=2,
            )
        os.remove(path)                          # 已归档，删本地
        uploaded += 1
        print(f'archived {name} → {key}')
    print(f'完成：{uploaded} 个文件')
    return 0


if __name__ == '__main__':
    sys.exit(main())

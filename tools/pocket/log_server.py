#!/usr/bin/env python3
"""App 操作日志的接收端：127.0.0.1:8791，只对 Caddy 的 /pocket/log 暴露。

设计（贴合这台机器的约定）：
- 只监听回环，公网只能经 Caddy 进来；Caddy 侧再限制方法与大小。
- **第一件事就是鉴权**：Authorization: Bearer <token>，token 在
  /root/.secrets/pocket-log.env（0600），空则整个服务拒绝启动。
- 写入 /root/logs/pocket/app/<device>-<YYYYMMDD>.jsonl（一行一个事件），
  由 cron 定期打包上传到 COS（pocket/logs/…），本机保留 30 天。

请求体（应用侧决定，服务端只做校验与落盘）：
    {"device":"<id>","app":"<version>","events":[{"ts":"…","event":"…", …}, …]}
"""
from __future__ import annotations

import json
import os
import sys
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = '127.0.0.1'
PORT = int(os.environ.get('POCKET_LOG_PORT', '8791'))
OUT_DIR = os.environ.get('POCKET_LOG_DIR', '/root/logs/pocket/app')
SECRET_FILE = os.environ.get('POCKET_LOG_ENV', '/root/.secrets/pocket-log.env')
MAX_BODY = 256 * 1024          # 一次最多 256 KB
MAX_EVENTS = 500
TZ = timezone(timedelta(hours=8))

_lock = threading.Lock()


def load_token() -> str:
    token = os.environ.get('POCKET_LOG_TOKEN', '')
    if token:
        return token
    try:
        with open(SECRET_FILE, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line.startswith('POCKET_LOG_TOKEN='):
                    return line.split('=', 1)[1].strip()
    except FileNotFoundError:
        pass
    return ''


TOKEN = load_token()


class Handler(BaseHTTPRequestHandler):
    server_version = 'pocket-log/1'

    def log_message(self, fmt: str, *args) -> None:      # 不把每条请求写进 journal
        pass

    def _deny(self, code: int, message: str) -> None:
        body = json.dumps({'ok': False, 'error': message}).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:                            # noqa: N802
        if self.path.split('?')[0] != '/pocket/log':
            self._deny(404, 'not found')
            return
        if TOKEN and self.headers.get('Authorization', '') != f'Bearer {TOKEN}':
            self._deny(401, 'unauthorized')
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            self._deny(400, 'bad length')
            return
        if length <= 0 or length > MAX_BODY:
            self._deny(413, 'body too large')
            return

        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            self._deny(400, 'bad json')
            return
        if not isinstance(payload, dict):
            self._deny(400, 'bad payload')
            return
        events = payload.get('events')
        if not isinstance(events, list) or not events:
            self._deny(400, 'no events')
            return
        if len(events) > MAX_EVENTS:
            self._deny(413, 'too many events')
            return

        device = ''.join(ch for ch in str(payload.get('device', 'unknown')) if ch.isalnum() or ch in '-_')[:48] or 'unknown'
        app = str(payload.get('app', ''))[:32]
        now = datetime.now(TZ)
        path = os.path.join(OUT_DIR, f'{device}-{now:%Y%m%d}.jsonl')
        os.makedirs(OUT_DIR, exist_ok=True)

        with _lock, open(path, 'a', encoding='utf-8') as f:
            for event in events:
                if not isinstance(event, dict):
                    continue
                event = dict(event)
                event['device'] = device
                event['app'] = app
                event['receivedAt'] = now.isoformat()
                f.write(json.dumps(event, ensure_ascii=False) + '\n')

        body = json.dumps({'ok': True, 'accepted': len(events)}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    if not TOKEN:
        print(f'拒绝启动：{SECRET_FILE} 里没有 POCKET_LOG_TOKEN', file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f'pocket log 接收端 {HOST}:{PORT} → {OUT_DIR}')
    server.serve_forever()
    return 0


if __name__ == '__main__':
    sys.exit(main())

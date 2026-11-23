#!/usr/bin/env python3
"""兴趣摘要生成器：按用户画像挑内容，写一份 App 能拉的 digest.json。

跑法（cron/systemd timer，每 6 小时）：

    /root/scripts/pocket/digest.py

产出（原子写）：
    /srv/hermes/pocket/<secret>/digest.json     公网可读，路径不可枚举
    /srv/hermes/pocket/<secret>/index.html      ?（不做页面，只给 App 用）

设计约束（来自用户画像与项目约定）：
- 行情/投资类内容**不在这里现算**，只把既有日报管线的产物指过去；不猜、不补数据。
- 摘要里不放持仓、金额等隐私；只放公开内容与"为什么推荐"的标签。
- 任何一路数据源失败都跳过，不整体失败：宁可少几条，不可空着或报错。
- 零第三方 SDK：只用标准库 + 公开匿名接口。
"""
from __future__ import annotations

import json
import os
import random
import re
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser('~')
PUBLISH_ROOT = os.environ.get('POCKET_PUBLISH_ROOT', '/srv/hermes/pocket')
CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'interests.json')
UA = 'dsh-pocket-digest/1.0 (+https://github.com/frankfurtlin/dsh-pocket)'
TZ = timezone(timedelta(hours=8))

# 兴趣权重：来自画像（DSH 插件与前端 / agent 基建 / A 股资源板块 / AI 工程）
DEFAULT_INTERESTS = {
    'topics': [
        {'id': 'dsh', 'label': 'DSH / agent 基建', 'weight': 3,
         'keywords': ['dsh', 'deepseek harness', 'cordis', 'agent', 'mcp', 'tool use', 'coding agent']},
        {'id': 'ai-eng', 'label': 'AI 工程', 'weight': 2,
         'keywords': ['llm', 'model', 'openai', 'anthropic', 'gemini', 'claude', 'gpt', 'release',
                      'inference', 'server', '本地', '模型']},
        {'id': 'frontend', 'label': '前端体验', 'weight': 2,
         'keywords': ['ui', 'frontend', 'flutter', 'react', 'design', 'design system', 'css']},
        {'id': 'market', 'label': 'A 股与资源品', 'weight': 2,
         'keywords': ['a股', '上证', '有色', '黄金', '稀土', '铜', '铝', '锂', '行情', '财报', '央行']},
        {'id': 'oss', 'label': '开源与工具', 'weight': 1,
         'keywords': ['open source', 'github', 'cli', 'tool', 'self-host', 'homelab', '开源']},
    ],
    'max_items': 6,
    'ai_window_hours': 30,
    'arxiv_days': 3,
}


def now() -> datetime:
    return datetime.now(TZ)


def load_config() -> dict:
    cfg = json.loads(json.dumps(DEFAULT_INTERESTS))
    try:
        with open(CONFIG, encoding='utf-8') as f:
            override = json.load(f)
        cfg.update({k: v for k, v in override.items() if v})
    except FileNotFoundError:
        pass
    except Exception as exc:  # 配置坏了就用默认，别让整条流水线停
        print(f'[warn] interests.json 读取失败，用默认: {exc}', file=sys.stderr)
    return cfg


def fetch(url: str, timeout: int = 15) -> bytes | None:
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': '*/*'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
        print(f'[warn] {url} -> {exc}', file=sys.stderr)
        return None


_WORD_CACHE: dict[str, 're.Pattern[str]'] = {}


def _hits(keyword: str, text: str) -> bool:
    """关键词命中：短的按词边界匹配（避免 ui 命中 build、mcp 命中 xmcp2），
    中文直接子串（没有词边界概念）。"""
    kw = keyword.lower()
    if not kw:
        return False
    if any('\u4e00' <= ch <= '\u9fff' for ch in kw):
        return kw in text
    if len(kw) <= 4:
        pat = _WORD_CACHE.get(kw)
        if pat is None:
            pat = _WORD_CACHE[kw] = re.compile(r'(?<![a-z0-9])' + re.escape(kw) + r'(?![a-z0-9])')
        return pat.search(text) is not None
    return kw in text


def score(text: str, cfg: dict) -> tuple[int, list[str]]:
    low = (text or '').lower()
    total, tags = 0, []
    for topic in cfg['topics']:
        if any(_hits(kw, low) for kw in topic['keywords']):
            total += int(topic['weight'])
            tags.append(topic['label'])
    return total, tags


# ── 来源 1：AI HOT（公开匿名接口）────────────────────────────────────────────
def from_aihot(cfg: dict) -> list[dict]:
    """AI HOT 的 v1 公开接口（2026-11 从 /api/public/items 迁到 /api/v1/items，
    take → limit、since → window；window 只接受 24h / 7d）。"""
    window = '24h' if cfg['ai_window_hours'] <= 24 else '7d'
    url = f'https://aihot.news/api/v1/items?mode=selected&window={window}&limit=50'
    raw = fetch(url)
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    out = []
    for it in data.get('items') or []:
        title = (it.get('title') or it.get('originalTitle') or '').strip()
        summary = (it.get('summary') or '').strip()
        if not title:
            continue
        s, tags = score(f'{title} {summary}', cfg)
        if not s:
            continue
        links = it.get('links') or {}
        link = ''
        if isinstance(links, dict):
            link = links.get('original') or links.get('aihot') or ''
        elif isinstance(links, list) and links:
            first = links[0]
            link = first.get('url') if isinstance(first, dict) else str(first)
        if not link:
            continue                      # 点了没地方去的条目不发
        source = it.get('source')
        out.append({
            'id': f"aihot:{it.get('id') or title}",
            'title': title,
            'summary': summary[:280],
            'source': (source or {}).get('name') if isinstance(source, dict) else 'AI HOT',
            'url': link,
            'publishedAt': it.get('publishedAt') or '',
            'tags': tags,
            'score': s,
        })
    return out


# ── 来源 2：arXiv（按关键词检索最近的论文）────────────────────────────────────
def from_arxiv(cfg: dict) -> list[dict]:
    terms = ['large language model agent', 'coding agent', 'llm agent tool use']
    query = ' OR '.join(f'all:"{t}"' for t in terms)
    url = ('http://export.arxiv.org/api/query?search_query='
           f'{urllib.parse.quote(query)}&sortBy=submittedDate&sortOrder=descending&max_results=20')
    raw = fetch(url, timeout=20)
    if not raw:
        return []
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return []
    ns = {'a': 'http://www.w3.org/2005/Atom'}
    cutoff = now() - timedelta(days=cfg['arxiv_days'])
    out = []
    for entry in root.findall('a:entry', ns):
        title = ' '.join((entry.findtext('a:title', '', ns) or '').split())
        summary = ' '.join((entry.findtext('a:summary', '', ns) or '').split())
        link = entry.findtext('a:id', '', ns) or ''
        published = entry.findtext('a:published', '', ns) or ''
        if not title:
            continue
        try:
            when = datetime.fromisoformat(published.replace('Z', '+00:00'))
            if when < cutoff:
                continue
        except ValueError:
            pass
        s, tags = score(f'{title} {summary}', cfg)
        if not s:
            continue
        out.append({
            'id': f'arxiv:{link.rsplit("/", 1)[-1]}',
            'title': title,
            'summary': summary[:280],
            'source': 'arXiv',
            'url': link,
            'publishedAt': published,
            'tags': tags,
            'score': s + 1,   # 论文更稀缺，同等命中时略优先
        })
    return out


# ── 来源 3：既有日报管线（只指过去，不重算行情）──────────────────────────────
def from_market(cfg: dict) -> list[dict]:
    """指向用户自己的每日市场报告，不在这里算任何行情数字。"""
    candidates = sorted(
        (p for p in _glob_reports() if p),
        key=os.path.getmtime, reverse=True)
    if not candidates:
        return []
    latest = candidates[0]
    age_h = (time.time() - os.path.getmtime(latest)) / 3600
    if age_h > 36:
        return []
    return [{
        'id': f'market:{os.path.basename(latest)}',
        'title': '今日市场报告已更新',
        'summary': f'{os.path.basename(latest)}（{datetime.fromtimestamp(os.path.getmtime(latest), TZ):%m-%d %H:%M}）',
        'source': '每日市场报告',
        'url': 'https://hermes.frankfurtlin.top/kb-public/',
        'publishedAt': datetime.fromtimestamp(os.path.getmtime(latest), TZ).isoformat(),
        'tags': ['A 股与资源品'],
        'score': 2,
    }]


def _glob_reports():
    import glob
    for pattern in ('/root/workspace/market-report/data/reports/*.html',
                    '/root/workspace/kb-data/**/*.html'):
        yield from glob.glob(pattern, recursive=True)


def main() -> int:
    cfg = load_config()
    items: list[dict] = []
    for fn in (from_aihot, from_arxiv, from_market):
        try:
            items.extend(fn(cfg))
        except Exception as exc:                       # 单源出错不影响整体
            print(f'[warn] {fn.__name__} 失败: {exc}', file=sys.stderr)

    seen, unique = set(), []
    for it in sorted(items, key=lambda i: (-i['score'], i.get('publishedAt') or '')):
        if it['id'] in seen:
            continue
        seen.add(it['id'])
        unique.append(it)
    per_source: dict[str, int] = {}
    capped = []
    for it in unique:
        key = it['source'] if it['source'] in ('arXiv',) else 'news'
        if per_source.get(key, 0) >= (2 if key == 'arXiv' else 4):
            continue
        per_source[key] = per_source.get(key, 0) + 1
        capped.append(it)
    unique = capped[:cfg['max_items']]

    secret_path = _secret_dir()
    payload = {
        'schema': 1,
        'generatedAt': now().isoformat(),
        'items': unique,
        'topics': [t['label'] for t in cfg['topics']],
    }
    target = os.path.join(PUBLISH_ROOT, secret_path, 'digest.json')
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    os.replace(tmp, target)
    os.chmod(target, 0o644)
    print(f'{len(unique)} 条 → {target}')
    return 0


def _secret_dir() -> str:
    """不可枚举的路径：只在本地配置里出现一次，公网无法猜。"""
    cfg_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'publish.json')
    try:
        with open(cfg_path, encoding='utf-8') as f:
            return json.load(f)['path']
    except (FileNotFoundError, KeyError, json.JSONDecodeError):
        path = ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(20))
        with open(cfg_path, 'w', encoding='utf-8') as f:
            json.dump({'path': path}, f)
        os.chmod(cfg_path, 0o600)
        return path


if __name__ == '__main__':
    sys.exit(main())

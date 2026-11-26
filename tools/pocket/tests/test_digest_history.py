#!/usr/bin/env python3
"""`digest.py` 历史留档的回归测试（标准库 unittest，不需要网络）。

    python3 tools/pocket/tests/test_digest_history.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DIGEST = os.path.join(os.path.dirname(HERE), 'digest.py')

spec = importlib.util.spec_from_file_location('pocket_digest', DIGEST)
digest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(digest)

TZ = timezone(timedelta(hours=8))


def payload(at: str, titles: list[str]) -> dict:
    return {
        'schema': 1,
        'generatedAt': at,
        'topics': ['t'],
        'items': [{'id': f'{at}-{i}', 'title': title, 'url': 'https://x'} for i, title in enumerate(titles)],
    }


class HistoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.base = self._tmp.name

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def index(self) -> dict:
        with open(os.path.join(self.base, 'history/index.json'), encoding='utf-8') as handle:
            return json.load(handle)

    def test_batches_are_listed_newest_first_with_title_previews(self) -> None:
        digest.write_history(self.base, payload('2026-11-25T09:45:00+08:00', ['a', 'b']))
        digest.write_history(self.base, payload('2026-11-26T09:45:00+08:00', ['c', 'd', 'e']))
        index = self.index()
        self.assertEqual([b['id'] for b in index['batches']], ['20261126-0945', '20261125-0945'])
        self.assertEqual([b['count'] for b in index['batches']], [3, 2])
        self.assertEqual(index['batches'][0]['titles'], ['c', 'd', 'e'])
        for batch_id in ('20261125-0945', '20261126-0945'):
            with open(os.path.join(self.base, 'history', f'{batch_id}.json'), encoding='utf-8') as handle:
                stored = json.load(handle)
            self.assertEqual(stored['items'][0]['title'], 'a' if batch_id.startswith('20261125') else 'c')

    def test_rerunning_within_the_same_minute_replaces_that_batch(self) -> None:
        digest.write_history(self.base, payload('2026-11-26T09:45:00+08:00', ['a', 'b']))
        digest.write_history(self.base, payload('2026-11-26T09:45:00+08:00', ['only one']))
        index = self.index()
        self.assertEqual([(b['id'], b['count']) for b in index['batches']], [('20261126-0945', 1)])

    def test_batches_older_than_the_keep_window_are_removed_from_disk(self) -> None:
        old = (datetime.now(TZ) - timedelta(days=digest.HISTORY_KEEP_DAYS + 5)).isoformat()
        digest.write_history(self.base, payload('2026-11-26T09:45:00+08:00', ['fresh']))
        digest.write_history(self.base, payload(old, ['stale']))
        ids = [b['id'] for b in self.index()['batches']]
        self.assertNotIn(old[:16].replace('-', '').replace('T', '-').replace(':', ''), ids)
        files = os.listdir(os.path.join(self.base, 'history'))
        self.assertNotIn(old[:16].replace('-', '').replace('T', '-').replace(':', '') + '.json', files)

    def test_index_is_capped(self) -> None:
        digest.HISTORY_MAX_BATCHES = 3
        try:
            for hour in range(6):
                digest.write_history(self.base, payload(f'2026-11-26T0{hour}:45:00+08:00', [f'i{hour}']))
            self.assertEqual(len(self.index()['batches']), 3)
        finally:
            digest.HISTORY_MAX_BATCHES = 240

    def test_a_corrupt_index_is_rebuilt_instead_of_failing(self) -> None:
        os.makedirs(os.path.join(self.base, 'history'))
        with open(os.path.join(self.base, 'history/index.json'), 'w', encoding='utf-8') as handle:
            handle.write('{not json')
        digest.write_history(self.base, payload('2026-11-26T09:45:00+08:00', ['x']))
        self.assertEqual([b['id'] for b in self.index()['batches']], ['20261126-0945'])


if __name__ == '__main__':
    sys.exit(unittest.main(verbosity=2))

// 推送历史的解析：目录推导、批次清单（排序/坏条目）、单批条目。
// 真实数据来自服务端 history/index.json 与 history/<id>.json（见 tools/pocket/digest.py）。

import 'dart:convert';

import 'package:dsh_app/digest/digest_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _index = '''
{
 "schema": 1,
 "generatedAt": "2026-11-26T10:12:00+08:00",
 "batches": [
  {"id": "20261125-2159", "at": "2026-11-25T21:59:00+08:00", "count": 2, "titles": ["旧的一条", "旧的另一条"]},
  {"id": "20261126-0959", "at": "2026-11-26T09:59:00+08:00", "count": 6, "titles": ["To Answer", "When Answering"]},
  {"id": "", "at": "2026-11-26T11:00:00+08:00", "count": 1, "titles": []},
  "garbage"
 ]
}
''';

const _batch = '''
{
 "schema": 1,
 "generatedAt": "2026-11-26T09:59:00+08:00",
 "items": [
  {"id": "a", "title": "第一条", "summary": "摘要", "source": "arXiv", "url": "https://x/1", "publishedAt": "2026-11-25T10:00:00Z", "tags": ["AI"]},
  {"id": "b", "title": "", "url": "https://x/2"},
  {"id": "c", "title": "第三条", "source": "X", "url": "", "tags": []}
 ]
}
''';

void main() {
  test('the history directory comes from the digest URL', () {
    expect(digestDirectoryOf('https://h/pocket/secret/digest.json'), 'https://h/pocket/secret/');
    expect(digestDirectoryOf('https://h/api/update.json'), 'https://h/api/');
    expect(digestDirectoryOf(null), isNull);
    expect(digestDirectoryOf(''), isNull);
    expect(digestDirectoryOf('digest.json'), isNull);
  });

  test('the index sorts newest first and skips broken rows', () {
    final index = DigestHistoryIndex.parse(_index);
    expect(index.batches.map((b) => b.id), ['20261126-0959', '20261125-2159']);
    expect(index.batches.first.count, 6);
    expect(index.batches.first.titles.first, 'To Answer');
    expect(index.batches.first.localTime, isNotNull);
  });

  test('an empty or broken index reads as no history, not an error page', () {
    expect(DigestHistoryIndex.parse('').isEmpty, isTrue);
    expect(DigestHistoryIndex.parse('{not json').isEmpty, isTrue);
    expect(DigestHistoryIndex.parse('[]').isEmpty, isTrue);
    expect(DigestHistoryIndex.parse('{"batches": {}}').isEmpty, isTrue);
  });

  test('one batch keeps only rows with a title', () {
    final root = jsonDecode(_batch) as Map<String, Object?>;
    final items = [for (final raw in (root['items'] as List)) ?DigestItem.fromJson(raw)];
    expect(items.map((i) => i.id), ['a', 'c']);
    expect(items.first.tags, ['AI']);
    expect(items.last.url, isEmpty);
  });
}

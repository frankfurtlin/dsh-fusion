// 哪些清单源必须验签：只有官方发布源（<updateDownloadOrigin>/update.json）。
// 自定义 feed / 内测通道是构建者自己的来源，有签名才验；GitHub API 另一套格式。

import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the official feed requires a signature', () {
    final sources = buildUpdateSources();
    final feed = sources.metadataEndpoints().firstWhere((e) => e.id == 'feed');
    expect(feed.url, UpdateSources.officialFeed);
    expect(feed.requireSignature, isTrue);
    // GitHub API 不在签名范围内。
    final api = sources.metadataEndpoints().firstWhere((e) => e.kind == EndpointKind.githubApi);
    expect(api.requireSignature, isFalse);
  });

  test('a build-time feed override is the builder’s own source', () {
    final sources = buildUpdateSources(feed: 'https://example.com/update.json');
    final feed = sources.metadataEndpoints().firstWhere((e) => e.id == 'feed');
    expect(feed.requireSignature, isFalse);
  });

  test('with no mirror origin there is no feed to ask', () {
    final sources = buildUpdateSources(mirror: '', feed: '');
    expect(sources.feed, isNull);
  });
}

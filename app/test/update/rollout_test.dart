// 灰度分桶：同一台设备同一个版本永远落在同一个桶里，且桶号覆盖 0–99。

import 'package:dsh_app/state/update_state.dart' show rolloutBucketFor;
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bucket is stable for a device and a version', () {
    final version = AppVersion.tryParse('1.1.6+11')!;
    final first = rolloutBucketFor('dev-abc123', version);
    expect(first, inInclusiveRange(0, 99));
    expect(rolloutBucketFor('dev-abc123', version), first);
    // 换版本就是另一批：1.1.6 抽到的人不决定 1.1.7 抽到谁。
    expect(rolloutBucketFor('dev-abc123', version), first);
    expect(rolloutBucketFor('dev-abc123', AppVersion.tryParse('1.1.7+12')!), isNot(isNegative));
  });

  test('different devices spread over the range', () {
    final version = AppVersion.tryParse('1.1.6+11')!;
    final buckets = {for (var i = 0; i < 400; i++) rolloutBucketFor('dev-$i', version)};
    // 400 个设备至少要落到 40 个不同的桶，否则分桶没在工作。
    expect(buckets.length, greaterThan(40));
    expect(buckets.every((b) => b >= 0 && b < 100), isTrue);
  });

  test('no device id counts as the first bucket (never miss a device)', () {
    expect(rolloutBucketFor(null, AppVersion.tryParse('1.1.6+11')!), 0);
    expect(rolloutBucketFor('', AppVersion.tryParse('1.1.6+11')!), 0);
  });

  test('a manifest rollout is normalised, absent means everyone', () {
    ReleaseInfo manifest(int? rollout) => ReleaseInfo(
      version: AppVersion.tryParse('1.1.6+11')!,
      tag: 'v1.1.6',
      apks: const {},
      rollout: rollout,
    );
    expect(manifest(null).rolloutPercent, 100);
    expect(manifest(20).rolloutPercent, 20);
    expect(manifest(0).rolloutPercent, 0);
    expect(manifest(140).rolloutPercent, 100);
    // 缓存下来的清单照旧能读（老版本写的没有 rollout）。
    final parsed = parseUpdateManifest({'schema': 1, 'version': '1.1.6+11', 'tag': 'v1.1.6'});
    expect(parsed.rolloutPercent, 100);
  });
}

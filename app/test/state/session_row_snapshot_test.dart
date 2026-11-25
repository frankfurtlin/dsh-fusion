// 会话列表落盘快照：冷启动第一眼的那份数据。
// 关心的是「同一台 Host 能读回来」「别的 Host 不串」「坏文件当没有」。

import 'dart:io';

import 'package:dsh_app/state/hosts_state.dart' show HostRef;
import 'package:dsh_app/state/session_row_snapshot.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary row(String id, {String? title, bool running = false, String? origin}) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime.fromMillisecondsSinceEpoch(1795600000000),
  running: running,
  blank: false,
  agentAvailable: true,
  origin: origin,
  projections: SessionProjections(-1, {'title': title}),
  projectionsKind: 'sequenced',
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session-snapshot');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('rows come back for the same host, and only for it', () async {
    const host = HostRef.ssh('ssh-1');
    await SessionRowSnapshot(directory: () async => dir).save(host, [
      row('s1', title: '会话一'),
      row('s2', running: true),
    ]);

    // 新实例 = 冷启动，只能从文件里读。
    final cold = SessionRowSnapshot(directory: () async => dir);
    final rows = await cold.rowsFor(host);
    expect(rows.map((r) => r.sessionId), ['s1', 's2']);
    expect(rows.first.title, '会话一');
    expect(rows.last.running, isTrue);
    // 标题是快照里的，时间戳原样回来。
    expect(rows.first.updatedAt.millisecondsSinceEpoch, 1795600000000);

    expect(await cold.rowsFor(const HostRef.ssh('ssh-2')), isEmpty);
    expect(await cold.rowsFor(HostRef.local), isEmpty);
  });

  test('subagent rows are not cached (the drawer never shows them)', () async {
    const host = HostRef.local;
    await SessionRowSnapshot(directory: () async => dir).save(host, [
      row('parent', title: '主线'),
      row('child', title: '子会话', origin: 'subagent'),
    ]);
    final rows = await SessionRowSnapshot(directory: () async => dir).rowsFor(host);
    expect(rows.map((r) => r.sessionId), ['parent']);
  });

  test('a damaged file reads as no rows', () async {
    const host = HostRef.ssh('ssh-1');
    final file = File('${dir.path}/session_list/ssh-ssh-1.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('{not json');

    final rows = await SessionRowSnapshot(directory: () async => dir).rowsFor(host);
    expect(rows, isEmpty);
    // 读失败不影响下一次写。
    final store = SessionRowSnapshot(directory: () async => dir);
    await store.save(host, [row('fresh', title: '新')]);
    expect((await SessionRowSnapshot(directory: () async => dir).rowsFor(host)).single.sessionId, 'fresh');
  });
}

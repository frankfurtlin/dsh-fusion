// 会话列表的落盘快照：冷启动先把上次的行画出来，网络读完再替换。
//
// 为什么要有它：进 App 时唯一的大等待是 `session/list`（187 个会话 ≈ 670 KB
// JSON / 295 KB gzip，手机上要 2 秒出头；实测 1.1.4 的账本 session_list
// 2381 ms）。这台 Host 的接口不分页、也不认 maxMessages（120/200/300/500 返回
// 完全一样），客户端没法把这一份变小，能做的只有别让它挡住第一眼。
//
// 只存抽屉要显示的那几个字段（标题、时间、状态），不存 raw 行：不把会话内容
// （turnOutline 里的提问/回答摘录）落到磁盘上。每台 Host 一个文件，最多
// [_maxRows] 行；文件坏了当作没有。
//
// 什么时候读：SessionsController.build() 里在读网络之前 await 一次（几毫秒），
// 有快照就立刻 state=AsyncData，随后的真列表照旧盖上去。写：每次列表读成功。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'hosts_state.dart' show HostRef;

/// 一份快照里最多留多少行（抽屉只用得到前几十行）。
const _maxRows = 400;

/// 文件总大小上限：超过就不写，避免把磁盘写满。
const _maxBytes = 512 * 1024;

class SessionRowSnapshot {
  SessionRowSnapshot({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  final Map<String, List<SessionSummary>> _rows = {};
  final Set<String> _loaded = {};

  static String _key(HostRef host) => '${host.kind.name}-${host.id}';

  /// 这台 Host 上次的列表；没有（或还没读过）时是空列表。
  Future<List<SessionSummary>> rowsFor(HostRef host) async {
    final key = _key(host);
    if (_loaded.add(key)) {
      _rows[key] = await _read(key);
    }
    return _rows[key] ?? const [];
  }

  /// 列表读成功后写下这一次的行（去掉子会话：抽屉不显示它们）。
  Future<void> save(HostRef host, Iterable<SessionSummary> rows) async {
    final kept = [
      for (final row in rows)
        if (!row.isSubagent && row.sessionId.isNotEmpty) row,
    ];
    if (kept.isEmpty) return;
    if (kept.length > _maxRows) kept.removeRange(_maxRows, kept.length);
    _rows[_key(host)] = kept;
    _loaded.add(_key(host));
    try {
      final directory = await _directory();
      final file = await _file(directory, _key(host));
      final encoded = jsonEncode({
        'version': 1,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'rows': [for (final row in kept) _toJson(row)],
      });
      if (encoded.length > _maxBytes) return;
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // 写不下来就只在内存里有效：不值得为缓存弄坏列表。
    }
  }

  /// 测试用：丢掉内存里的那一份。
  void clear() {
    _rows.clear();
    _loaded.clear();
  }

  Future<File> _file(Directory directory, String key) async =>
      File('${directory.path}/session_list/$key.json');

  Future<List<SessionSummary>> _read(String key) async {
    try {
      final directory = await _directory();
      final file = await _file(directory, key);
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != 1) return const [];
      final rows = decoded['rows'];
      if (rows is! List) return const [];
      return [
        for (final raw in rows.take(_maxRows)) _fromJson(raw),
      ].whereType<SessionSummary>().toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Map<String, Object?> _toJson(SessionSummary row) => {
    'id': row.sessionId,
    'updated': row.updatedAt.millisecondsSinceEpoch,
    'running': row.running,
    'blank': row.blank,
    'agent': row.agentAvailable,
    'cwd': row.cwd,
    'origin': row.origin,
    'kind': row.projectionsKind,
    'title': row.title,
  };

  static SessionSummary? _fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final updated = raw['updated'];
    final title = raw['title'];
    return SessionSummary(
      sessionId: id,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updated is int ? updated : 0),
      running: raw['running'] == true,
      blank: raw['blank'] == true,
      agentAvailable: raw['agent'] == true,
      cwd: raw['cwd'] is String ? raw['cwd'] as String : null,
      origin: raw['origin'] is String ? raw['origin'] as String : null,
      // A cached row is not a live projection: `cached` keeps title reads from
      // asking the Host about it before the real list lands.
      projections: SessionProjections(-1, {'title': title is String ? title : null}),
      projectionsKind: raw['kind'] is String ? raw['kind'] as String : 'cached',
    );
  }
}

final sessionRowSnapshotProvider = Provider<SessionRowSnapshot>((ref) => SessionRowSnapshot());

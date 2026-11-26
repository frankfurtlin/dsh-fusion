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
//
// **一份快照存的是「抽屉能显示的全部行」，不是「全部行」的前 N 行。** 子会话
// （`origin == 'subagent'`）在抽屉里从来不显示（sessions_state 的 `_visible`
// 同样过滤掉它们），所以不落盘。2026-11-26 真机那次 `session_list_cached
// rows=93` 对照 `session_list rows=189` 看着像只铺了首屏，实测那台 Host 当时
// 正是 93 个真人会话 + 96 个子会话（187 条里 96 条是 subagent），93 就是全部。
// 为了以后不用再去数一遍，文件里记着写它时的全量行数（`total`），
// 诊断页那行会显示成 `rows=93 total=189`。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'hosts_state.dart' show HostRef;

/// 一份快照里最多留多少行（抽屉只用得到前几十行）。
const _maxRows = 400;

/// 文件总大小上限：超了就从最旧的行开始丢到装得下（不是干脆不写——那会把上一版
/// 的文件留在盘上，看着就像「快照少了一半」）。
const _maxBytes = 512 * 1024;

class SessionRowSnapshot {
  SessionRowSnapshot({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  final Map<String, List<SessionSummary>> _rows = {};
  final Set<String> _loaded = {};

  /// 写是有先后顺序的：两次读前后脚落地时，慢的那次不能盖掉新的。
  Future<void> _queue = Future<void>.value();

  /// 文件里记着的两个数：写它的时刻、写它时列表的全量行数（子会话在内）。
  final Map<String, DateTime> _savedAt = {};
  final Map<String, int> _savedTotal = {};

  static String _key(HostRef host) => '${host.kind.name}-${host.id}';

  /// 这份文件是什么时候写的（诊断页用）；没写过或没读过时 null。
  DateTime? savedAtFor(HostRef host) => _savedAt[_key(host)];

  /// 写这份文件那次 `session/list` 有多少行（含子会话）；不知道时 null。
  /// 和 [rowsFor] 的条数一比就知道快照有没有掉行。
  int? totalFor(HostRef host) => _savedTotal[_key(host)];

  /// 这台 Host 上次的列表；没有（或还没读过）时是空列表。
  Future<List<SessionSummary>> rowsFor(HostRef host) async {
    final key = _key(host);
    if (_loaded.add(key)) {
      _rows[key] = await _read(key);
    }
    return _rows[key] ?? const [];
  }

  /// 列表读成功后写下这一次的行（去掉子会话：抽屉不显示它们）。
  Future<void> save(HostRef host, Iterable<SessionSummary> rows) {
    final all = rows.toList(growable: false);
    final kept = [
      for (final row in all)
        if (!row.isSubagent && row.sessionId.isNotEmpty) row,
    ];
    if (kept.isEmpty) return Future<void>.value();
    if (kept.length > _maxRows) kept.removeRange(_maxRows, kept.length);
    final key = _key(host);
    final total = all.length;
    final fitted = _trimmedToFit(kept, total);
    _rows[key] = fitted;
    _loaded.add(key);
    _savedTotal[key] = total;
    if (fitted.isEmpty) return Future<void>.value();
    final written = _queue.then((_) => _write(key, fitted, total));
    _queue = written.catchError((Object _) {});
    return written;
  }

  /// 装不下 [_maxBytes] 时从尾部（最旧的）开始丢，直到装得下：绝不因为超限
  /// 就不写，把上一版的文件留在盘上。正常一份（93 行 ≈ 20 KB）一次就过。
  List<SessionSummary> _trimmedToFit(List<SessionSummary> rows, int total) {
    var keep = rows.length;
    while (keep > 0) {
      final candidate = keep == rows.length ? rows : rows.sublist(0, keep);
      if (_encode(candidate, total).length <= _maxBytes) return candidate;
      keep = keep ~/ 2;
    }
    return const [];
  }

  String _encode(List<SessionSummary> rows, int total) => jsonEncode({
    'version': 1,
    'savedAt': DateTime.now().toUtc().toIso8601String(),
    'total': total,
    'rows': [for (final row in rows) _toJson(row)],
  });

  Future<void> _write(String key, List<SessionSummary> rows, int total) async {
    try {
      final directory = await _directory();
      final file = await _file(directory, key);
      final savedAt = DateTime.now().toUtc();
      final encoded = _encode(rows, total);
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
      _savedAt[key] = savedAt;
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
      // 老文件没有这两个字段：没有就是不知道，不是 0。
      final savedAt = DateTime.tryParse(decoded['savedAt'] is String ? decoded['savedAt'] as String : '');
      if (savedAt != null) _savedAt[key] = savedAt.toLocal();
      final total = decoded['total'];
      if (total is int) _savedTotal[key] = total;
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

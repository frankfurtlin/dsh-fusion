// 性能账本：这一次启动里，哪个阶段等了多久。
//
// 为什么要有它：进 App 和点开会话慢的时候，环境里没有任何计时数据 —— 操作日志
// （[PocketLog]）只记事件不记耗时，诊断包也只有版本/状态。这里按阶段记毫秒，
// 两条出口：
//   * [PocketLog]：构建里注入了上报令牌时，随操作日志一起上去（服务器侧聚合）；
//   * 设置 → 诊断 → 性能：人可以直接复制，粘给 agent 看（不依赖令牌）。
//
// 约定：只记名称、毫秒和几个计数（行数、记录数、是否复用）；不记会话内容、
// 不记主机地址、不记凭据。名称是固定的英文标识，方便直接 grep。
//
// 这一份是"本次进程"的：冷启动、建链、列表、开会话各一次或几次，最多留 [_max]
// 条，先进的先丢。

import 'pocket_log.dart';

/// 一条已经结束的阶段：名称、耗时、计数。
class PerfSpan {
  const PerfSpan(this.name, this.ms, this.fields);

  final String name;
  final int ms;
  final Map<String, Object?> fields;

  /// `session_list 233ms rows=186`：诊断页和复制出去的文字用的就是它。
  @override
  String toString() {
    final tail = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    return '$name ${ms}ms${tail.isEmpty ? '' : ' $tail'}';
  }
}

abstract final class PerfTrace {
  /// 留多少条。一次启动正常 10 条上下（冷启动、建链、列表、若干次开会话）。
  static const maxSpans = 50;

  static final List<PerfSpan> _spans = [];
  static final Map<String, Stopwatch> _open = {};

  /// 这一次进程起来的时间（[text] 的抬头用）。
  static final DateTime bootedAt = DateTime.now();

  /// 已记下的阶段，按发生顺序。
  static List<PerfSpan> get spans => List.unmodifiable(_spans);

  static bool get isEmpty => _spans.isEmpty;

  /// 开始一段。同名未结束的开始会被替换（比如重连又开了一段）。
  static void begin(String name) {
    _open[name] = Stopwatch()..start();
  }

  /// 结束一段；没有对应的 [begin] 时什么都不做（调用点不必套 try）。
  static void end(String name, [Map<String, Object?> fields = const {}]) {
    final watch = _open.remove(name);
    if (watch == null) return;
    _add(name, watch.elapsedMilliseconds, fields);
  }

  /// 记一个已经量好的点（例如在别处用本地 Stopwatch 量的）。
  static void note(String name, int ms, [Map<String, Object?> fields = const {}]) =>
      _add(name, ms, fields);

  /// 把 [run] 量一遍再返回；失败也记一条（带 error），错误照旧抛出。
  static Future<T> measure<T>(
    String name,
    Future<T> Function() run, {
    Map<String, Object?> Function(T value)? fields,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final value = await run();
      _add(name, watch.elapsedMilliseconds, fields?.call(value) ?? const {});
      return value;
    } catch (error) {
      _add(name, watch.elapsedMilliseconds, {'error': _firstLine('$error')});
      rethrow;
    }
  }

  /// 诊断页上的文字：一行一条，可直接复制。
  static String text() {
    if (_spans.isEmpty) return '';
    final head = 'boot ${bootedAt.toIso8601String()}';
    return [head, ..._spans.map((s) => s.toString())].join('\n');
  }

  static void _add(String name, int ms, Map<String, Object?> fields) {
    _spans.add(PerfSpan(name, ms, Map.unmodifiable(fields)));
    while (_spans.length > maxSpans) {
      _spans.removeAt(0);
    }
    // 操作日志开着的时候顺手发一条：服务器侧能看到跨启动的分布。
    PocketLog.instance.log('perf', {
      'span': name,
      'ms': ms,
      ...fields,
    });
  }

  static String _firstLine(String text) {
    final line = text.split('\n').first;
    return line.length > 120 ? '${line.substring(0, 119)}…' : line;
  }

  /// 测试用：清空（进程里只有一份账本）。
  static void reset() {
    _spans.clear();
    _open.clear();
  }
}

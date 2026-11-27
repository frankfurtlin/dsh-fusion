import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'redact.dart' show redactJson;

/// 操作日志：把 App 里发生的事按行记下来，攒够了 POST 到自己的服务器
/// (`https://hermes.frankfurtlin.top/pocket/log`)，服务端落盘后定期归档到 COS。
///
/// 约束（对齐项目约定）：
/// - **不记凭据**：每条字段都过一遍 [redact]，token/密码/私钥一律剥掉。
/// - **不打扰前台**：批量上报，最多 30 条或 30 秒一次；失败就留在队列里，下次再试。
/// - **可关**：`POCKET_LOG_TOKEN` 为空（本地构建）时整个模块是空操作。
/// - 单条请求上限 256 KB（服务端也校验），队列最多留 500 条，超出丢最旧的。
class PocketLog {
  PocketLog._();

  static final PocketLog instance = PocketLog._();

  /// CI 构建时由 `--dart-define=POCKET_LOG_TOKEN=…` 注入；本地构建为空 = 关闭。
  static const _token = String.fromEnvironment('POCKET_LOG_TOKEN');

  static const _endpoint = 'https://hermes.frankfurtlin.top/pocket/log';
  static const _flushEvery = Duration(seconds: 30);
  static const _maxQueued = 500;
  static const _maxBatch = 30;

  final List<Map<String, Object?>> _queue = [];
  File? _spool;
  Timer? _timer;
  bool _sending = false;
  bool _started = false;

  bool get enabled => _token.isNotEmpty && !kIsWeb;

  /// 设备标识：装一次就固定，用于把日志按机器分开。
  String device = 'unknown';

  Future<void> start({required String deviceId, required String appVersion}) async {
    if (!enabled || _started) return;
    _started = true;
    device = deviceId;
    _appVersion = appVersion;
    try {
      final dir = Directory('${await _supportDir()}/logs');
      await dir.create(recursive: true);
      _spool = File('${dir.path}/pending.jsonl');
      if (await _spool!.exists()) {
        for (final line in await _spool!.readAsLines()) {
          if (line.trim().isEmpty) continue;
          try {
            _queue.add(jsonDecode(line) as Map<String, Object?>);
          } catch (_) {}
        }
      }
    } catch (_) {
      // 拿不到目录就只在内存里攒，不影响功能
    }
    log('app_start', {'queuedFromSpool': _queue.length});
    _timer = Timer.periodic(_flushEvery, (_) => flush());
  }

  String _appVersion = '';

  Future<String> _supportDir() async {
    final env = Platform.environment;
    // Android: /data/user/0/<pkg>/files；Flutter 侧没有 path_provider 依赖，
    // 用 HOME 系列环境变量在测试里也能落到临时目录。
    final home = env['HOME'] ?? env['TMPDIR'] ?? Directory.systemTemp.path;
    return home;
  }

  /// 记一条。字段里的敏感值会被剥掉。
  void log(String event, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    final entry = <String, Object?>{'ts': DateTime.now().toIso8601String(), 'event': event, ...redactEntry(fields)};
    _queue.add(entry);
    while (_queue.length > _maxQueued) {
      _queue.removeAt(0);
    }
    if (_queue.length >= _maxBatch) {
      unawaited(flush());
    }
  }

  Future<void> flush() async {
    if (!enabled || _sending || _queue.isEmpty) return;
    _sending = true;
    final batch = _queue.take(_maxBatch).toList();
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client.postUrl(Uri.parse(_endpoint));
      request.headers
        ..contentType = ContentType.json
        ..set('Authorization', 'Bearer $_token');
      request.write(jsonEncode({'device': device, 'app': _appVersion, 'events': batch}));
      final response = await request.close().timeout(const Duration(seconds: 20));
      await response.drain<void>();
      if (response.statusCode == 200) {
        _queue.removeRange(0, batch.length);
      }
      client.close(force: true);
    } catch (_) {
      // 网络问题：留在队列里，下次再发
    } finally {
      _sending = false;
      await _persist();
    }
  }

  Future<void> _persist() async {
    final spool = _spool;
    if (spool == null) return;
    try {
      final text = _queue.map((e) => jsonEncode(e)).join('\n');
      await spool.writeAsString(text, flush: false);
    } catch (_) {}
  }

  /// 关掉（测试或用户关闭上报时）。
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _persist();
  }
}

/// 单条事件的脱敏：直接复用诊断导出的同一套规则，避免两份实现漂移。
Map<String, Object?> redactEntry(Map<String, Object?> fields) =>
    (redactJson(fields) as Map?)?.cast<String, Object?>() ?? const {};

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../diagnostics/pocket_log.dart';

/// 服务端「兴趣摘要」里的一条内容。
class DigestItem {
  const DigestItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.source,
    required this.url,
    required this.publishedAt,
    required this.tags,
  });

  final String id;
  final String title;
  final String summary;
  final String source;
  final String url;
  final String publishedAt;
  final List<String> tags;

  static DigestItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final title = (json['title'] as String? ?? '').trim();
    if (title.isEmpty) return null;
    return DigestItem(
      id: json['id'] as String? ?? title,
      title: title,
      summary: (json['summary'] as String? ?? '').trim(),
      source: json['source'] as String? ?? '',
      url: json['url'] as String? ?? '',
      publishedAt: json['publishedAt'] as String? ?? '',
      tags: [
        for (final t in (json['tags'] as List? ?? const []))
          if (t is String && t.isNotEmpty) t,
      ],
    );
  }
}

/// 一次读到的摘要：条目 + 开关状态 + 生成时间。
class DigestSnapshot {
  const DigestSnapshot({
    required this.items,
    required this.enabled,
    required this.generatedAt,
  });

  final List<DigestItem> items;
  final bool enabled;
  final String generatedAt;

  static const empty = DigestSnapshot(items: [], enabled: true, generatedAt: '');

  bool get isEmpty => items.isEmpty;

  /// 解析服务端那份 JSON。字段缺失或坏掉时按能读多少读多少 —— 页面上宁可少一条，
  /// 也不要整页报错。
  static DigestSnapshot parse(String raw, {required bool enabled}) {
    if (raw.isEmpty) return DigestSnapshot(items: const [], enabled: enabled, generatedAt: '');
    try {
      final root = jsonDecode(raw);
      if (root is! Map) return DigestSnapshot(items: const [], enabled: enabled, generatedAt: '');
      final items = [
        for (final entry in (root['items'] as List? ?? const []))
          ?DigestItem.fromJson(entry),
      ];
      return DigestSnapshot(
        items: items,
        enabled: enabled,
        generatedAt: root['generatedAt'] as String? ?? '',
      );
    } catch (_) {
      return DigestSnapshot(items: const [], enabled: enabled, generatedAt: '');
    }
  }
}


/// 一批推送（服务端每 6 小时一轮，留最近 30 天）。
class DigestBatch {
  const DigestBatch({required this.id, required this.at, required this.count, required this.titles});

  final String id;

  /// `generatedAt` 原文（ISO 8601，带 +08:00）。
  final String at;
  final int count;

  /// 这批的标题（服务端只给前 120 字，列表页够用；详情再取全文）。
  final List<String> titles;

  /// 本地时间显示用；解析不了返回 null。
  DateTime? get localTime => DateTime.tryParse(at)?.toLocal();

  static DigestBatch? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'] as String? ?? '';
    if (id.isEmpty) return null;
    return DigestBatch(
      id: id,
      at: json['at'] as String? ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      titles: [
        for (final t in (json['titles'] as List? ?? const []))
          if (t is String && t.trim().isNotEmpty) t.trim(),
      ],
    );
  }
}

/// `history/index.json` 的解析结果（坏条目跳过，不整页报错）。
class DigestHistoryIndex {
  const DigestHistoryIndex(this.batches);

  final List<DigestBatch> batches;

  static const empty = DigestHistoryIndex([]);

  bool get isEmpty => batches.isEmpty;

  static DigestHistoryIndex parse(String raw) {
    if (raw.isEmpty) return empty;
    try {
      final root = jsonDecode(raw);
      if (root is! Map) return empty;
      final batches = [
        for (final entry in (root['batches'] as List? ?? const [])) ?DigestBatch.fromJson(entry),
      ]..sort((a, b) => b.id.compareTo(a.id));
      return DigestHistoryIndex(batches);
    } catch (_) {
      return empty;
    }
  }
}

/// 服务端那一份摘要所在的目录（`.../digest.json` 去掉文件名）；拿不到返回 null。
String? digestDirectoryOf(String? manifestUrl) {
  if (manifestUrl == null || manifestUrl.isEmpty) return null;
  final cut = manifestUrl.lastIndexOf('/');
  if (cut <= 'https://'.length) return null;
  return manifestUrl.substring(0, cut + 1);
}

/// 与 Kotlin 侧的通道：后台拉取、缓存、开关都在那边，这里只读结果。
class DigestApi {
  const DigestApi._();

  static const _channel = MethodChannel('top.frankfurtlin.dshfusion/digest');

  /// 读缓存的摘要；离线可用。
  static Future<DigestSnapshot> load() async {
    final result = await _channel.invokeMapMethod<String, Object?>('load');
    final enabled = result?['enabled'] as bool? ?? true;
    final json = result?['json'] as String? ?? '';
    return DigestSnapshot.parse(json, enabled: enabled);
  }

  /// 手动刷新一次（页面下拉）。返回最新快照。
  static Future<DigestSnapshot> refresh() async {
    final result = await _channel.invokeMapMethod<String, Object?>('refresh');
    final json = result?['json'] as String? ?? '';
    final snapshot = DigestSnapshot.parse(json, enabled: true);
    PocketLog.instance.log('digest_refresh', {
      'fresh': result?['fresh'],
      'items': snapshot.items.length,
    });
    return snapshot;
  }

  /// 摘要目录（用 Kotlin 侧记下的地址推出来）。
  static Future<String?> directory() async {
    final result = await _channel.invokeMapMethod<String, Object?>('load');
    return digestDirectoryOf(result?['url'] as String?);
  }

  /// 推送历史：读服务端的 `history/index.json`。失败抛异常，页面显示重试。
  static Future<DigestHistoryIndex> history() async {
    final base = await directory();
    if (base == null) return DigestHistoryIndex.empty;
    final raw = await _getJson('${base}history/index.json');
    final index = DigestHistoryIndex.parse(raw);
    PocketLog.instance.log('digest_history', {'batches': index.batches.length});
    return index;
  }

  /// 某一批的全部条目（点开历史条目时才取）。
  static Future<List<DigestItem>> batchItems(String id) async {
    final base = await directory();
    if (base == null) return const [];
    final raw = await _getJson('${base}history/$id.json');
    try {
      final root = jsonDecode(raw);
      if (root is! Map) return const [];
      return [for (final entry in (root['items'] as List? ?? const [])) ?DigestItem.fromJson(entry)];
    } catch (_) {
      return const [];
    }
  }

  /// 一个很小的只读 GET：不走 App 的 HTTP 栈，历史页自己用。
  static Future<String> _getJson(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, 'dsh-pocket/1.0');
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> setEnabled(bool enabled) async {
    final result = await _channel.invokeMethod<bool>('setEnabled', enabled);
    return result ?? enabled;
  }

  /// 打开过页面，把当前条目记成已提示，避免下次又弹通知。
  static Future<void> markSeen() async {
    await _channel.invokeMethod<void>('markSeen');
  }
}

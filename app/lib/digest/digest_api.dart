import 'dart:convert';

import 'package:flutter/services.dart';

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
    return DigestSnapshot.parse(json, enabled: true);
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

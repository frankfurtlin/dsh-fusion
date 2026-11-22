import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../ui/common/empty_view.dart';
import 'digest_api.dart';

/// 「发现」：按你的兴趣方向挑出来的内容。
///
/// 内容由服务器侧的定时任务生成（`/root/scripts/pocket/digest.py`），这里只负责
/// 展示、手动刷新和开关。后台拉取与通知在 Kotlin 侧（`DigestSync`），每 6 小时一次。
class DigestPage extends StatefulWidget {
  const DigestPage({super.key});

  @override
  State<DigestPage> createState() => _DigestPageState();
}

class _DigestPageState extends State<DigestPage> {
  DigestSnapshot _snapshot = DigestSnapshot.empty;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await DigestApi.load();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
      await DigestApi.markSeen();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final snapshot = await DigestApi.refresh();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot.isEmpty ? _snapshot : snapshot;
        _refreshing = false;
        _error = null;
      });
      await DigestApi.markSeen();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _error = '$error';
      });
    }
  }

  Future<void> _toggle(bool enabled) async {
    await DigestApi.setEnabled(enabled);
    if (!mounted) return;
    setState(() {
      _snapshot = DigestSnapshot(
        items: _snapshot.items,
        enabled: enabled,
        generatedAt: _snapshot.generatedAt,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.digestTitle),
        actions: [
          IconButton(
            tooltip: l10n.digestRefresh,
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _snapshot.enabled,
                    onChanged: _toggle,
                    title: Text(l10n.digestPushTitle),
                    subtitle: Text(l10n.digestPushSubtitle),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        l10n.digestError,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (_snapshot.items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: EmptyView(
                        title: l10n.digestEmptyTitle,
                        message: l10n.digestEmptyDetail,
                      ),
                    )
                  else
                    for (final item in _snapshot.items) _DigestTile(item: item),
                ],
              ),
            ),
    );
  }
}

class _DigestTile extends StatelessWidget {
  const _DigestTile({required this.item});

  final DigestItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: item.url.isEmpty
            ? null
            : () => launchUrl(Uri.parse(item.url), mode: LaunchMode.externalApplication),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: theme.textTheme.titleSmall),
              if (item.summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  item.summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (item.source.isNotEmpty) _Chip(label: item.source),
                  for (final tag in item.tags.take(2)) _Chip(label: tag),
                  if (item.publishedAt.length >= 10)
                    _Chip(label: item.publishedAt.substring(0, 10)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(label, style: theme.textTheme.labelSmall),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/common/empty_view.dart';
import '../ui/theme/app_icons.dart';
import 'digest_api.dart';
import 'digest_history_page.dart';
import 'digest_tile.dart';

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
            tooltip: l10n.digestHistory,
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => const DigestHistoryPage())),
            icon: const Icon(AppIcons.time),
          ),
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
                    for (final item in _snapshot.items) DigestTile(item: item),
                ],
              ),
            ),
    );
  }
}

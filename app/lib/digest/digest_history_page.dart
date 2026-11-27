// 推送历史：服务端每 6 小时留一份，App 按批次列出，展开才取那几天的条目。
//
// 数据来自 `<摘要目录>/history/index.json`（批次清单）与 `history/<id>.json`
// （某一轮的完整条目）。仍然是同一个不可枚举的路径，不额外要鉴权；
// 失败不缓存，下拉或点「重试」重来。

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/common/empty_view.dart';
import '../ui/theme/app_icons.dart';
import 'digest_api.dart';
import 'digest_tile.dart';

class DigestHistoryPage extends StatefulWidget {
  const DigestHistoryPage({super.key});

  @override
  State<DigestHistoryPage> createState() => _DigestHistoryPageState();
}

class _DigestHistoryPageState extends State<DigestHistoryPage> {
  DigestHistoryIndex _index = DigestHistoryIndex.empty;
  final _batchItems = <String, Future<List<DigestItem>>>{};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final index = await DigestApi.history();
      if (!mounted) return;
      setState(() {
        _index = index;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<List<DigestItem>> _items(String id) => _batchItems.putIfAbsent(id, () => DigestApi.batchItems(id));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.digestHistory),
        actions: [
          IconButton(
            tooltip: l10n.digestRefresh,
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(AppIcons.autoUpdate),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: EmptyView(
                icon: AppIcons.offline,
                title: l10n.digestHistoryError,
                actionLabel: l10n.commonRetry,
                onAction: () => unawaited(_load()),
              ),
            )
          : _index.isEmpty
          ? Center(
              child: EmptyView(title: l10n.digestHistoryEmpty, message: l10n.digestHistoryEmptyDetail),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                itemCount: _index.batches.length,
                itemBuilder: (context, index) =>
                    _BatchTile(batch: _index.batches[index], load: () => _items(_index.batches[index].id)),
              ),
            ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({required this.batch, required this.load});

  final DigestBatch batch;
  final Future<List<DigestItem>> Function() load;

  /// `11-26 09:59`：本地时间；解析不了就显示原始字符串。
  static String _stamp(DigestBatch batch) {
    final time = batch.localTime;
    if (time == null) return batch.at;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final preview = batch.titles.isEmpty ? null : batch.titles.first;
    return ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(_stamp(batch), style: theme.textTheme.titleSmall),
      subtitle: preview == null
          ? Text(l10n.digestHistoryCount(batch.count), style: theme.textTheme.bodySmall)
          : Text(
              '${l10n.digestHistoryCount(batch.count)} · $preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      children: [
        FutureBuilder<List<DigestItem>>(
          future: load(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              );
            }
            final items = snapshot.data ?? const <DigestItem>[];
            if (items.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.digestHistoryEmpty, style: theme.textTheme.bodySmall),
              );
            }
            return Column(children: [for (final item in items) DigestTile(item: item)]);
          },
        ),
      ],
    );
  }
}

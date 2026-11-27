// 一条推送内容（发现页和历史页共用的卡片）：标题、摘要、来源/标签/日期。
// 点开走外部浏览器；没有链接的条目不可点。

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'digest_api.dart';

class DigestTile extends StatelessWidget {
  const DigestTile({super.key, required this.item});

  final DigestItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: item.url.isEmpty ? null : () => launchUrl(Uri.parse(item.url), mode: LaunchMode.externalApplication),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: theme.textTheme.titleSmall),
              if (item.summary.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(item.summary, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (item.source.isNotEmpty) DigestChip(label: item.source),
                  for (final tag in item.tags.take(2)) DigestChip(label: tag),
                  if (item.publishedAt.length >= 10) DigestChip(label: item.publishedAt.substring(0, 10)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DigestChip extends StatelessWidget {
  const DigestChip({super.key, required this.label});

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

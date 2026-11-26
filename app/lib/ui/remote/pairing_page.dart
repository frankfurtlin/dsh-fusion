// DSH Remote (中继) 的扫码配对。DeepSeek 账号已随手机本地引擎删除
// （2026-11-26）：配对要把这台手机绑到账号 ID 上，没有账号就没有可绑的身份，
// 所以这里不再扫码，而是把原因说清楚。
//
// 中继主机本身保留：已经配对 / 服务器上已登记的主机照旧可以连接、切换、
// 看状态；只是这台手机不能再新配对一个。

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';

class RemotePairingPage extends StatelessWidget {
  const RemotePairingPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const RemotePairingPage());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return AppPage.list(
      title: l10n.remotePairTitle,
      subtitle: Text(l10n.remotePairSubtitle),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.remotePairNeedsDeepSeek, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    l10n.remotePairNeedsDeepSeekBody,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// 设置 › 隐私与分享 › 改进 DSH Go: the switch for anonymous usage statistics
// (lib/usage/usage_stats.dart) and, under it, what goes out.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/android_features.dart';
import '../../usage/usage_stats.dart';
import 'settings_widgets.dart';

class UsageStatsSection extends ConsumerStatefulWidget {
  const UsageStatsSection({super.key});

  @override
  ConsumerState<UsageStatsSection> createState() => _UsageStatsSectionState();
}

class _UsageStatsSectionState extends ConsumerState<UsageStatsSection> {
  @override
  void initState() {
    super.initState();
    // The switch and its sentence on screen count as being told.
    unawaited(ref.read(usageStatsProvider.notifier).markNoticed());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Its report isn't in a shape the server takes yet: every day would be dropped.
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    return SettingsSection(
      title: l10n.usageStatsSection,
      footer: Text(ohos ? l10n.harmonyUsageNotSent : l10n.usageStatsFooter),
      children: [
        // Nothing is collected in this build; the section is left out of 隐私 entirely
        // (ui/settings/privacy_page.dart) and kept here only for callers that still build it.
      ],
    );
  }
}

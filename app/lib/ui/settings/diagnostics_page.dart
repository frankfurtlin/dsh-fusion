// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../diagnostics/perf_trace.dart';
import '../../diagnostics/redact.dart';
import '../../diagnostics/system_ime_diagnostics.dart';
import '../../state/android_features.dart';
import '../../state/app_info.dart';
import '../../state/connection_state.dart';
import '../../state/settings_state.dart';
import '../common/list_page_row.dart';
import 'diagnostics_export_card.dart';
import '../shell/page_frame.dart';
import '../phone/phone_control_screen.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart' show AppType;
import 'settings_widgets.dart';
import '../common/brief_notice.dart';

/// Self-service diagnostics: what the app knows about the runtime and the
/// connection, plus a copyable report with every secret redacted.
class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  static Map<String, Object?> report({required AppSettings settings, required String connection}) => {
    'app': AppInfo.version,
    'connection': connection,
    'settings': {'hasApiKey': settings.hasApiKey, 'themeMode': settings.themeMode.name},
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider);
    final conn = ref.watch(activeConnectionProvider);
    final connection = switch (conn) {
      AsyncData(:final value) => value == null ? l10n.commonNotConnected : l10n.pluginsConnectedHost(value.label),
      AsyncError(:final error) => l10n.pluginsConnectionError('$error'),
      _ => l10n.pluginsConnecting,
    };
    Future<void> copyReport() async {
      final json = const JsonEncoder.withIndent('  ')
          .convert(redactJson(report(settings: settings, connection: connection)));
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        showBriefNotice(context, l10n.pluginsDiagnosticsCopied);
      }
    }

    return AppPage.list(
      title: l10n.pluginsDiagnostics,
      subtitle: Text(l10n.pluginsDiagnosticsDescription),
      children: [
        SettingsSection(
          title: l10n.pluginsConnection,
          children: [
            InfoRow(label: l10n.pluginsClient, value: connection),
            InfoRow(label: 'API Key', value: settings.hasApiKey ? l10n.pluginsConfigured : l10n.commonNotSet),
          ],
        ),
        // 本次启动各阶段等了多久：复制给我，就能说清是建链、列表还是会话内容慢。
        const PerfSection(),
        // Android reads the system log through a privileged channel; HarmonyOS, this app's own window.
        const SystemImeDiagnosticsSection(),
        DiagnosticsExportCard(
          title: l10n.pluginsExport,
          extra: [
            ListPageRow(
              icon: AppIcons.copy,
              title: l10n.pluginsCopyDiagnostics,
              subtitle: l10n.pluginsDiagnosticsContents,
              onTap: copyReport,
            ),
          ],
        ),
        // The note belongs to the export card; the next group starts 24 below
        // it, as groups do.
        const DiagnosticsBundleNote(),
      ],
    );
  }
}

/// 本次启动的性能账本（diagnostics/perf_trace.dart）：一行一个阶段，可复制。
/// 不写入磁盘、不含会话内容；进程重开后重新记。
class PerfSection extends StatelessWidget {
  const PerfSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = PerfTrace.text();
    Future<void> copy() async {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) showBriefNotice(context, l10n.perfCopied);
    }

    return SettingsSection(
      title: l10n.performanceTitle,
      footer: Text(l10n.perfHint),
      children: [
        if (text.isEmpty)
          InfoRow(label: l10n.performanceTitle, value: l10n.perfEmpty)
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SelectableText(
              text,
              style: AppType.monoLabel(color: theme.colorScheme.onSurfaceVariant).copyWith(height: 1.6),
            ),
          ),
          ListPageRow(icon: AppIcons.copy, title: l10n.perfCopy, onTap: copy),
        ],
      ],
    );
  }
}

/// Only this visible, user-owned section can start a native consent request.
class SystemImeDiagnosticsSection extends ConsumerStatefulWidget {
  const SystemImeDiagnosticsSection({super.key});

  @override
  ConsumerState<SystemImeDiagnosticsSection> createState() => _SystemImeDiagnosticsSectionState();
}

class _SystemImeDiagnosticsSectionState extends ConsumerState<SystemImeDiagnosticsSection> with WidgetsBindingObserver {
  late final SystemImeDiagnostics _diagnostics;
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _diagnostics = ref.read(systemImeDiagnosticsProvider);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (_route?.isCurrent == false) _diagnostics.cancelPending(notify: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A native consent dialog makes Flutter inactive without leaving the Activity.
    // Native onActivityPaused also revokes consent when the user actually leaves.
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      _diagnostics.cancelPending();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _diagnostics.cancelPending(notify: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _diagnostics,
    builder: (context, _) {
      final l10n = context.l10n;
      final evidence = _diagnostics.evidence;
      // HarmonyOS records this app's own window geometry: no privileged log, nothing to grant.
      final ohos = ref.watch(operatingSystemProvider) == 'ohos';
      final status = _diagnostics.collecting
          ? l10n.systemImeCollecting
          : switch (evidence?.code) {
              null => l10n.systemImeNotCollected,
              'ok' => l10n.systemImeRetained,
              'noEvents' => l10n.systemImeNoEvents,
              'unavailable' => ohos ? l10n.systemImeOhosUnavailable : l10n.systemImeUnavailable,
              'unsupported' => l10n.systemImeUnsupported,
              'denied' => l10n.systemImeDenied,
              'cancelled' => l10n.systemImeCancelled,
              'busy' => l10n.systemImeBusy,
              'timeout' => l10n.systemImeTimeout,
              'limitExceeded' => l10n.systemImeLimitExceeded,
              _ => l10n.systemImeFailed,
            };
      return SettingsSection(
        title: ohos ? l10n.systemImeOhosTitle : l10n.systemImeTitle,
        children: [
          SettingsTile(
            icon: AppIcons.exportLog,
            title: ohos ? l10n.systemImeOhosCollect : l10n.systemImeCollect,
            subtitle: ohos ? l10n.systemImeOhosPrivacy : l10n.systemImePrivacy,
            onTap: _diagnostics.collecting
                ? null
                : () => _diagnostics.collect(isCurrent: () => mounted && (_route?.isCurrent ?? true)),
            tinted: false,
          ),
          SettingsTile(title: status, subtitle: l10n.systemImeEvidenceLimits),
          InfoRow(label: l10n.systemImeEventCount, value: '${evidence?.events.length ?? 0} / 64'),
          if (evidence != null)
            InfoRow(
              label: l10n.systemImeCapturedAt,
              value: DateTime.fromMillisecondsSinceEpoch(evidence.capturedAt).toString().split('.').first,
            ),
          if (evidence?.code == 'unavailable' && !ohos)
            SettingsTile(
              icon: AppIcons.permissions,
              title: l10n.systemImePermissions,
              subtitle: l10n.systemImePermissionsHint,
              onTap: () {
                _diagnostics.cancelPending();
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneControlScreen()));
              },
              tinted: false,
            ),
          SettingsTile(
            icon: AppIcons.clearAll,
            title: l10n.systemImeClear,
            subtitle: l10n.systemImeMemory,
            onTap: evidence != null || _diagnostics.collecting ? _diagnostics.clear : null,
            tinted: false,
          ),
        ],
      );
    },
  );
}

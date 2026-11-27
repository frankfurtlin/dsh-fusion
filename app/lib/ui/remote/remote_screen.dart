import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/connection_state.dart';
import '../../remote/web/web_host_config.dart';
import '../../state/hosts_state.dart';
import '../common/ask_ai.dart';
import '../common/overview_card.dart';
import '../common/status_chip.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'host_key_dialog.dart';
import 'host_status.dart';
import 'link_progress.dart';
import 'network_details_sheet.dart';
import 'relay_login_sheet.dart';
import 'ssh_host_form.dart';
import 'web_host_form.dart';
import 'session_backup_page.dart';
import 'remote_web/remote_web_entry.dart';

/// 远程主机 (a list page): the computers and servers this phone can drive.
///
/// Two ways in, side by side: a DSH Remote account (李国宝's ds-harness-remote,
/// end-to-end encrypted relay, no network setup) and SSH hosts (self-contained:
/// dsh-app starts `dsh web` over SSH and tunnels to it). Picking a host makes
/// it the active one; the chat and the session list follow. The old Remote
/// Web console stays as a small fallback at the bottom.
class RemoteScreen extends ConsumerWidget {
  const RemoteScreen({super.key});

  Future<void> _use(BuildContext context, WidgetRef ref, HostRef host) async {
    final navigator = Navigator.of(context);
    if (ref.read(activeHostProvider) == host) {
      // Tapping the active host after a failure: confirm trust if that was
      // the problem, then connect again.
      final failed = ref.read(hostLinkStatusProvider(host)).value?.phase == HostLinkPhase.failed;
      if (!failed) {
        navigator.maybePop();
        return;
      }
      if (await activateHost(context, ref, host)) {
        ref.read(remoteConnectionProvider(host).notifier).retry();
      }
      return;
    }
    final ok = await activateHost(context, ref, host);
    if (ok && navigator.mounted) navigator.maybePop();
  }

  /// A host added while there is no host at all (first run: this page *is* the
  /// first page) is the one to use: take it at once instead of a second tap.
  /// 本机引擎已下线，所以不再看本机运行环境，只看「有没有主机」。
  Future<void> _addWeb(BuildContext context, WidgetRef ref) async {
    final saved = await Navigator.of(context)
        .push<WebHostConfig>(MaterialPageRoute(builder: (_) => const WebHostFormPage()));
    if (saved == null || !context.mounted) return;
    if (ref.read(activeHostProvider).isNone) await _use(context, ref, HostRef.web(saved.id));
  }

  Future<void> _addSsh(BuildContext context, WidgetRef ref) async {
    final saved = await Navigator.of(context)
        .push<SshHostConfig>(MaterialPageRoute(builder: (_) => const SshHostFormPage()));
    if (saved == null || !context.mounted) return;
    if (ref.read(activeHostProvider).isNone) await _use(context, ref, HostRef.ssh(saved.id));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final ssh = ref.watch(hostsProvider.select((s) => s.ssh));
    final web = ref.watch(hostsProvider.select((s) => s.web));
    final active = ref.watch(activeHostProvider);
    final signedIn = ref.watch(relayAccountProvider.select((a) => a.value?.signedIn ?? false));
    void push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return AppPage.list(
      title: l10n.commonRemoteHost,
      subtitle: Text(l10n.remoteHostsIntro),
      actions: const [AskAiButton(AskAiTopic.remote)],
      children: [
        _ActiveCard(active: active),
        // The DSH Web of the host we are already connected to, when its
        // transport can carry one. Self-hides: no session or no tunnel
        // transport means no entry at all.
        const RemoteWebEntry(),
        SettingsSection(
          title: l10n.remoteTransferSettings,
          children: [
            SettingsSwitchTile(
              key: const ValueKey('remote-compact-history'),
              spot: Spots.remoteCompactHistory,
              subtitle: l10n.remoteCompactHistoryHint,
              value: ref.watch(remoteCompactHistoryProvider),
              onChanged: (value) => unawaited(ref.read(remoteCompactHistoryProvider.notifier).set(value)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.webLoginTitle,
          footer: web.isEmpty ? Text(l10n.webLoginIntro) : null,
          children: [
            for (final h in web)
              _WebRow(
                config: h,
                active: active == HostRef.web(h.id),
                onTap: () => _use(context, ref, HostRef.web(h.id)),
                onEdit: () => push(WebHostFormPage(existing: h)),
              ),
            SettingsTile(
              icon: AppIcons.add,
              tinted: false,
              title: l10n.webLoginAdd,
              subtitle: l10n.webLoginIntro,
              onTap: () => unawaited(_addWeb(context, ref)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.remoteSshHosts,
          footer: Text(l10n.remoteSshRequirements),
          children: [
            for (final h in ssh)
              _SshRow(
                config: h,
                active: active == HostRef.ssh(h.id),
                onTap: () => _use(context, ref, HostRef.ssh(h.id)),
                onEdit: () => push(SshHostFormPage(existing: h)),
              ),
            SettingsTile(
              icon: AppIcons.add,
              tinted: false,
              spot: Spots.addSshHost,
              subtitle: ssh.isEmpty ? l10n.remoteSshDirect : null,
              onTap: () => unawaited(_addSsh(context, ref)),
            ),
          ],
        ),
        // Only meaningful once there is a host to come back to.
        if (ssh.isNotEmpty || signedIn)
          SettingsSection(
            title: l10n.remoteStartupSection,
            children: [
              SettingsSwitchTile(
                key: const ValueKey('remote-auto-connect'),
                spot: Spots.remoteAutoConnect,
                subtitle: l10n.remoteAutoConnectOnStartupHint,
                value: ref.watch(remoteAutoConnectProvider),
                onChanged: (value) => unawaited(ref.read(remoteAutoConnectProvider.notifier).set(value)),
              ),
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              icon: AppIcons.save,
              spot: Spots.remoteSessionBackup,
              onTap: () => push(const SessionBackupPage()),
            ),
          ],
        ),
      ],
    );
  }
}

/// What the chat is talking to right now (only for a remote host), with live
/// state and the failure with its one fix.
class _ActiveCard extends ConsumerWidget {
  const _ActiveCard({required this.active});

  final HostRef active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    // 没有主机时这张卡没有可说的（本机引擎已下线，也没有「切回本机」）。
    if (active.isNone) return const SizedBox.shrink();
    final status = ref.watch(hostLinkStatusProvider(active)).value ?? HostLinkStatus.idle;
    final view = HostStatusView.ofLink(status);
    final name = ref.watch(hostNameProvider(active)) ?? l10n.commonRemoteHost;
    final ssh = active.kind == HostKind.ssh ? ref.watch(hostsProvider).sshById(active.id) : null;
    final error = status.error;
    // Errors a retry can't fix go to the host's settings (SSH) or the trust
    // check (relay) instead.
    final needsLogin = active.kind == HostKind.relay && error?.kind == HostLinkErrorKind.notLoggedIn;
    final needsSettings = ssh != null && error != null && !error.retryable;
    final needsTrust =
        active.kind == HostKind.relay &&
        (error?.kind == HostLinkErrorKind.hostKeyMismatch || error?.kind == HostLinkErrorKind.hostKeyUnverified);
    void reconnect() => ref.read(remoteConnectionProvider(active).notifier).retry();
    final failed = status.phase == HostLinkPhase.failed && error != null;
    return OverviewCard(
      leading: OverviewGlyph(hostKindIcon(active.kind), tint: hostKindTint(active.kind)),
      title: Text(l10n.remoteActiveHost(name)),
      subtitle: InkWell(
        onTap: active.kind == HostKind.relay && status.isConnected
            ? () => showRemoteNetworkDetails(context, active)
            : null,
        child: Row(
          children: [
            AnimatedStatusDot(tone: view.tone, size: 7),
            const SizedBox(width: 6),
            Flexible(
              child: Text(_statusLine(status, view, ssh?.address), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (active.kind == HostKind.relay && status.isConnected) ...[
              const SizedBox(width: 6),
              Tooltip(message: l10n.remoteNetworkDetails, child: const Icon(AppIcons.info, size: 16)),
            ],
          ],
        ),
      ),
      // 「切回本机」已去掉：本机引擎下线后，本机不再是可回退的主机。
      footer: failed
          ? Padding(
              padding: const EdgeInsets.only(left: OverviewCard.inset, right: OverviewCard.inset - 12),
              child: LinkErrorBox(
                error: error,
                action: needsLogin
                    ? (
                        l10n.remoteSignInAgain,
                        () async {
                          if (ref.read(relayAccountProvider).value?.user?.provider == 'password') {
                            final backend = ref.read(relayBackendProvider);
                            final signedIn = await showSelfHostedLogin(
                              context,
                              initialServer: ref.read(relayServerProvider) ?? defaultRelayServer,
                            );
                            if (signedIn == true &&
                                context.mounted &&
                                ref.read(activeHostProvider) == active &&
                                identical(backend, ref.read(relayBackendProvider))) {
                              reconnect();
                            }
                            return;
                          }
                          await ref.read(relayAccountProvider.notifier).login();
                          if (context.mounted && (ref.read(relayAccountProvider).value?.signedIn ?? false)) reconnect();
                        },
                      )
                    : needsSettings
                    ? (
                        l10n.remoteHostSettings,
                        () =>
                            Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => SshHostFormPage(existing: ssh))),
                      )
                    : needsTrust
                    ? (
                        l10n.remoteHostKeyTrustAgain,
                        () async {
                          if (await activateHost(context, ref, active)) {
                            reconnect();
                          }
                        },
                      )
                    : (active.kind == HostKind.relay ? l10n.remoteReconnect : l10n.commonRetry, reconnect),
              ),
            )
          : null,
    );
  }

  static String _statusLine(HostLinkStatus status, HostStatusView view, String? address) {
    if (status.phase == HostLinkPhase.reconnecting) {
      final why = status.error?.message;
      return why == null ? appL10n.remoteReconnectingEllipsis : appL10n.remoteReconnectReason(why);
    }
    if (status.phase == HostLinkPhase.connected) {
      if (address != null) return appL10n.remoteConnectedSsh(address);
      final path = status.network?.path ?? status.path;
      return path == null ? appL10n.remoteConnectedEncrypted : appL10n.remoteConnectedVia(path.label);
    }
    return view.label;
  }
}

/// Dot + word on the right of a host row.
class _HostState extends StatelessWidget {
  const _HostState(this.view);

  final HostStatusView view;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedStatusDot(tone: view.tone, size: 7),
        const SizedBox(width: 6),
        Text(view.label),
      ],
    );
  }
}

/// A trailing 20dp icon button whose glyph ends at the row's 16dp edge.
class _EdgeIconButton extends StatelessWidget {
  const _EdgeIconButton({required this.icon, required this.tooltip, required this.onPressed});

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// False when another trailing button follows it.

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: DshColors.of(context).textTertiary,
      icon: icon,
      onPressed: onPressed,
    );
    // Compact box 40, glyph 20: 10 of air; row padding 12 → nudge 6.
    return Transform.translate(
      offset: const Offset(SettingsMetrics.trailingPad + 10 - SettingsMetrics.inset, 0),
      child: button,
    );
  }
}

/// 一行网页登录主机：名字 + 网址（主机那一栏），失败状态和 SSH 行一样跟着显示。
class _WebRow extends ConsumerWidget {
  const _WebRow({required this.config, required this.active, required this.onTap, required this.onEdit});

  final WebHostConfig config;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = active ? watchHostStatus(ref, HostRef.web(config.id)) : null;
    return Semantics(
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.web),
        tinted: false,
        title: config.displayName,
        subtitle: '${config.username}@${config.base.host}',
        onTap: onTap,
        value: view == null ? null : _HostState(view),
        trailing: _EdgeIconButton(
          icon: const Icon(AppIcons.configure, size: 20),
          tooltip: l10n.commonEdit,
          onPressed: onEdit,
        ),
      ),
    );
  }
}

class _SshRow extends ConsumerWidget {
  const _SshRow({required this.config, required this.active, required this.onTap, required this.onEdit});

  final SshHostConfig config;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = active ? watchHostStatus(ref, HostRef.ssh(config.id)) : null;
    return Semantics(
      selected: active,
      inMutuallyExclusiveGroup: true,
      child: SettingsTile(
        icon: hostKindIcon(HostKind.ssh),
        tinted: false,
        title: config.name,
        subtitle: config.address,
        onTap: onTap,
        value: view == null ? null : _HostState(view),
        trailing: _EdgeIconButton(
          icon: const Icon(AppIcons.configure, size: 20),
          tooltip: l10n.commonEdit,
          onPressed: onEdit,
        ),
      ),
    );
  }
}

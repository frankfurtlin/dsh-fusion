// 手机桥: the settings page for the bridge server connection — where the
// server lives, which token authenticates it, whether the foreground service is
// running, and the way to the system accessibility switch the remote side needs.
//
// The page never decides what state the bridge is in: the native side answers
// and explains itself in [BridgeConfig.status], shown verbatim. Nothing here
// polls by hand; [BridgeChannel.watch] already falls back to polling when the
// event channel isn't there.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/phone_state.dart';
import '../ui/common/brief_notice.dart';
import '../ui/phone/phone_widgets.dart';
import '../ui/providers/provider_widgets.dart';
import '../ui/settings/settings_widgets.dart';
import '../ui/shell/page_frame.dart';
import '../ui/theme/semantic_colors.dart';
import 'bridge_channel.dart';

/// The page's own copy of the channel (stateless; one per call is fine).
const _bridge = BridgeChannel();

class BridgeSettingsPage extends ConsumerStatefulWidget {
  const BridgeSettingsPage({super.key});

  @override
  ConsumerState<BridgeSettingsPage> createState() => _BridgeSettingsPageState();
}

class _BridgeSettingsPageState extends ConsumerState<BridgeSettingsPage> with WidgetsBindingObserver {
  final _origin = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _a11yOn = false;
  final _name = TextEditingController();

  StreamSubscription<BridgeStatus>? _states;
  BridgeConfig? _config;
  BridgeStatus? _live;
  bool _busy = false;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _states = _bridge.watch().listen(_onState);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_states?.cancel());
    _origin.dispose();
    _username.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the accessibility page (or from anywhere): ask again.
    if (state == AppLifecycleState.resumed) {
      unawaited(_load());
      unawaited(ref.read(phoneProvider.notifier).refreshStatus());
    }
  }

  void _onState(BridgeStatus state) {
    if (!mounted) return;
    final wasRunning = _config?.running ?? false;
    setState(() => _live = state);
    if (state.running != wasRunning) unawaited(_load());
  }

  Future<void> _load() async {
    final config = await _bridge.config();
    if (!mounted) return;
    setState(() {
      _config = config;
      if (!_seeded && config != null) {
        _seeded = true;
        _origin.text = config.origin ?? '';
        _name.text = config.deviceName;
      }
    });
    final on = await _bridge.a11yEnabled();
    if (mounted) setState(() => _a11yOn = on);
  }

  Future<void> _save() async {
    final origin = _origin.text.trim();
    final name = _name.text.trim();
    if (_issue(origin) != null || _busy) return;
    setState(() => _busy = true);
    final saved = await _bridge.saveConfig(origin: origin, deviceName: name);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!saved) {
      _notice(context.l10n.bridgeSaveFailed);
      return;
    }
    // What the native side kept, not what was typed: normalising differs.
    await _load();
    if (mounted) _notice(context.l10n.bridgeSaved);
  }

  Future<void> _pasteToken() async {
    if (_busy) return;
    String? token;
    try {
      token = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } on PlatformException {
      token = null;
    }
    if (!mounted) return;
    if (token == null || token.isEmpty) {
      _notice(context.l10n.bridgeTokenPasteEmpty);
      return;
    }
    setState(() => _busy = true);
    final saved = await _bridge.setToken(token);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!saved) {
      _notice(context.l10n.bridgeTokenPasteFailed);
      return;
    }
    await _load();
    if (mounted) _notice(context.l10n.bridgeTokenPasted);
  }

  Future<void> _clearToken() async {
    if (_busy) return;
    setState(() => _busy = true);
    final cleared = await _bridge.clearToken();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!cleared) {
      _notice(context.l10n.bridgeTokenPasteFailed);
      return;
    }
    await _load();
    if (mounted) _notice(context.l10n.bridgeTokenCleared);
  }

  /// Signs in to the gateway with the account the user typed, so the token doesn't have to be
  /// copied out of a desktop browser.
  Future<void> _signIn() async {
    if (_busy) return;
    final origin = _origin.text.trim().replaceAll(RegExp(r'/+$'), '');
    final username = _username.text.trim();
    final password = _password.text;
    if (origin.isEmpty || username.isEmpty || password.isEmpty) {
      _notice(context.l10n.bridgeLoginFailed);
      return;
    }
    setState(() => _busy = true);
    final result = await _bridge.gatewayLogin(origin: origin, username: username, password: password);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      _notice(context.l10n.bridgeLoginFailed);
      return;
    }
    _password.clear();
    if (result.config?.origin == null) {
      await _bridge.saveConfig(origin: origin, deviceName: _name.text.trim());
    }
    await _load();
    if (mounted) _notice(context.l10n.bridgeTokenPasted);
  }

  /// Reads the gateway cookie out of this app's own WebView store, so a user who logged into
  /// the gateway inside 网页模式 doesn't have to copy a cookie out of a desktop browser.
  Future<void> _tokenFromWeb() async {
    if (_busy) return;
    final origin = _origin.text.trim();
    if (origin.isEmpty) {
      _notice(context.l10n.bridgeOriginRequired);
      return;
    }
    setState(() => _busy = true);
    final token = await _bridge.gatewayCookie(origin);
    if (!mounted) return;
    if (token == null) {
      setState(() => _busy = false);
      _notice(context.l10n.bridgeTokenFromWebEmpty);
      return;
    }
    final saved = await _bridge.setToken(token);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!saved) {
      _notice(context.l10n.bridgeTokenPasteFailed);
      return;
    }
    await _load();
    if (mounted) _notice(context.l10n.bridgeTokenPasted);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    final running = _live?.running ?? _config?.running ?? false;
    setState(() => _busy = true);
    final ok = running ? await _bridge.stop() : await _bridge.start();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) _notice(running ? context.l10n.bridgeStopFailed : context.l10n.bridgeStartFailed);
    await _load();
  }

  Future<void> _openAccessibility() async {
    // The bridge answers for itself; a build without it can still use the
    // phone channel the settings page next door uses.
    var opened = await _bridge.openAccessibility();
    if (!opened) {
      try {
        opened = await ref.read(phoneChannelProvider).openAccessibilitySettings();
      } on PlatformException {
        opened = false;
      } on MissingPluginException {
        opened = false;
      }
    }
    if (!opened && mounted) _notice(context.l10n.bridgeA11yOpenFailed);
  }

  void _notice(String text) => ScaffoldMessenger.of(context).showBriefNotice(text);

  /// Why [value] can't be an origin, or null when it can. The server compares
  /// `Origin` byte for byte, so a path or a trailing slash in here would only
  /// fail later as a 403 nobody can read.
  String? _issue(String value) {
    final l10n = context.l10n;
    if (value.isEmpty) return l10n.bridgeOriginRequired;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return l10n.bridgeOriginInvalid;
    }
    if (uri.userInfo.isNotEmpty || (uri.path.isNotEmpty && uri.path != '/') || uri.hasQuery || uri.hasFragment) {
      return l10n.bridgeOriginBare;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final config = _config;
    final live = _live;
    final running = live?.running ?? config?.running ?? false;
    final unavailable = config == null;
    final issue = _issue(_origin.text);
    // An empty field is not wrong yet: it is unanswered. Only flag it once
    // something has been typed, or when the button is pressed.
    final shownIssue = _origin.text.trim().isEmpty ? null : issue;
    final insecure = (config?.insecure ?? false) || _typedInsecure;
    final status = (live?.status.isNotEmpty ?? false) ? live!.status : (config?.status ?? '');
    final caps = config?.caps ?? const <String>[];
    final phone = ref.watch(phoneProvider);
    final a11yKnown = phone.loaded && phone.status.ready;
    final a11y = phone.status.a11y;

    return AppPage.list(
      title: l10n.bridgeTitle,
      children: [
        if (insecure)
          PhoneNote(key: const ValueKey('bridge-insecure'), tone: NoteTone.warn, text: l10n.bridgeInsecureWarning),
        if (unavailable)
          PhoneNote(key: const ValueKey('bridge-unavailable'), tone: NoteTone.info, text: l10n.bridgeUnavailable),
        SettingsSection(
          title: l10n.bridgeServerSection,
          footer: Text(l10n.bridgeServerFooter),
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.bridgeOriginLabel,
                  // The server's own address is the hint until one is typed.
                  helper: shownIssue == null ? l10n.bridgeOriginHelper : null,
                  error: shownIssue,
                  child: TextField(
                    key: const ValueKey('bridge-origin'),
                    controller: _origin,
                    enabled: !_busy,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'https://dsh.frankfurtlin.top',
                      error: shownIssue == null ? null : const SizedBox.shrink(),
                    ),
                  ),
                ),
                FormFieldBlock(
                  label: l10n.bridgeDeviceNameLabel,
                  helper: l10n.bridgeDeviceNameHelper,
                  child: TextField(
                    key: const ValueKey('bridge-device-name'),
                    controller: _name,
                    enabled: !_busy,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => unawaited(_save()),
                    decoration: const InputDecoration(hintText: 'android'),
                  ),
                ),
              ],
            ),
            _Actions(
              children: [
                FilledButton(
                  key: const ValueKey('bridge-save'),
                  onPressed: _busy || issue != null ? null : () => unawaited(_save()),
                  child: Text(l10n.bridgeSave),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: l10n.bridgeLoginSection,
          footer: Text(l10n.bridgeLoginFooter),
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.bridgeLoginUsername,
                  child: TextField(
                    key: const ValueKey('bridge-login-username'),
                    controller: _username,
                    enabled: !_busy,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                  ),
                ),
                FormFieldBlock(
                  label: l10n.bridgeLoginPassword,
                  child: TextField(
                    key: const ValueKey('bridge-login-password'),
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => unawaited(_signIn()),
                  ),
                ),
              ],
            ),
            _Actions(
              children: [
                FilledButton(
                  key: const ValueKey('bridge-login-submit'),
                  onPressed: _busy ? null : () => unawaited(_signIn()),
                  child: Text(l10n.bridgeLoginButton),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: l10n.bridgeTokenSection,
          footer: Text(l10n.bridgeTokenFooter),
          children: [
            SettingsTile(
              title: l10n.bridgeTokenLabel,
              value: Text(config?.tokenPresent ?? false ? l10n.bridgeTokenPresent : l10n.bridgeTokenAbsent),
            ),
            _Actions(
              children: [
                OutlinedButton(
                  key: const ValueKey('bridge-token-paste'),
                  onPressed: _busy ? null : () => unawaited(_pasteToken()),
                  child: Text(l10n.bridgeTokenPaste),
                ),
                OutlinedButton(
                  key: const ValueKey('bridge-token-from-web'),
                  onPressed: _busy ? null : () => unawaited(_tokenFromWeb()),
                  child: Text(l10n.bridgeTokenFromWeb),
                ),
                TextButton(
                  key: const ValueKey('bridge-token-clear'),
                  onPressed: _busy || !(config?.tokenPresent ?? false) ? null : () => unawaited(_clearToken()),
                  child: Text(l10n.bridgeTokenClear),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: l10n.bridgeConnectionSection,
          children: [
            _Actions(
              children: [
                FilledButton(
                  key: const ValueKey('bridge-toggle'),
                  onPressed: _busy || unavailable ? null : () => unawaited(_toggle()),
                  child: Text(running ? l10n.bridgeDisconnect : l10n.bridgeConnect),
                ),
              ],
            ),
            if (status.isNotEmpty) _Note(key: const ValueKey('bridge-status'), text: status),
            if (caps.isNotEmpty) InfoRow(label: l10n.bridgeCapsLabel, value: caps.length.toString()),
          ],
        ),
        SettingsSection(
          title: l10n.bridgeA11ySection,
          footer: Text(l10n.bridgeA11yHint),
          children: [
            if (a11yKnown)
              SettingsTile(title: l10n.bridgeA11yState, value: Text(a11y.ok ? l10n.bridgeA11yOn : l10n.bridgeA11yOff)),
            SettingsSwitchTile(
              title: l10n.bridgeA11yAllow,
              value: _a11yOn,
              onChanged: _busy
                  ? null
                  : (on) async {
                      final applied = await _bridge.setA11yEnabled(on);
                      if (!mounted) return;
                      setState(() => _a11yOn = on && applied);
                    },
            ),
            SettingsTile(title: l10n.bridgeA11yOpen, onTap: () => unawaited(_openAccessibility())),
          ],
        ),
      ],
    );
  }

  /// The address as typed, for the warning — before anyone saved it.
  bool get _typedInsecure {
    final uri = Uri.tryParse(_origin.text.trim());
    if (uri == null || uri.scheme != 'http') return false;
    final host = uri.host;
    return host.isNotEmpty && host != '127.0.0.1' && host != 'localhost' && host != '::1';
  }
}

/// A row of card buttons: 16 in from the card edge, 12 between them.
class _Actions extends StatelessWidget {
  const _Actions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 4, SettingsMetrics.inset, SettingsMetrics.inset),
    child: Row(
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const SizedBox(width: 12),
          if (index == 0) Expanded(child: child) else child,
        ],
      ],
    ),
  );
}

/// The native side's sentence under the button, in the secondary colour.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 0, SettingsMetrics.inset, 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary, height: 1.5),
      ),
    );
  }
}

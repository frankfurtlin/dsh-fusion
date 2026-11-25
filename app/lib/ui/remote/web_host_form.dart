// 网页登录主机的表单：网址 + 账号 + 密码，和浏览器登录同一个入口
// （dsh-passwords 网关）。密码存进安全存储，别处不落盘。
//
// 和 SSH 表单的区别是有意的：没有端口、没有私钥、没有主机指纹、没有「实例管理」——
// 那些是给「自己有服务器」的人准备的；这里只有三样东西。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/web/gateway_login.dart';
import '../../remote/web/web_host_config.dart';
import '../../state/hosts_state.dart';
import '../common/brief_notice.dart';
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

class WebHostFormPage extends ConsumerStatefulWidget {
  const WebHostFormPage({super.key, this.existing});

  /// Null to add a new host.
  final WebHostConfig? existing;

  @override
  ConsumerState<WebHostFormPage> createState() => _WebHostFormPageState();
}

class _WebHostFormPageState extends ConsumerState<WebHostFormPage> {
  late final String _id = widget.existing?.id ?? WebHostConfig.newId();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _url = TextEditingController(text: widget.existing?.baseUrl ?? '');
  late final _account = TextEditingController(text: widget.existing?.username ?? '');
  final _password = TextEditingController();
  bool _saving = false;
  bool _testing = false;
  String? _urlError;
  String? _error;
  HostLinkErrorText? _testResult;

  bool get _editing => widget.existing != null;

  /// The password to save: a freshly typed one, or (editing) null to keep the
  /// stored one. Empty text on a new host is a validation error.
  String? get _typedPassword => _password.text.isEmpty ? null : _password.text;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _validBase() {
    final normalized = WebHostConfig.normalizeBaseUrl(_url.text);
    _urlError = normalized == null ? appL10n.webLoginErrUrl : null;
    return normalized;
  }

  Future<void> _test() async {
    final l10n = appL10n;
    final base = _validBase();
    final password = _typedPassword;
    if (base == null) {
      setState(() {});
      return;
    }
    if (base.isEmpty || _account.text.trim().isEmpty || password == null) {
      setState(() => _error = l10n.webLoginErrMissing);
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
      _testResult = null;
    });
    try {
      final session = await GatewayLogin().login(
        Uri.parse(base),
        username: _account.text.trim(),
        password: password,
      );
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = HostLinkErrorText.ok(l10n.webLoginTestOk, session.expiresAt);
      });
    } on GatewayLoginError catch (error) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = HostLinkErrorText.failed(error.message, error.detail);
      });
    } finally {
      if (mounted && _testing) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final l10n = appL10n;
    final base = _validBase();
    final account = _account.text.trim();
    final password = _typedPassword;
    if (base == null) {
      setState(() {});
      return;
    }
    final needsPassword = !_editing && password == null;
    if (base.isEmpty || account.isEmpty || needsPassword) {
      setState(() => _error = l10n.webLoginErrMissing);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final config = WebHostConfig(
      id: _id,
      name: _name.text.trim(),
      baseUrl: base,
      username: account,
    );
    final hosts = ref.read(hostsProvider.notifier);
    final saved = await hosts.saveWeb(config, password: password);
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _saving = false;
        _error = l10n.commonSaveFailed;
      });
      return;
    }
    showBriefNotice(context, l10n.webLoginSaved);
    Navigator.of(context).pop(config);
  }

  Future<void> _delete() async {
    final l10n = appL10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.webLoginRemove),
        content: Text(l10n.webLoginRemoveHint),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(hostsProvider.notifier).removeWeb(_id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final error = _testResult;
    return AppPage.list(
      title: _editing ? l10n.webLoginEdit : l10n.webLoginAdd,
      subtitle: Text(l10n.webLoginIntro),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.remoteHostBasicInfo,
              footer: _editing ? Text(l10n.webLoginPasswordSaved) : null,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(hintText: 'dsh'),
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.webLoginUrl,
                      error: _urlError,
                      child: TextField(
                        controller: _url,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) => setState(() => _urlError = null),
                        decoration: InputDecoration(hintText: l10n.webLoginUrlHint),
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.webLoginAccount,
                      child: TextField(
                        controller: _account,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(),
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.webLoginPassword,
                      child: TextField(
                        controller: _password,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _save(),
                        decoration: InputDecoration(hintText: l10n.webLoginPasswordHint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      error.ok ? AppIcons.done : AppIcons.warning,
                      size: 18,
                      color: error.ok ? theme.colorScheme.primary : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        error.ok ? error.message : l10n.remoteErrorDetail(error.message, error.detail ?? ''),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: error.ok ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (_error case final message?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Text(message, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _testing || _saving ? null : _test,
                      icon: _testing
                          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(AppIcons.testConnection, size: 19),
                      label: Text(_testing ? l10n.webLoginTesting : l10n.webLoginTest),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
            ),
            if (_editing)
              Center(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(AppIcons.delete, size: 19),
                  label: Text(l10n.webLoginRemove),
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ],
    );
  }
}

/// 「测试连接」的结果：成功一行，失败带详情。
class HostLinkErrorText {
  const HostLinkErrorText._(this.ok, this.message, this.detail, this.at);

  factory HostLinkErrorText.ok(String message, DateTime? at) => HostLinkErrorText._(true, message, null, at);
  factory HostLinkErrorText.failed(String message, String? detail) => HostLinkErrorText._(false, message, detail, null);

  final bool ok;
  final String message;
  final String? detail;
  final DateTime? at;
}

// The dsh-pocket-ui skill that teaches a host's agent to edit ui.json. The files
// ship in assets/skills/dsh-pocket-ui/ (flat; manifest.json maps each to its place
// in the skill folder).
//
// 手机本地引擎已删除（2026-11-26）：本机 rootfs 写入与内置技能的自动安装
// 随之删除。现在只剩远程主机这一条路 —— 由本人确认后
// （[UiSkillRemoteInstaller]）用 SSH 的 [uiSkillShellScript] 或交给 agent 的
// [uiSkillInstallPrompt] 安装；不确认就不装。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';

const uiSkillName = 'dsh-pocket-ui';
const uiSkillAssetDir = 'assets/skills/dsh-pocket-ui/';

/// The second skill the app ships: teaches a host's agent to write a small
/// local native plugin (sdk/plugin-kit/skill, built into
/// assets/skills/dsh-pocket-plugin/ by sdk/plugin-kit/scripts/sync-skill.mjs).
/// Installed and kept current exactly like [uiSkillName], in its own folder.
const pluginSkillName = 'dsh-pocket-plugin';

/// The fourth: troubleshooting and bug-report playbook. Turns a symptom into a
/// redacted environment summary / issue draft from the report the person
/// pastes in (手机本地引擎已删除：不再往 rootfs 写诊断快照).
const supportSkillName = 'dsh-pocket-support';

/// Uses the same report, prompt and checked adapter as companion light mode.
const companionAdaptSkillName = 'companion-adapt';

typedef UiSkillBundleLoader = Future<UiSkillBundle> Function();

/// Reads the skill the app ships, for the remote 「安装技能」 card.
final uiSkillBundleLoaderProvider = Provider<UiSkillBundleLoader>((ref) => loadUiSkillBundle);

/// The managed line inside SKILL.md's front matter.
const uiSkillManagedMarker = '# dsh-pocket:managed';

/// Markers that make a skill folder "managed" (safe to overwrite): the current
/// one plus the one earlier releases wrote, so installs from before the rename
/// keep getting updated instead of counting as user-owned.
const uiSkillManagedMarkers = [uiSkillManagedMarker, '# dsh-go:managed'];

final _safePath = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$');

/// The skill's files: path inside the skill folder → text.
class UiSkillBundle {
  UiSkillBundle(Map<String, String> files, {this.name = uiSkillName})
    : files = Map.unmodifiable({
        for (final MapEntry(:key, :value) in files.entries)
          if (_safePath.hasMatch(key)) key: value,
      });

  final Map<String, String> files;

  /// The skill's folder name under `$DSH_HOME/skills/`.
  final String name;

  String get skillMd => files['SKILL.md'] ?? '';

  /// SKILL.md last, so DSH never sees the skill before its files.
  List<MapEntry<String, String>> get writeOrder => [
    ...files.entries.where((e) => e.key != 'SKILL.md'),
    ...files.entries.where((e) => e.key == 'SKILL.md'),
  ];
}

typedef UiAssetReader = Future<String> Function(String key);

/// Reads a bundled skill (manifest first): [uiSkillName] unless [name] says
/// otherwise.
Future<UiSkillBundle> loadUiSkillBundle([UiAssetReader? read, String name = uiSkillName, String? os]) async {
  final reader = read ?? rootBundle.loadString;
  final assetDir = 'assets/skills/$name/';
  final manifest = jsonDecode(await reader('${assetDir}manifest.json'));
  final files = (manifest as Map)['files'] as Map;
  // What HarmonyOS says differently takes the same path, so nothing of Android's
  // is left behind when it installs over an earlier copy.
  final harmony = os == 'ohos' ? manifest['harmony'] as Map? : null;
  final assets = {
    for (final MapEntry(key: asset, value: target) in files.entries) '$target': '$asset',
    if (harmony != null)
      for (final MapEntry(key: asset, value: target) in harmony.entries) '$target': '$asset',
  };
  return UiSkillBundle({
    for (final MapEntry(key: target, value: asset) in assets.entries) target: await reader('$assetDir$asset'),
  }, name: name);
}

// ── Remote hosts ────────────────────────────────────────────────────────────

/// Installs the skill on a remote host after the person agreed. The app's
/// wiring provides one (SSH: [uiSkillShellScript] over the host's shell;
/// relay: [uiSkillInstallPrompt] into the composer for the person to send);
/// without one, no install entry is shown.
abstract interface class UiSkillRemoteInstaller {
  /// Returns whether the skill was written (or the message handed over).
  Future<bool> install(BuildContext context, HostRef host, UiSkillBundle bundle);
}

final uiSkillRemoteInstallerProvider = Provider<UiSkillRemoteInstaller?>((ref) => null);

/// A POSIX `sh` script that writes [bundle] to
/// `${DSH_HOME:-$HOME/.dsh}/skills/dsh-pocket-ui/` (leaving a folder the person
/// took over alone) and prints `DSHAPP skill=installed` or
/// `DSHAPP skill=user-owned`.
String uiSkillShellScript(UiSkillBundle bundle) {
  final out = StringBuffer()
    ..writeln('set -e')
    ..writeln('d="\${DSH_HOME:-\$HOME/.dsh}/skills/${bundle.name}"')
    ..writeln(
      'if [ -f "\$d/SKILL.md" ] && ! grep -q -e \'^ *$uiSkillManagedMarker\' '
      "-e '^ *${uiSkillManagedMarkers[1]}' \"\$d/SKILL.md\"; then "
      "echo 'DSHAPP skill=user-owned'; exit 0; fi",
    );
  final dirs = {
    for (final path in bundle.files.keys)
      if (path.contains('/')) path.substring(0, path.lastIndexOf('/')),
  };
  out.writeln('mkdir -p "\$d"${dirs.map((d) => ' "\$d/$d"').join()}');
  var n = 0;
  for (final MapEntry(key: path, value: text) in bundle.writeOrder) {
    var tag = 'DSHGO_EOF_$n';
    while (text.split('\n').contains(tag)) {
      tag = '${tag}_';
    }
    n++;
    final body = text.endsWith('\n') ? text : '$text\n';
    out
      ..writeln("cat > \"\$d/$path.dsh-go-tmp\" <<'$tag'")
      ..write(body)
      ..writeln(tag)
      ..writeln('mv "\$d/$path.dsh-go-tmp" "\$d/$path"');
  }
  out.writeln("echo 'DSHAPP skill=installed'");
  return out.toString();
}

/// A message for the remote agent: the skill's working files and where to
/// put them. The person sends it themself.
String uiSkillInstallPrompt(UiSkillBundle bundle) {
  final out = StringBuffer()
    ..writeln(appL10n.shellSkillInstallPrompt(uiSkillName))
    ..writeln()
    ..writeln(appL10n.shellSkillInstallDirectory(uiSkillName))
    ..writeln(appL10n.shellSkillInstallFiles)
    ..writeln(
      appL10n.shellSkillInstallCheck('`node "\${DSH_HOME:-\$HOME/.dsh}/skills/$uiSkillName/scripts/check.mjs"`'),
    )
    ..writeln(appL10n.shellSkillInstallConfirm);
  for (final path in const ['SKILL.md', 'schema.json', 'scripts/check.mjs']) {
    final text = bundle.files[path];
    if (text == null) continue;
    final lang = switch (path.split('.').last) {
      'md' => 'markdown',
      'json' => 'json',
      _ => 'js',
    };
    out
      ..writeln()
      ..writeln(appL10n.shellSkillInstallFile(path))
      ..writeln()
      ..writeln('````$lang')
      ..write(text.endsWith('\n') ? text : '$text\n')
      ..writeln('````');
  }
  return out.toString();
}

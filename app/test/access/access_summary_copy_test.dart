// The permission copy names where things live in 设置; the names must be the
// way there as the settings hub has it (系统权限 and 语音 sit under 通用), in
// both languages (0.9.8 smoke 02w).
//
// 1.2.0: 首启的收尾页删掉了，这两句现在没有界面用；留着它们是因为设置里的
// 位置（设置 › 通用 › ...）改了就得跟着改。

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final locale in [AppLocale.zhCN, AppLocale.en]) {
    test('summary paths follow the settings hub: ${locale.languageCode}', () {
      final l10n = lookupL10n(locale);
      String way(SettingsPageId id) => SettingsIndex.path(SettingsIndex.entry(id), l10n).join(' › ');
      final access = way(SettingsPageId.systemAccess);
      final voice = way(SettingsPageId.voice);
      expect(access, locale == AppLocale.en ? 'Settings › General › System permissions' : '设置 › 通用 › 系统权限');
      expect(voice, locale == AppLocale.en ? 'Settings › General › Voice' : '设置 › 通用 › 语音');
      expect(l10n.accessSummaryMessage, contains(access));
      expect(l10n.accessVoiceDownload, contains(voice));
    });
  }
}

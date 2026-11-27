// Golden baselines for the pages the app still has after 1.2.2 (local engine,
// account and tavern removed). They pin layout, grouping and which rows exist —
// not glyphs: Flutter tests render text in the Ahem block font, so every CJK
// character shows as a box. That is fine here (the baseline is self-consistent
// and the pages' text is asserted separately where it matters), but never read
// a baseline for wording.
//
// 字形为 Ahem（Flutter 测试的默认字体，中文会渲染成方块），基线只验证布局、
// 分组与行数，不验证文案或字形。Glyphs are Ahem: layout only, never wording.
//
// Everything below is deterministic: a fixed 1080×2400 surface at dpr 3 (a
// 360×800 logical phone; the settings hub and 全部功能 get a taller surface so
// their groups fit), a pinned text scale, fixed frame pumps instead of timers,
// and providers overridden or fed from mock preferences. No test opens a
// socket: there is no active host in any of them, so the host link, session
// list and plugin inventory all resolve to their "not connected" values.
//
// Regenerate the baselines after an intended UI change:
//   flutter test --update-goldens test/golden
// Then run it without --update-goldens to prove the baselines match.
//
// 兴趣推送 (DigestPage) reads its cached snapshot through the
// `top.frankfurtlin.dshfusion/digest` method channel (the Kotlin side does the
// download); the test hands that channel a fixed payload, so no request leaves
// the process and the page's two item cards come from a constant.

import 'dart:convert';

import 'package:dsh_app/digest/digest_page.dart';
import 'package:dsh_app/digest/digest_tile.dart' show DigestTile;
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/web/web_host_config.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/ui/common/feature_tile.dart';
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/settings/voice_settings_page.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/terminal/terminal_screen.dart' show TerminalCardFrame;
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart' show TerminalEnvironment, TerminalInfo, TerminalShell;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show Terminal;

/// A 360×800 logical phone.
const _phone = Size(1080, 2400);

/// 360×1300 logical: tall enough for the hub's first three groups at once.
const _tallPage = Size(1080, 3900);

const _dpr = 3.0;

final _zh = lookupL10n(AppLocale.zhCN);

/// Give async providers a fixed number of frames; never wait on real time.
Future<void> _frames(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  Widget home, {
  List<Override> overrides = const [],
  Size physical = _phone,
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = _dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        locale: AppLocale.zhCN,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: L10n.localizationsDelegates,
        // Pin the text scale: a desktop with a system text size would
        // otherwise reflow every row and break the baseline.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const digestChannel = MethodChannel('top.frankfurtlin.dshfusion/digest');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.zhCN);
    messenger.setMockMethodCallHandler(digestChannel, (call) async {
      switch (call.method) {
        case 'load':
        case 'refresh':
          return {'enabled': true, 'json': jsonEncode(_digestFeed)};
        case 'setEnabled':
          return true;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(digestChannel, null));

  testWidgets('settings hub: AI / 能力 / 外观 with 兴趣推送 still there', (tester) async {
    await _pumpPage(
      tester,
      const SettingsScreen(),
      overrides: [operatingSystemProvider.overrideWithValue('android')],
      physical: _tallPage,
    );
    expect(find.text(_zh.hubGroupAi), findsOneWidget);
    expect(find.text(_zh.hubGroupCapabilities), findsOneWidget);
    expect(find.text(_zh.hubSettingsAppearance), findsOneWidget);
    expect(find.text(_zh.digestPushSubtitle), findsOneWidget);
    await expectLater(find.byType(SettingsScreen), matchesGoldenFile('golden/settings_hub_zh.png'));
  });

  testWidgets('remote hosts: a web-login row and both add entries, offline', (tester) async {
    const host = WebHostConfig(id: 'web-golden', name: 'dsh', baseUrl: 'https://dsh.example.com', username: 'frank');
    SharedPreferences.setMockInitialValues({
      HostsController.webPrefsKey: jsonEncode([host.toJson()]),
    });
    await _pumpPage(
      tester,
      const RemoteScreen(),
      overrides: [
        operatingSystemProvider.overrideWithValue('android'),
        // The relay stays off: no socket, and the page's relay row is absent.
        relayBackendProvider.overrideWithValue(const UnavailableRelayBackend()),
      ],
    );
    expect(find.text(_zh.webLoginTitle), findsOneWidget);
    expect(find.text('dsh'), findsOneWidget);
    expect(find.text('frank@dsh.example.com'), findsOneWidget);
    expect(find.text(_zh.webLoginAdd), findsOneWidget);
    expect(find.text(_zh.remoteSshHosts), findsOneWidget);
    expect(find.text(_zh.remoteSshDirect), findsOneWidget);
    await expectLater(find.byType(RemoteScreen), matchesGoldenFile('golden/remote_hosts_zh.png'));
  });

  testWidgets('voice settings: 自动 / 系统 / 自定义云端转写, no 语音模型 block', (tester) async {
    await _pumpPage(
      tester,
      const VoiceSettingsPage(),
      overrides: [operatingSystemProvider.overrideWithValue('android')],
    );
    for (final mode in ['auto', 'system', 'cloud']) {
      expect(find.byKey(ValueKey('voice-mode-$mode')), findsOneWidget);
    }
    expect(find.text(_zh.voiceModeAuto), findsOneWidget);
    expect(find.text(_zh.voiceModeSystem), findsOneWidget);
    expect(find.text(_zh.voiceModeCloud), findsOneWidget);
    // 语音模型（SenseVoice）卡随手机本地引擎在 1.2.0 删除。这一页还在的下载块
    // 是「流式识别模型」（实时字幕用），不是被删的「语音模型」。
    expect(find.text(_zh.speechLiveName), findsOneWidget);
    await expectLater(find.byType(VoiceSettingsPage), matchesGoldenFile('golden/voice_settings_zh.png'));
  });

  testWidgets('interest feed: the item cards', (tester) async {
    await _pumpPage(tester, const DigestPage(), overrides: [operatingSystemProvider.overrideWithValue('android')]);
    // The AppBar title and the switch row share the word 兴趣推送.
    expect(find.text(_zh.digestPushTitle), findsWidgets);
    expect(find.byType(DigestTile), findsNWidgets(2));
    expect(find.text('手机端 golden 基线'), findsOneWidget);
    await expectLater(find.byType(DigestPage), matchesGoldenFile('golden/digest_zh.png'));
  });

  testWidgets('terminal page: the dark card, its tabs and the key row', (tester) async {
    await _pumpPage(
      tester,
      const TerminalPage(sessionId: _terminalSession),
      overrides: [
        operatingSystemProvider.overrideWithValue('android'),
        terminalWorkspaceProvider(_terminalSession).overrideWith(() => _GoldenTerminalWorkspace(_terminalSession)),
      ],
    );
    expect(find.text(_zh.botsTerminal), findsWidgets);
    // The screen is xterm's own painter (no Flutter text widgets inside the
    // card), so assert the card and the key row's own widgets by type/key.
    expect(find.byType(TerminalCardFrame), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-new')), findsOneWidget);
    await expectLater(find.byType(TerminalPage), matchesGoldenFile('golden/terminal_zh.png'));
  });

  testWidgets('all features: the feature grid', (tester) async {
    await _pumpPage(
      tester,
      const AllFeaturesPage(),
      overrides: [operatingSystemProvider.overrideWithValue('android')],
      physical: _tallPage,
    );
    expect(find.text(_zh.catalogAllFeatures), findsWidgets);
    expect(find.byType(FeatureTile), findsWidgets);
    await expectLater(find.byType(AllFeaturesPage), matchesGoldenFile('golden/all_features_zh.png'));
  });
}

/// A terminal page with one live tab, no Host behind it. The tab's screen has
/// a little output so the golden shows the card's real geometry; input stays
/// writable so the key row is drawn enabled.
const _terminalSession = 'golden-session';

class _GoldenTerminalWorkspace extends TerminalWorkspace {
  _GoldenTerminalWorkspace(super.sessionId);

  @override
  TerminalWorkspaceState build() {
    final terminal = Terminal(maxLines: 1000)
      ..write('\$ dsh --version\r\n')
      ..write('1.2.2\r\n')
      ..write('\$ ls\r\n')
      ..write('app  docs  packages  tooling\r\n')
      ..write('\$ ');
    return TerminalWorkspaceState(
      loading: false,
      tabs: [
        TerminalTab(
          id: 'golden-tab',
          terminal: terminal,
          title: 'zsh',
          phase: TerminalPhase.live,
          writable: true,
          info: const TerminalInfo(
            id: 'golden-tab',
            title: 'zsh',
            shell: TerminalShell(path: '/bin/zsh', name: 'zsh'),
            cwd: '/home/me/project',
          ),
        ),
      ],
      selectedId: 'golden-tab',
      environment: const TerminalEnvironment(cwd: '/home/me/project'),
    );
  }
}

/// A fixed feed for 兴趣推送: enough for two cards, no URL that a tap could open.
const _digestFeed = {
  'generatedAt': '2026-11-27T08:00:00+08:00',
  'items': [
    {
      'id': 'item-1',
      'title': '手机端 golden 基线',
      'summary': '为当前界面固定视觉基线，防止布局回归。',
      'source': 'DSH Pocket',
      'url': '',
      'publishedAt': '2026-11-27',
      'tags': ['测试', '界面'],
    },
    {
      'id': 'item-2',
      'title': '删掉的东西不再回来',
      'summary': '本机引擎、账号与酒馆页面都已移除。',
      'source': 'DSH Pocket',
      'url': '',
      'publishedAt': '2026-11-26',
      'tags': ['记录'],
    },
  ],
};

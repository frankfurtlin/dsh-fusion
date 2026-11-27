// The system-permission pages on HarmonyOS: notifications are asked for with
// the system's dialog, and only what works there is read or offered. Android
// beside it wherever the OS is a parameter.
//
// 1.2.0: 首启的「想让 DSH Pocket 帮你做哪些事」页面（选、走、收尾）删掉了，这个
// 文件只剩和它一起活下来的部分：通知权限的对话框、按系统分项、一步的走法、
// 设置 › 系统权限，以及搜索里的入口。首启那几组随页面一起删。

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/notify_channel.dart';
import 'package:dsh_app/state/access_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/access/access_walk.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:dsh_app/ui/settings/system_access_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _primary = ValueKey('access-primary');

final _zh = lookupL10n(AppLocale.zhCN);
final _en = lookupL10n(AppLocale.en);

/// 「一步」的一步：原样读手机，[open] 记下每一次打开，可以答「打开后是什么」。
class FakeAccessDriver implements AccessDriver {
  FakeAccessDriver(this.readings, {this.answer});

  AccessReadings readings;
  AccessReadings Function(AccessItem item, AccessReadings readings)? answer;

  /// `notifications` / `notifications+`（[again]）。
  final opened = <String>[];
  var appInfoOpened = 0;

  @override
  Future<AccessReadings> read() async => readings;

  @override
  Future<bool> open(AccessItem item, {bool again = false}) async {
    opened.add(again ? '${item.name}+' : item.name);
    if (answer case final answer?) readings = answer(item, readings);
    return true;
  }

  @override
  Future<bool> openAppInfo() async {
    appInfoOpened++;
    return true;
  }
}

Future<void> _frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _primaryLabel(WidgetTester tester) => (tester.widget<FilledButton>(find.byKey(_primary)).child! as Text).data!;

/// A phone-sized screen with the app's theme and localizations, no engine behind it.
Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  List<Override> overrides = const [],
  Locale locale = AppLocale.zhCN,
  Size logicalSize = const Size(360, 780),
}) async {
  tester.view.physicalSize = logicalSize * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: locale,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: L10n.localizationsDelegates,
        home: home,
      ),
    ),
  );
  await _frames(tester);
}

/// 人去了系统设置又回来：挂起、恢复，页面重新读一遍。
Future<void> _awayAndBack(WidgetTester tester) async {
  for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pump();
  for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const notify = MethodChannel('dsh/notify');
  const voice = MethodChannel('dsh/voice');
  final calls = <String>[];
  late Future<Object?> Function(MethodCall) answer;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    answer = (_) async => true;
    messenger.setMockMethodCallHandler(notify, (call) {
      calls.add(call.method);
      return answer(call);
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(notify, null);
    messenger.setMockMethodCallHandler(voice, null);
  });

  group('the channel\'s permission dialog', () {
    test('answers what the native side says; refused is false', () async {
      expect(await NotifyChannel().requestPermission(), isTrue);
      answer = (_) async => false;
      expect(await NotifyChannel().requestPermission(), isFalse);
      expect(calls, ['requestPermission', 'requestPermission']);
    });

    test('a failure or no native side is not a grant', () async {
      answer = (_) async => throw PlatformException(code: 'no_ability');
      expect(await NotifyChannel().requestPermission(), isFalse);
      messenger.setMockMethodCallHandler(notify, null);
      expect(await NotifyChannel().requestPermission(), isFalse);
    });
  });

  group('notifications, by OS', () {
    test('a dialog item on HarmonyOS only', () {
      expect(AccessItem.notifications.dialogOn('ohos'), isTrue);
      expect(AccessItem.notifications.dialogOn('ios'), isTrue);
      expect(AccessItem.notifications.dialogOn('android'), isFalse);
      for (final item in AccessItem.values.where((i) => i != AccessItem.notifications)) {
        expect(item.dialogOn('ohos'), item.dialogOn('android'), reason: item.name);
      }
    });

    AccessDriver driver(String os) {
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue(os)]);
      addTearDown(container.dispose);
      return container.read(accessDriverProvider);
    }

    test('HarmonyOS: the first try asks, again opens settings', () async {
      final phone = driver('ohos');
      expect(await phone.open(AccessItem.notifications), isTrue);
      expect(calls, ['requestPermission']);
      expect(await phone.open(AccessItem.notifications, again: true), isTrue);
      expect(calls, ['requestPermission', 'openSettings']);
    });

    test('HarmonyOS: a refusal or a failed dialog still came back, for the step to say so', () async {
      final phone = driver('ohos');
      answer = (_) async => false;
      expect(await phone.open(AccessItem.notifications), isTrue);
      answer = (_) async => throw PlatformException(code: 'no_ability');
      expect(await phone.open(AccessItem.notifications), isTrue);
    });

    test('Android: settings, first and again', () async {
      final phone = driver('android');
      expect(await phone.open(AccessItem.notifications), isTrue);
      expect(await phone.open(AccessItem.notifications, again: true), isTrue);
      expect(calls, ['openSettings', 'openSettings']);
    });
  });

  group('the step', () {
    Future<FakeAccessDriver> pump(WidgetTester tester, String os) async {
      final phone = FakeAccessDriver(const AccessReadings(mic: true, notifications: false));
      await _pump(
        tester,
        AccessWalk(items: const [AccessItem.notifications], onDone: () {}),
        overrides: [accessDriverProvider.overrideWithValue(phone), operatingSystemProvider.overrideWithValue(os)],
      );
      return phone;
    }

    testWidgets('on HarmonyOS the dialog answers at once; 重试 goes to settings', (tester) async {
      final phone = await pump(tester, 'ohos');
      expect(_primaryLabel(tester), _zh.accessTurnOn);
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications']);
      expect(find.text(_zh.accessNotOnYet), findsOneWidget);
      expect(_primaryLabel(tester), _zh.commonRetry);

      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications', 'notifications+']);
    });

    testWidgets('on HarmonyOS allowed in the dialog: its check, without leaving the app', (tester) async {
      final phone = await pump(tester, 'ohos');
      phone.answer = (_, r) => const AccessReadings(mic: true, notifications: true);
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(find.text(_zh.accessIsOn), findsOneWidget);
    });

    testWidgets('on Android a settings page: nothing to say until the person is back', (tester) async {
      final phone = await pump(tester, 'android');
      await tester.tap(find.byKey(_primary));
      await _frames(tester);
      expect(phone.opened, ['notifications']);
      expect(find.text(_zh.accessNotOnYet), findsNothing);
      await _awayAndBack(tester);
      expect(find.text(_zh.accessNotOnYet), findsOneWidget);
    });

    testWidgets('why it asks: on HarmonyOS only while the app runs', (tester) async {
      await pump(tester, 'ohos');
      expect(find.text(_zh.harmonyNotifyWhy), findsOneWidget);
      expect(find.text(_zh.accessNotifyWhy), findsNothing);
    });

    testWidgets('why it asks: on Android as ever', (tester) async {
      await pump(tester, 'android');
      expect(find.text(_zh.accessNotifyWhy), findsOneWidget);
      expect(find.text(_zh.harmonyNotifyWhy), findsNothing);
    });
  });

  group('what each OS offers', () {
    test('Android: exactly what it always had, in that order, never 回复提醒', () {
      expect(accessFeaturesFor('android'), [
        AccessFeature.files,
        AccessFeature.pet,
        AccessFeature.phone,
        AccessFeature.background,
        AccessFeature.voice,
      ]);
      expect(accessFeaturesFor('linux'), accessFeaturesFor('android'));
    });

    test('HarmonyOS: 回复提醒 and 语音输入, which ask for notifications and the microphone, and 系统操作', () {
      expect(accessFeaturesFor('ohos'), [AccessFeature.alerts, AccessFeature.systemActions, AccessFeature.voice]);
      expect(accessFeaturesFor('ios'), [AccessFeature.alerts, AccessFeature.voice]);
      expect(accessItemsFor(AccessFeature.alerts, null), [AccessItem.notifications]);
      expect(accessItemsFor(AccessFeature.systemActions, null), isEmpty, reason: 'no permission of its own');
      // A maker's name changes nothing: none of its switches belong to these.
      expect(accessWalk(accessFeaturesFor('ohos'), 'huawei'), [AccessItem.mic, AccessItem.notifications]);
    });
  });

  group('picks kept across a kill', () {
    Future<AccessSetup> reload(String stored) async {
      SharedPreferences.setMockInitialValues({AccessSetupController.prefsKey: stored});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(accessSetupProvider);
      await Future<void>.delayed(Duration.zero);
      return container.read(accessSetupProvider);
    }

    test('回复提醒 comes back', () async {
      final setup = await reload('{"features":["alerts","voice"],"skipped":[]}');
      expect(setup.features, {AccessFeature.alerts, AccessFeature.voice});
    });

    test('a name this build doesn\'t know is passed over', () async {
      final setup = await reload('{"features":["alerts","later"],"skipped":[]}');
      expect(setup.features, {AccessFeature.alerts});
    });
  });

  group('the readings on HarmonyOS', () {
    test('only the two it offers: storage, battery and the rest are not asked for', () async {
      messenger.setMockMethodCallHandler(voice, (call) async => call.method == 'permission' ? 'denied' : null);
      answer = (call) async => {'enabled': false, 'done': false, 'attention': false};
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
      addTearDown(container.dispose);
      final r = await container.read(accessDriverProvider).read();
      expect(r.mic, isFalse);
      expect(r.notifications, isFalse);
      for (final item in AccessItem.values.where(
        (i) => !i.vendor && i != AccessItem.mic && i != AccessItem.notifications,
      )) {
        expect(accessStateOf(item, r, const {}), isNull, reason: item.name);
      }
      expect(r.metered, isNull);
    });

    test('no answer from a channel is no reading, not an off', () async {
      messenger.setMockMethodCallHandler(notify, null);
      messenger.setMockMethodCallHandler(voice, (call) async => throw PlatformException(code: 'no_ability'));
      final container = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
      addTearDown(container.dispose);
      final r = await container.read(accessDriverProvider).read();
      expect(accessStateOf(AccessItem.notifications, r, const {}), isNull);
      expect(accessStateOf(AccessItem.mic, r, const {}), isNull);
    });
  });

  group('设置 › 系统权限', () {
    Future<void> page(WidgetTester tester, String os, {Locale locale = AppLocale.zhCN}) async {
      await _pump(
        tester,
        const SystemAccessPage(),
        locale: locale,
        overrides: [
          accessDriverProvider.overrideWithValue(
            FakeAccessDriver(const AccessReadings(mic: true, notifications: false)),
          ),
          operatingSystemProvider.overrideWithValue(os),
        ],
      );
    }

    testWidgets('on HarmonyOS: 回复提醒 and 语音输入 with their states, nothing falsely off', (tester) async {
      await page(tester, 'ohos');
      expect(find.byKey(const ValueKey('access-section-alerts')), findsOneWidget);
      expect(find.byKey(const ValueKey('access-section-voice')), findsOneWidget);
      // 系统操作 included: it has no permission to list here.
      for (final other in ['files', 'pet', 'phone', 'background', 'systemActions']) {
        expect(find.byKey(ValueKey('access-section-$other')), findsNothing, reason: other);
      }
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-notifications')), matching: find.text(_zh.accessStateOff)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-mic')), matching: find.text(_zh.accessStateOn)),
        findsOneWidget,
      );
      expect(find.text(_zh.accessStateOff), findsOneWidget);
    });

    test('the subtitle names the right system', () {
      expect(_en.accessPageSubtitle, contains('Android'));
      expect(_en.harmonyAccessSubtitle, contains('HarmonyOS'));
      expect(_en.harmonyAccessSubtitle, isNot(contains('Android')));
    });

    testWidgets('on HarmonyOS the subtitle is its own', (tester) async {
      await page(tester, 'ohos', locale: AppLocale.en);
      expect(find.text(_en.harmonyAccessSubtitle), findsOneWidget);
      expect(find.text(_en.accessPageSubtitle), findsNothing);
    });

    testWidgets('on Android: every feature, each item with where it stands', (tester) async {
      await _pump(
        tester,
        const SystemAccessPage(),
        // Tall enough that the lazy list builds every section.
        logicalSize: const Size(360, 2400),
        overrides: [
          accessDriverProvider.overrideWithValue(
            FakeAccessDriver(
              const AccessReadings(
                vendor: 'vivo',
                appLabel: 'DSH Pocket',
                mic: true,
                storage: false,
                notifications: true,
                battery: false,
                accessibility: false,
                overlay: true,
                sdk: 34,
              ),
            ),
          ),
          operatingSystemProvider.overrideWithValue('android'),
        ],
      );
      for (final feature in ['files', 'pet', 'phone', 'background', 'voice']) {
        expect(find.byKey(ValueKey('access-section-$feature')), findsOneWidget, reason: feature);
      }
      expect(find.byKey(const ValueKey('access-section-alerts')), findsNothing);
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-storage')), matching: find.text(_zh.accessStateOff)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('access-item-mic')), matching: find.text(_zh.accessStateOn)),
        findsOneWidget,
      );
    });

    testWidgets('a row that isn\'t on opens its step, which shows the same item', (tester) async {
      await _pump(
        tester,
        const SystemAccessPage(),
        overrides: [
          accessDriverProvider.overrideWithValue(
            FakeAccessDriver(const AccessReadings(storage: false, mic: true)),
          ),
          operatingSystemProvider.overrideWithValue('android'),
        ],
      );
      await tester.tap(find.byKey(const ValueKey('access-item-storage')));
      await _frames(tester, 12);
      expect(find.byKey(const ValueKey('access-step-storage')), findsOneWidget);
      expect(find.text(_zh.accessStorageTitle), findsOneWidget);
      expect(_primaryLabel(tester), _zh.accessTurnOn);
    });
  });

  group('search for it', () {
    List<String> ids(String q, {required bool android}) => [
      for (final h in searchSettings(
        q,
        spots: SettingsIndex.spots,
        features: featureSections,
        zh: _zh,
        en: _en,
        androidFeatures: android,
      ))
        h.spot?.id ?? 'feature:${h.feature!.id}',
    ];

    test('by name and by what it has on HarmonyOS', () {
      for (final q in ['系统权限', 'System permissions', '麦克风', '通知权限', '回复提醒']) {
        expect(ids(q, android: false), contains('page:systemAccess'), reason: q);
      }
    });

    test('not by what only Android has', () {
      for (final q in ['无障碍', '后台弹出界面', '受限制的设置', 'overlay', 'restricted settings']) {
        expect(ids(q, android: false), isNot(contains('page:systemAccess')), reason: q);
        expect(ids(q, android: true), contains('page:systemAccess'), reason: q);
      }
    });
  });
}

// The terminal page's explicit 「键盘输入」 action.
//
// Touch reaches the IME by tapping the drawn screen, which a screen reader
// cannot do and which the phone bridge's a11y service cannot do either. The
// tab row therefore carries a real button: it must be a labelled, tappable
// semantic node, and tapping it must hand the IME to the screen reader's hidden
// field — that field is the one ACTION_SET_TEXT can write into. Tapping the
// screen itself keeps its old behaviour (the key row owns the IME).

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/ui/terminal/terminal_keyboard.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart' show TerminalEnvironment, TerminalInfo, TerminalShell;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView;

const _session = 'keyboard-input-session';

final _zh = lookupL10n(AppLocale.zhCN);

const _keyboardKey = ValueKey('terminal-keyboard');
const _fieldKey = ValueKey('terminal-a11y-input');

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final overrides = <Override>[
    operatingSystemProvider.overrideWithValue('android'),
    terminalWorkspaceProvider(_session).overrideWith(() => _LiveWorkspace(_session)),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        locale: AppLocale.zhCN,
        supportedLocales: AppLocale.supported,
        localizationsDelegates: L10n.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: child!,
        ),
        home: const TerminalPage(sessionId: _session),
      ),
    ),
  );
  // The workspace state is synchronous; the frames only let the terminal's
  // autofocus open its IME session and the press animations settle.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The screen reader's field: the one editable node the terminal has.
FocusNode _fieldFocus(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_fieldKey)).focusNode!;

/// The key row's IME session, which the explicit action has to end first.
TerminalKeyboardState _keyRow(WidgetTester tester) => tester.state<TerminalKeyboardState>(find.byType(TerminalKeyboard));

void main() {
  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the 键盘输入 key is a labelled, tappable button', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(tester);

    expect(find.byKey(_keyboardKey), findsOneWidget);
    expect(find.bySemanticsLabel(_zh.botsTerminalKeyboardInput), findsOneWidget);
    final data = tester.getSemantics(find.byKey(_keyboardKey)).getSemanticsData();
    expect(data.label, _zh.botsTerminalKeyboardInput);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    // The label is the only way a screen reader announces it: nothing visible
    // is text (the key is an icon).
    expect(find.text(_zh.botsTerminalKeyboardInput), findsNothing);
    // The handle must be gone before the test ends; the framework checks it
    // before tear-downs run.
    semantics.dispose();
  });

  testWidgets('tapping it moves the IME to the screen reader field, and a screen tap takes it back', (tester) async {
    await _pumpPage(tester);

    // The terminal's autofocus put the IME on the key row, not on the field.
    expect(_keyRow(tester).hasConnection, isTrue);
    expect(_fieldFocus(tester).hasFocus, isFalse);

    await tester.tap(find.byKey(_keyboardKey));
    await tester.pump();
    expect(_fieldFocus(tester).hasFocus, isTrue, reason: 'the field owns the focus after the action');
    expect(_keyRow(tester).hasConnection, isFalse, reason: 'the key row gave the IME up first');
    expect(tester.testTextInput.isVisible, isTrue, reason: 'the IME is open');

    // Touch keeps its old path: a tap on the drawn screen is the key row's.
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    expect(_fieldFocus(tester).hasFocus, isFalse);
    expect(_keyRow(tester).hasConnection, isTrue);
    // xterm schedules a tap timer of its own (~300ms); let it fire so the test
    // ends without pending work.
    await tester.pump(const Duration(milliseconds: 500));
  });
}

/// One live, writable tab with a little output, and no Host behind it.
class _LiveWorkspace extends TerminalWorkspace {
  _LiveWorkspace(super.sessionId);

  @override
  TerminalWorkspaceState build() {
    final terminal = Terminal(maxLines: 1000)
      ..write('\$ dsh --version\r\n')
      ..write('1.2.3\r\n')
      ..write('\$ ');
    return TerminalWorkspaceState(
      loading: false,
      tabs: [
        TerminalTab(
          id: 'live-tab',
          terminal: terminal,
          title: 'zsh',
          phase: TerminalPhase.live,
          writable: true,
          info: const TerminalInfo(
            id: 'live-tab',
            title: 'zsh',
            shell: TerminalShell(path: '/bin/zsh', name: 'zsh'),
            cwd: '/home/me/project',
          ),
        ),
      ],
      selectedId: 'live-tab',
      environment: const TerminalEnvironment(cwd: '/home/me/project'),
    );
  }
}

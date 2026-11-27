// The screen reader / phone-bridge input channel of the terminal page.
//
// xterm's screen is drawn, so the terminal keeps a real, invisible TextField
// (`hint=终端输入`) as the one editable node an a11y service can write into.
// Android writes into it with ACTION_SET_TEXT (the framework's semantics
// `setText` action) — not through the IME, so no composing range is involved.
// The text must then reach the terminal exactly once, as the keystrokes a
// keyboard would have sent: characters through `textInput`, a line break as
// Enter. This file locks that path at the level Android uses.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/terminal_state.dart';
import 'package:dsh_app/ui/terminal/terminal_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart' show TerminalEnvironment, TerminalInfo, TerminalShell;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show Terminal;

const _session = 'a11y-text-session';

const _keyboardKey = ValueKey('terminal-keyboard');
const _fieldKey = ValueKey('terminal-a11y-input');

/// What the terminal sent down the wire (its `onOutput`), in order.
final _sent = <String>[];

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final overrides = <Override>[
    operatingSystemProvider.overrideWithValue('android'),
    terminalWorkspaceProvider(_session).overrideWith(() => _RecordingWorkspace(_session)),
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
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The screen reader's field: the one editable node the terminal has.
TextField _field(WidgetTester tester) => tester.widget<TextField>(find.byKey(_fieldKey));

/// The semantics node an a11y service finds and writes into: the editable one,
/// the node that carries `setText` (the TextField's own annotations sit on a
/// parent node and carry no actions of their own).
SemanticsNode _fieldNode(WidgetTester tester) => tester.getSemantics(find.byType(EditableText));

/// Hands the IME to the hidden field the way the 「键盘输入」 key does; the
/// field only offers ACTION_SET_TEXT while it owns the input focus.
Future<void> _focusField(WidgetTester tester) async {
  await tester.tap(find.byKey(_keyboardKey));
  await tester.pump();
}

/// ACTION_SET_TEXT as Android performs it: the framework's semantics `setText`
/// action on the field's editable node.
Future<void> _setText(WidgetTester tester, String text) async {
  // The test view's pipeline owns the semantics tree `getSemantics` reads.
  // ignore: deprecated_member_use
  tester.binding.pipelineOwner.semanticsOwner!.performAction(_fieldNode(tester).id, SemanticsAction.setText, text);
  await tester.pump();
}

void main() {
  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({});
    _sent.clear();
  });

  testWidgets('the field an a11y service finds offers ACTION_SET_TEXT', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(tester);
    await _focusField(tester);

    // The root cause of the "text in the field, nothing in the terminal" bug:
    // an IgnorePointer around the field sets isBlockingUserActions, and the
    // framework then strips every user action from its subtree — setText
    // (ACTION_SET_TEXT) and tap included. The node must keep them.
    final node = _fieldNode(tester);
    final data = node.getSemanticsData();
    expect(node.areUserActionsBlocked, isFalse);
    expect(data.hasAction(SemanticsAction.setText), isTrue, reason: 'ACTION_SET_TEXT reaches the framework');
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.flagsCollection.isTextField, isTrue);
    semantics.dispose();
  });

  testWidgets('ACTION_FOCUS then ACTION_SET_TEXT delivers text without the 键盘输入 key', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(tester);

    // The phone bridge focuses the screen's only editable node itself before
    // typing; the button is a human convenience, not a prerequisite.
    expect(_field(tester).focusNode!.hasFocus, isFalse);
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(_fieldNode(tester).id, SemanticsAction.focus);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_field(tester).focusNode!.hasFocus, isTrue, reason: 'ACTION_FOCUS lands on the hidden field');

    await _setText(tester, 'echo hi');

    expect(_sent.join(), 'echo hi');
    semantics.dispose();
  });

  testWidgets('ACTION_SET_TEXT delivers "echo hi" to the terminal once', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(tester);
    await _focusField(tester);

    await _setText(tester, 'echo hi');

    expect(_sent.join(), 'echo hi', reason: 'the characters reach the terminal');
    // The phone bridge reads the field back to decide ok; keeping the text is
    // what makes its read-back agree with what the shell received.
    expect(_field(tester).controller!.text, 'echo hi', reason: 'the field keeps what was typed');
    semantics.dispose();
  });

  testWidgets('a line break in ACTION_SET_TEXT is one Enter and the text before it is sent', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(tester);
    await _focusField(tester);

    await _setText(tester, 'echo hi\n');

    expect(_sent.join(), 'echo hi\r', reason: 'characters then exactly one carriage return');
    expect(_sent.where((chunk) => chunk == '\r').length, 1, reason: 'one Enter, not two');
    expect(_field(tester).controller!.text, '', reason: 'the next command starts from an empty field');
    semantics.dispose();
  });

  testWidgets('the same value written twice is sent once', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(tester);
    await _focusField(tester);

    await _setText(tester, 'echo hi');
    await _setText(tester, 'echo hi');

    expect(_sent.join(), 'echo hi', reason: 'no duplicate for an unchanged field');
    semantics.dispose();
  });

  testWidgets('a controller write (the a11y write landing in the field) reaches the terminal', (tester) async {
    await _pumpPage(tester);
    await _focusField(tester);

    // ACTION_SET_TEXT ends up as a controller value change in the framework.
    _field(tester).controller!.value = const TextEditingValue(
      text: 'echo hi',
      selection: TextSelection.collapsed(offset: 7),
    );
    await tester.pump();

    expect(_sent.join(), 'echo hi');
  });

  testWidgets('an IME commit into the field reaches the terminal once', (tester) async {
    await _pumpPage(tester);
    await _focusField(tester);

    // What a screen-reader user's own keyboard sends: the framework reports
    // the edit to both channels, and the second report must not type it again.
    await tester.enterText(find.byKey(_fieldKey), 'echo hi');
    await tester.pump();

    expect(_sent.join(), 'echo hi');
  });

  testWidgets('deleting characters sends Backspace and retyping sends the new text', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpPage(tester);
    await _focusField(tester);

    await _setText(tester, 'echo hix');
    await _setText(tester, 'echo hi');

    // 'x' was deleted from the field, so a Backspace goes to the shell.
    expect(_sent.join(), 'echo hix\u007f', reason: 'the deletion is a Backspace');
    semantics.dispose();
  });
}

/// One live, writable tab whose terminal records what it sends.
class _RecordingWorkspace extends TerminalWorkspace {
  _RecordingWorkspace(super.sessionId);

  @override
  TerminalWorkspaceState build() {
    final terminal = Terminal(maxLines: 1000, onOutput: _sent.add)..write('\$ ');
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

// The dark terminal card of the terminal page — the xterm screen, pinch to
// resize the font, long-press selection with copy / paste, the composing
// preview and the bottom slot (key row or status).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/l10n.dart';
import '../../state/terminal_state.dart';
import '../common/empty_view.dart';
import '../common/field_paste.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'terminal_keyboard.dart';
import 'terminal_keys.dart';
import 'terminal_palette.dart';
import '../common/brief_notice.dart';

/// The card shell: the engine log card's dark surface (dark in both themes),
/// with the dark theme inside so buttons and empty states read on it.
class TerminalCardFrame extends StatelessWidget {
  const TerminalCardFrame({super.key, required this.child});

  final Widget child;

  /// The dark theme of the current palette (light mode keeps the card dark).
  static final _darkThemes = <AppAccent, ThemeData>{};

  static ThemeData _darkThemeFor(AppAccent accent) {
    if (_darkThemes.length > 4) _darkThemes.clear();
    return _darkThemes.putIfAbsent(accent, () => buildDarkTheme(accent: accent));
  }

  @override
  Widget build(BuildContext context) {
    final ambient = Theme.of(context);
    final palette = TerminalPalette.of(context);
    return Theme(
      data: ambient.brightness == Brightness.dark ? ambient : _darkThemeFor(DshSurfaces.of(context).accent),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: palette.background,
          shape: RoundedSuperellipseBorder(
            borderRadius: AppShape.radiusLg,
            side: BorderSide(color: palette.hairline, width: 0.5),
          ),
        ),
        child: ClipRSuperellipse(
          borderRadius: AppShape.radiusLg,
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

/// A card with nothing but a status in its bottom slot (loading the list).
class TerminalCardPlaceholder extends StatelessWidget {
  const TerminalCardPlaceholder({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return TerminalCardFrame(
      child: Column(
        children: [
          const Spacer(),
          _Divider(),
          TerminalStatusBar(label: label, busy: true),
        ],
      ),
    );
  }
}

/// One tab's screen inside the card.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({
    super.key,
    required this.sessionId,
    required this.tab,
    required this.focusNode,
    required this.modifiers,
  });

  final String sessionId;
  final TerminalTab tab;
  final FocusNode focusNode;
  final TerminalModifiers modifiers;

  /// Inner padding of the screen inside the card.
  static const padding = EdgeInsets.fromLTRB(12, 12, 12, 6);

  @override
  ConsumerState<TerminalScreen> createState() => TerminalScreenState();
}

class TerminalScreenState extends ConsumerState<TerminalScreen> with FieldPaste<TerminalScreen> {
  final _selection = TerminalController();
  var _scroll = ScrollController();
  final _stack = GlobalKey();
  var _view = GlobalKey<TerminalViewState>();
  final _keyboard = GlobalKey<TerminalKeyboardState>();
  final _pointers = <int, Offset>{};
  double? _pinchSpan;
  double _pinchFont = TerminalFontSize.fallback;
  String? _composing;

  /// The screen reader's field (see [_a11yFieldBox]): a real, invisible
  /// [TextField] over the screen, skipped by keyboard traversal so a hardware
  /// Tab stays on the terminal.
  final _a11yField = FocusNode(debugLabel: 'terminal-a11y-field', skipTraversal: true);
  final _a11yController = TextEditingController();

  /// True while the field is being written back in step with the terminal, so
  /// the write does not turn into input of its own.
  bool _a11ySyncing = false;

  /// What the screen-reader channel has typed since the shell's last line
  /// break: the field's own text, so an a11y service that rewrites the whole
  /// field (ACTION_SET_TEXT) turns into the keystrokes that would have
  /// produced it.
  String _a11yText = '';

  TerminalTab get _tab => widget.tab;
  Terminal get _terminal => widget.tab.terminal;
  bool get _canType => _tab.phase == TerminalPhase.live && _tab.writable;

  TerminalWorkspace get _workspace => ref.read(terminalWorkspaceProvider(widget.sessionId).notifier);

  @override
  void initState() {
    super.initState();
    // Added before the field is built, so on a focus change this listener runs
    // first and the key row's IME session is closed before the field's opens.
    _a11yField.addListener(_onA11yFieldFocus);
    _a11yController.addListener(_onA11yChanged);
  }

  @override
  void didUpdateWidget(TerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Anchors belong to the old screen buffer.
    if (oldWidget.tab.terminal != widget.tab.terminal || oldWidget.tab.id != widget.tab.id) {
      _selection.clearSelection();
      // A paste still waiting on the system was for that terminal.
      cancelPaste();
    }
    if (oldWidget.tab.id != widget.tab.id) {
      // Each tab gets its own view (and scroll position); the old controller
      // goes once the old view has let go of it.
      _composing = null;
      _a11yText = '';
      _setA11yText('');
      _view = GlobalKey<TerminalViewState>();
      final old = _scroll;
      _scroll = ScrollController();
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    if (!_canType && (_a11yField.hasFocus || _composing != null)) {
      // The shell stopped taking input (ended, another device): let go of the
      // keyboard — the field leaves the tree on this same build anyway.
      _a11yField.unfocus();
      _composing = null;
    }
  }

  @override
  void dispose() {
    _a11yField.removeListener(_onA11yFieldFocus);
    _a11yController.removeListener(_onA11yChanged);
    _a11yField.dispose();
    _a11yController.dispose();
    _selection.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── Input ──

  void _toBottom() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _onText(String text) {
    if (widget.modifiers.any && text.runes.length == 1) {
      final m = widget.modifiers.consume();
      _terminal.textInput(withModifiers(text, ctrl: m.ctrl, alt: m.alt));
    } else {
      _terminal.textInput(text);
    }
    _toBottom();
  }

  void _onBackspace() {
    final m = widget.modifiers.consume();
    _backspace(ctrl: m.ctrl, alt: m.alt);
  }

  /// Backspace. The key row and the IME apply the sticky modifiers; the screen
  /// reader's field handles a whole string at a time and enters with none.
  void _backspace({bool ctrl = false, bool alt = false}) {
    _terminal.keyInput(TerminalKey.backspace, ctrl: ctrl, alt: alt);
    _toBottom();
  }

  void _onEnter() {
    final m = widget.modifiers.consume();
    _enter(ctrl: m.ctrl, alt: m.alt);
  }

  /// Enter at the prompt — the one submission path of both input channels.
  void _enter({bool ctrl = false, bool alt = false}) {
    _terminal.keyInput(TerminalKey.enter, ctrl: ctrl, alt: alt);
    _toBottom();
  }

  void _onExtraKey(TerminalExtraKey key) {
    _keyboard.currentState?.flushComposing();
    // The same for the accessibility field: end its composition so its
    // committed text lands before this key, not after it.
    _a11yController.clearComposing();
    final m = widget.modifiers.consume();
    key.send(_terminal, ctrl: m.ctrl, alt: m.alt);
    _toBottom();
  }

  // ── Screen reader ──
  //
  // xterm's screen is drawn: it has no text field for an a11y service to focus,
  // so TalkBack and the phone bridge's type action have nothing to write into.
  // [_a11yFieldBox] lays a real, invisible [TextField] over the screen instead;
  // its edits become the same key input the key row sends. Sticky modifiers
  // apply to a single character here too, exactly as on the touch channel.

  /// The accessibility field took the keyboard (or gave it back).
  ///
  /// This listener is added before the field is built, so it runs before the
  /// field's own: the key row's IME session ends first, and the field attaches
  /// onto a clean channel instead of two clients taking the keyboard over in
  /// one focus change.
  void _onA11yFieldFocus() {
    if (_a11yField.hasFocus) {
      _keyboard.currentState?.release();
      return;
    }
    if (_composing != null) setState(() => _composing = null);
  }

  /// The field's value changed. Composing text (pinyin before a candidate is
  /// picked) only shows in the pill — sending it would deliver half-typed
  /// characters. Everything else is typed, line breaks are Enter, and the
  /// field then starts the next command from an empty field.
  void _onA11yChanged() {
    if (_a11ySyncing || !mounted) return;
    final value = _a11yController.value;
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      final text = composing.textInside(value.text);
      if (text != _composing) setState(() => _composing = text);
      return;
    }
    if (_composing != null) setState(() => _composing = null);
    if (!_canType) {
      // The shell stopped taking input while the field had the text.
      _setA11yText('');
      return;
    }
    _submitA11y(value.text);
  }

  /// [next] (the whole field) as the difference from what was already typed:
  /// deletions become Backspace, new text goes through [_onText], a line break
  /// is [_enter]. What follows the last line break stays in the field.
  void _submitA11y(String next) {
    final before = _a11yText;
    var common = 0;
    while (common < next.length && common < before.length && next.codeUnitAt(common) == before.codeUnitAt(common)) {
      common++;
    }
    for (var i = common; i < before.length; i++) {
      _backspace();
    }
    final lines = next.substring(common).replaceAll('\r\n', '\n').split(RegExp('[\r\n]'));
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].isNotEmpty) _onText(lines[i]);
      if (i < lines.length - 1) _enter();
    }
    // After a submit the shell's line is a new, empty one; otherwise the field
    // mirrors what has been typed since the last one.
    final kept = lines.length > 1 ? lines.last : next;
    _a11yText = kept;
    _setA11yText(kept);
  }

  /// Puts the field back in step with what has been sent, without feeding the
  /// write back into [_onA11yChanged].
  void _setA11yText(String text) {
    if (_a11yController.text == text) return;
    _a11ySyncing = true;
    try {
      _a11yController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } finally {
      // A listener blowing up must not leave the field permanently muted.
      _a11ySyncing = false;
    }
  }

  /// Hardware keys: wait while the IME composes; sticky modifiers apply to
  /// the next printable key.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_keyboard.currentState?.composing ?? false) return KeyEventResult.skipRemainingHandlers;
    if (event is KeyUpEvent || !widget.modifiers.any) return KeyEventResult.ignored;
    final character = event.character;
    if (character == null || character.runes.length != 1 || character.codeUnitAt(0) < 0x20) {
      return KeyEventResult.ignored;
    }
    _onText(character);
    return KeyEventResult.handled;
  }

  // ── Pinch ──

  double _span() {
    final points = _pointers.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) {
      _pinchSpan = _span();
      _pinchFont = ref.read(terminalFontSizeProvider);
      _selection.clearSelection();
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;
    final start = _pinchSpan;
    if (start == null || start < 16 || _pointers.length < 2) return;
    ref.read(terminalFontSizeProvider.notifier).set(_pinchFont * _span() / start);
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) _pinchSpan = null;
  }

  // ── Selection ──

  Future<void> _copy() async {
    final range = _selection.selection;
    if (range == null) return;
    final text = _terminal.buffer.getText(range);
    _selection.clearSelection();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showBriefNotice(context, appL10n.commonCopied);
  }

  Future<void> _paste() async {
    final terminal = _terminal;
    _selection.clearSelection();
    final text = await readClipboard();
    if (text == null || text.isEmpty || !mounted) return;
    // A reconnect can replace the attachment before this widget rebuilds.
    final current = ref.read(terminalWorkspaceProvider(widget.sessionId)).selected;
    if (current == null || current.terminal != terminal || current.phase != TerminalPhase.live || !current.writable) {
      return;
    }
    terminal.paste(text);
    _toBottom();
  }

  /// Where the 复制 / 粘贴 bar goes: just above the selection, or just below
  /// it when the selection starts near the top. Null without a selection.
  Offset? _selectionBarAnchor() {
    final range = _selection.selection?.normalized;
    final render = _view.currentState?.renderTerminal;
    final stack = _stack.currentContext?.findRenderObject();
    if (range == null || render == null || !render.hasSize || stack is! RenderBox || !stack.hasSize) return null;
    Offset at(Offset local) => stack.globalToLocal(render.localToGlobal(local));
    final begin = at(render.getOffset(range.begin));
    final end = at(render.getOffset(range.end));
    final cell = render.cellSize;
    const gap = 8.0;
    final above = begin.dy - gap - _SelectionBar.height;
    final below = end.dy + cell.height + gap;
    final limit = stack.size.height - _SelectionBar.height - gap;
    final top = (above >= gap ? above : below).clamp(gap, limit < gap ? gap : limit);
    // Over the selection on one line; the middle of the screen across lines.
    final x = range.begin.y == range.end.y ? (begin.dx + end.dx) / 2 : stack.size.width / 2;
    return Offset(x, top);
  }

  // ── Build ──

  Widget? _bottom() {
    final tab = _tab;
    return switch (tab.phase) {
      TerminalPhase.live when tab.writable => ExtraKeysRow(modifiers: widget.modifiers, onKey: _onExtraKey),
      TerminalPhase.live => TerminalStatusBar(
        label: appL10n.botsTerminalOtherDevice,
        actionLabel: appL10n.botsTerminalTakeOver,
        onAction: () => _workspace.reconnect(tab.id),
      ),
      TerminalPhase.starting => TerminalStatusBar(label: appL10n.botsTerminalStarting, busy: true),
      TerminalPhase.connecting => TerminalStatusBar(label: appL10n.botsTerminalConnecting, busy: true),
      TerminalPhase.disconnected => TerminalStatusBar(
        label: tab.message ?? appL10n.botsTerminalDisconnected,
        actionLabel: appL10n.botsTerminalReconnect,
        onAction: () => _workspace.reconnect(tab.id),
      ),
      TerminalPhase.ended => TerminalStatusBar(
        label: switch (tab.exitCode) {
          null || 0 => appL10n.botsTerminalEnded,
          final code => appL10n.botsTerminalExitCode(code),
        },
        actionLabel: appL10n.botsTerminalNew,
        onAction: () => unawaited(_workspace.newTerminal(replacing: tab.id)),
      ),
      TerminalPhase.missing || TerminalPhase.failed => null,
    };
  }

  Widget? _blocked() {
    final tab = _tab;
    return switch (tab.phase) {
      TerminalPhase.missing => EmptyView(
        key: const ValueKey('terminal-missing'),
        icon: AppIcons.terminal,
        title: appL10n.botsTerminalGone,
        action: _CardButton(
          label: appL10n.botsTerminalNew,
          onPressed: () => unawaited(_workspace.newTerminal(replacing: tab.id)),
        ),
      ),
      TerminalPhase.failed => EmptyView(
        key: const ValueKey('terminal-failed'),
        icon: AppIcons.terminal,
        title: tab.message ?? TerminalCopy.startFailed,
        message: tab.message == TerminalCopy.limit ? appL10n.botsTerminalLimit : null,
        action: _CardButton(label: appL10n.commonRetry, onPressed: () => unawaited(_workspace.retry(tab.id))),
      ),
      _ => null,
    };
  }

  /// The screen reader's field: a real [TextField], invisible, over the whole
  /// screen. xterm draws the screen and owns a bare [TextInputClient] of its
  /// own, neither of which an a11y service can see as an editable node, so
  /// this is what TalkBack focuses and what ACTION_SET_TEXT writes into.
  ///
  /// Everything about it is deliberately passive: no autofocus (touch keeps
  /// going through [TerminalKeyboard]), no hit target ([IgnorePointer], so
  /// taps, long presses and scrolls still reach the terminal), no cursor and no
  /// selection overlay (nothing visible to draw), and a multiline IME so Enter
  /// arrives as a line break in the value instead of a submit action.
  Widget _a11yFieldBox() {
    return IgnorePointer(
      child: Opacity(
        opacity: 0,
        // At zero opacity the field's semantics must stay in the tree: they
        // are the only editable node the terminal has.
        alwaysIncludeSemantics: true,
        child: TextField(
          key: const ValueKey('terminal-a11y-input'),
          controller: _a11yController,
          focusNode: _a11yField,
          // Multiline so Enter arrives as a line break in the value (a
          // single-line field would send a submit action instead), filling the
          // screen area and never spelling anything.
          expands: true,
          maxLines: null,
          minLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          // The IME shape the key row's bridge asks for.
          enableSuggestions: true,
          enableIMEPersonalizedLearning: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
          keyboardAppearance: Brightness.dark,
          showCursor: false,
          enableInteractiveSelection: false,
          style: AppType.mono(color: Colors.transparent),
          decoration: InputDecoration(
            // TalkBack announces this, and the a11y tree reports it as the
            // edit box's hint (Flutter has no contentDescription for fields).
            labelText: appL10n.botsTerminalInput,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            isDense: true,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final font = ref.watch(terminalFontSizeProvider);
    final tab = _tab;
    final canType = _canType;
    final blocked = _blocked();
    final bottom = _bottom();

    Widget screen = TerminalView(
      _terminal,
      key: _view,
      controller: _selection,
      scrollController: _scroll,
      theme: canType ? TerminalPalette.of(context).theme : TerminalPalette.of(context).quiet,
      textStyle: TerminalStyle(
        fontSize: font,
        fontFamily: AppType.monoFamily,
        fontFamilyFallback: AppType.monoFallback,
      ),
      backgroundOpacity: 0,
      focusNode: widget.focusNode,
      autofocus: canType,
      hardwareKeyboardOnly: true,
      readOnly: !canType,
      keyboardAppearance: Brightness.dark,
      onTapUp: (_, _) => _keyboard.currentState?.show(),
      onKeyEvent: _onKeyEvent,
    );
    // The card is already inside the safe area; xterm would pad it again.
    screen = MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: screen,
    );
    screen = Listener(
      onPointerDown: _pointerDown,
      onPointerMove: _pointerMove,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerUp,
      child: Padding(padding: TerminalScreen.padding, child: screen),
    );
    screen = TerminalKeyboard(
      key: _keyboard,
      focusNode: widget.focusNode,
      enabled: canType,
      onText: _onText,
      onBackspace: _onBackspace,
      onEnter: _onEnter,
      onComposing: (text) {
        if (text != _composing && mounted) setState(() => _composing = text);
      },
      child: screen,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            key: _stack,
            children: [
              Positioned.fill(child: blocked == null ? screen : Center(child: blocked)),
              // The editable node an a11y service finds, over the screen.
              if (blocked == null && canType) Positioned.fill(child: _a11yFieldBox()),
              if (blocked == null)
                ListenableBuilder(
                  listenable: _selection,
                  builder: (context, _) {
                    final anchor = _selectionBarAnchor();
                    if (anchor == null) return const SizedBox.shrink();
                    return Positioned.fill(
                      child: CustomSingleChildLayout(
                        delegate: _CenteredAt(anchor),
                        child: _SelectionBar(onCopy: _copy, onPaste: canType ? _paste : null),
                      ),
                    );
                  },
                ),
              if (_composing case final text? when text.isNotEmpty && blocked == null)
                Positioned(left: 12, bottom: 8, child: _ComposingPill(text: text)),
            ],
          ),
        ),
        if (bottom != null) ...[
          _Divider(),
          AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            child: KeyedSubtree(key: ValueKey(bottom.runtimeType.toString() + tab.phase.name), child: bottom),
          ),
        ],
      ],
    );
  }
}

/// Puts its child's top centre at [anchor], kept 8 inside the sides.
class _CenteredAt extends SingleChildLayoutDelegate {
  const _CenteredAt(this.anchor);

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const margin = 8.0;
    final maxLeft = size.width - childSize.width - margin;
    final left = (anchor.dx - childSize.width / 2).clamp(margin, maxLeft < margin ? margin : maxLeft);
    return Offset(left, anchor.dy);
  }

  @override
  bool shouldRelayout(_CenteredAt oldDelegate) => oldDelegate.anchor != anchor;
}

/// EmptyView's button on the card (label in the theme's text style).
class _CardButton extends StatelessWidget {
  const _CardButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: Theme.of(context).textTheme.labelLarge,
      ),
      child: Text(label),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(height: 0.5, color: TerminalPalette.of(context).hairline);
}

/// 「复制 | 粘贴」 over the selection.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.onCopy, this.onPaste});

  static const height = 36.0;

  final VoidCallback onCopy;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = TerminalPalette.of(context);
    final style = Theme.of(context).textTheme.labelLarge?.copyWith(color: palette.foreground);
    Widget action(String label, VoidCallback onTap) => InkWell(
      key: ValueKey('terminal-$label'),
      onTap: onTap,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(child: Text(label, style: style)),
        ),
      ),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.key,
        shape: StadiumBorder(side: BorderSide(color: palette.hairline, width: 0.5)),
        shadows: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 4))],
      ),
      child: ClipPath(
        clipper: const ShapeBorderClipper(shape: StadiumBorder()),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              action(l10n.commonCopy, onCopy),
              if (onPaste case final paste?) ...[
                Container(width: 0.5, height: 16, color: palette.muted.withValues(alpha: 0.5)),
                action(l10n.commonPaste, paste),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What the IME is composing, until a candidate is picked.
class _ComposingPill extends StatelessWidget {
  const _ComposingPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = TerminalPalette.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: palette.key, shape: const StadiumBorder()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          text,
          style: AppType.mono(
            size: 14,
            color: palette.foreground,
          ).copyWith(decoration: TextDecoration.underline, decorationColor: palette.accent),
        ),
      ),
    );
  }
}

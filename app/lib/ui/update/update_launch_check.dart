import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/notify_state.dart' show launchNoticeShownProvider;
import '../../state/update_state.dart';
import 'update_sheet.dart';

/// Mounted once in the home shell; draws nothing.
///
/// A few seconds after launch (the engine starts first) it runs the daily
/// automatic check and offers the sheet when there's a version the person
/// hasn't skipped. Coming back to the front does the same — the app is
/// long-lived, so the launch check may be days old; the controller's own
/// throttle (24 h after a check that got an answer, 4 h after a failed one)
/// decides whether anything happens. It also tells the controller about the
/// resume, which continues an install waiting on the "install unknown apps"
/// permission.
class UpdateLaunchCheck extends ConsumerStatefulWidget {
  const UpdateLaunchCheck({super.key, this.delay = const Duration(seconds: 6)});

  final Duration delay;

  @override
  ConsumerState<UpdateLaunchCheck> createState() => _UpdateLaunchCheckState();
}

class _UpdateLaunchCheckState extends ConsumerState<UpdateLaunchCheck> {
  Timer? _timer;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () => unawaited(_run()));
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(ref.read(appUpdateProvider.notifier).onAppResumed());
        unawaited(_run());
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  /// One check at a time: the launch timer and a resume can land together.
  bool _running = false;

  Future<void> _run() async {
    if (!mounted || _running) return;
    _running = true;
    try {
      final offer = await ref.read(appUpdateProvider.notifier).autoCheckIfDue();
      if (!offer || !mounted) return;
      // Don't cover a page or sheet the person is in, or interrupt typing (raw
      // view insets: a Scaffold on the way may have consumed the keyboard's).
      // The mark in 设置 → 关于 stays either way.
      if (ModalRoute.of(context)?.isCurrent == false || View.of(context).viewInsets.bottom > 0) return;
      ref.read(launchNoticeShownProvider.notifier).set(true);
      await showUpdateSheet(context);
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

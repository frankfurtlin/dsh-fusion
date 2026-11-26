import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../diagnostics/perf_trace.dart';
import '../../launch/launch_state.dart';
import '../../launch/startup_trace.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../remote/remote_screen.dart';
import '../theme/theme.dart';
import '../web/mode_home.dart';
import 'brand_mark.dart';

/// App root: waits for settings and the saved host, then shows the connect page
/// or the home shell.
///
/// 手机本地引擎已删除（2026-11-26）：没有主机时首屏是 [RemoteScreen]
/// （「连接电脑或服务器」）。只为本机运行环境存在的引导流程（安装、外观、
/// 系统权限、API Key 起步）随引擎一起删除，App 不再启动任何本机运行时。
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.home});

  /// Stands in for [ModeHome] (tests).
  @visibleForTesting
  final Widget? home;

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  bool _launchReady = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final host = ref.watch(activeHostProvider);
    final hostRestored = ref.watch(activeHostRestoredProvider);

    final Widget child;
    if (!settings.loaded || hostRestored.isLoading) {
      StartupTrace.mark('waiting: settings ${settings.loaded}');
      child = const _Splash();
    } else if (host.isNone) {
      // 没有主机：直接是远程主机页（标题/文案都是现成的），挑中一个主机后
      // 上面的 host 变了，这一分支换成主界面。
      child = const RemoteScreen();
    } else {
      // The native shell or the web page, by 界面 (ui_mode_state.dart).
      child = widget.home ?? const ModeHome();
    }
    if (child is! _Splash && !_launchReady) {
      // 启动画面: the first page is up.
      _launchReady = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        StartupTrace.mark('first page');
        PerfTrace.end('first_page');
        // 手机本地引擎已删除：没有要等的本机引擎启动。
        LaunchController.active.value?.ready(waitsForEngine: false);
        StartupTrace.finished();
      });
    }
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.page),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      child: KeyedSubtree(
        key: ValueKey(child is _Splash ? 'splash' : (host.isNone ? 'connect' : 'home')),
        child: child,
      ),
    );
  }
}

/// Shown for the few hundred ms before settings and the saved host arrive. Same
/// colour as the Android launch window; the mark fades in only if loading is slow.
class _Splash extends StatefulWidget {
  const _Splash();

  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: AppBackdrop(
        child: Center(
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: AppMotion.of(context, AppMotion.slow),
            child: const Column(mainAxisSize: MainAxisSize.min, children: [BrandMark(size: 64, tile: true)]),
          ),
        ),
      ),
    );
  }
}

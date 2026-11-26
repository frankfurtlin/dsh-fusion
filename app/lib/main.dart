import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics/perf_trace.dart';
import 'diagnostics/pocket_log.dart';
import 'state/app_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'runtime/local_paths.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/fx/metal/metal_shader.dart';
import 'ui/fx/waves/distortion_wave.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/theme/theme.dart';

Future<void> main() => runWithFrameProbe(_startApp);

Future<void> _startApp() async {
  // 本次启动的计时从这里开始：Dart 入口 → 第一帧 → 第一页（设置 → 诊断 → 性能可读）。
  PerfTrace.begin('boot');
  PerfTrace.begin('first_page');
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  appErrorCapture.install();
  // 操作日志（可选）：CI 构建用 --dart-define=POCKET_LOG_TOKEN 打开，本地构建为空 =
  // 整个模块空操作。攒批上报，失败留在队列里。
  unawaited(PocketLog.instance.start(deviceId: await _deviceId(), appVersion: AppInfo.version));
  // The first frame is already in the chosen language (设置 → 语言), and is the launch
  // window's own picture (启动画面, lib/launch/launch_state.dart).
  await Future.wait([AppLanguageController.load(), LaunchController.begin(), LocalPaths.load()]);
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // The effects' shaders load now, so the first wave or metal word is not a plain fallback.
  unawaited(DistortionWave.precache());
  unawaited(MetalShader.load());
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  runApp(const ProviderScope(child: DshApp()));
  // 第一帧画完算 boot 结束：之后的等待都在页面里（建链、列表、开会话，各有自己的账）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    PerfTrace.end('boot');
  });
}

/// 稳定但不敏感的设备标识：装一次生成，之后一直用它归类日志。
Future<String> _deviceId() async {
  final prefs = await SharedPreferences.getInstance();
  const key = 'pocket.deviceId';
  final existing = prefs.getString(key);
  if (existing != null && existing.length >= 8) return existing;
  final created = 'dev-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
  await prefs.setString(key, created);
  return created;
}

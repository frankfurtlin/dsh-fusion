// Opens Platform pages (a subscription's sign-in, the workshop's) outside the
// app's WebView. Kept after 手机本地引擎与 DeepSeek 账号 et removed (2026-11-26):
// the two remaining sign-ins still need a real browser window.

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a page outside the app's WebView.
abstract interface class ExternalBrowser {
  /// True when something was launched.
  Future<bool> open(Uri url);
}

/// Chrome Custom Tab first (shares the browser's login cookies and keeps the
/// person next to the app), the default browser as a fallback. OAuth stays out
/// of embedded WebViews (RFC 8252).
class SystemBrowser implements ExternalBrowser {
  const SystemBrowser();

  @override
  Future<bool> open(Uri url) async {
    // HarmonyOS's url_launcher answers the in-app mode with a developer's toast.
    final modes = Platform.operatingSystem == 'ohos'
        ? const [LaunchMode.externalApplication]
        : const [LaunchMode.inAppBrowserView, LaunchMode.externalApplication];
    for (final mode in modes) {
      try {
        if (await launchUrl(url, mode: mode)) return true;
      } catch (_) {
        // No Custom Tabs provider: try the next mode.
      }
    }
    return false;
  }
}

final externalBrowserProvider = Provider<ExternalBrowser>((ref) => const SystemBrowser());

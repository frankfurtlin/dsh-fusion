// 手机桥: the OkHttp WebSocket client that keeps this phone reachable from the
// bridge server (`bridge-server`, /bridge/ws) while the app is in the
// background. The native side owns the service, the reconnect backoff and the
// token; Dart only reads the state and presses the switches.
//
// Contract (implemented in the android shell as `dsh/bridge`):
//
//   config          → {origin, deviceName, running, status, caps, tokenPresent}
//   saveConfig      {origin, deviceName} → bool
//   setToken        {token} → bool
//   clearToken      → bool
//   start / stop    → bool
//   openAccessibility → bool
//
//   EventChannel `dsh/bridge/events` → {status, running, connected}, pushed on
//   change only. A build without it falls back to polling [config] (see
//   [BridgeChannel.watch]).
//
// Everything here swallows a missing channel on purpose: on iOS, on HarmonyOS
// and on a build that hasn't picked up the service yet the page must still
// draw, say 「未就绪」 and not throw.

import 'dart:async';

import 'package:flutter/services.dart';

/// Names of the two channels; the native side registers them verbatim.
abstract final class BridgeChannels {
  static const method = MethodChannel('dsh/bridge');
  static const events = EventChannel('dsh/bridge/events');
}

/// What `config` answered: the saved settings plus the live service state.
class BridgeConfig {
  const BridgeConfig({
    this.origin,
    this.deviceName = 'android',
    this.running = false,
    this.status = '',
    this.caps = const [],
    this.tokenPresent = false,
  });

  factory BridgeConfig.fromMap(Map<Object?, Object?> m) => BridgeConfig(
    origin: _text(m['origin']),
    deviceName: _text(m['deviceName']) ?? 'android',
    running: _flag(m['running']),
    status: _text(m['status']) ?? '',
    caps: _strings(m['caps']),
    tokenPresent: _flag(m['tokenPresent']),
  );

  /// The server origin exactly as it will be sent in `Origin`, e.g.
  /// `https://dsh.frankfurtlin.top`; null until someone saved one.
  final String? origin;

  /// The name the server shows for this phone; `android` when unset.
  final String deviceName;

  /// The foreground service is up (it may still be reconnecting).
  final bool running;

  /// The native side's own sentence, shown as-is: it knows why it stopped.
  final String status;

  /// The ops this phone announced in `hello`; empty while not connected.
  final List<String> caps;

  /// A token is stored for [origin] (an AES-GCM secret in the Keystore).
  final bool tokenPresent;

  bool get configured => origin != null && origin!.isNotEmpty;

  /// True when the address is cleartext HTTP to something that isn't the
  /// loopback: this build's network security config refuses it, so the
  /// handshake fails with a message nobody can read.
  bool get insecure {
    final uri = Uri.tryParse(origin ?? '');
    if (uri == null || uri.scheme != 'http') return false;
    final host = uri.host;
    return host != '127.0.0.1' && host != 'localhost' && host != '::1';
  }
}

/// One pushed state change (or one poll's worth of `config`).
class BridgeStatus {
  const BridgeStatus({this.status = '', this.running = false, this.connected});

  factory BridgeStatus.fromMap(Map<Object?, Object?> m) => BridgeStatus(
    status: _text(m['status']) ?? '',
    running: _flag(m['running']),
    connected: m.containsKey('connected') ? _flag(m['connected']) : null,
  );

  /// See [BridgeConfig.status].
  final String status;
  final bool running;

  /// Null when nobody said (a build that only answers `config`); not a guess.
  final bool? connected;
}

/// Outcome of [BridgeChannel.gatewayLogin]: the refreshed config, or why it refused.
class BridgeLoginResult {
  const BridgeLoginResult({this.config, this.error});

  final BridgeConfig? config;
  final String? error;

  bool get ok => config != null;
}

/// The Dart end of the channels. Methods answer false (or null) instead of
/// throwing when the native side isn't there.
class BridgeChannel {
  const BridgeChannel();

  /// The saved settings and state, or null when the channel is missing.
  Future<BridgeConfig?> config() async {
    final map = await _call('config');
    return map == null ? null : BridgeConfig.fromMap(map);
  }

  Future<bool> saveConfig({required String origin, required String deviceName}) =>
      _bool('saveConfig', {'origin': origin, 'deviceName': deviceName});

  Future<bool> setToken(String token) => _bool('setToken', {'token': token});

  Future<bool> clearToken() => _bool('clearToken');

  /// Signs in to the dsh-passwords gateway with a username and password and stores the
  /// `dsh_gateway_token` it mints. [error] is the native side's reason when it refused.
  Future<BridgeLoginResult> gatewayLogin({
    required String origin,
    required String username,
    required String password,
  }) async {
    try {
      final map = await BridgeChannels.method.invokeMethod<Map<Object?, Object?>>('gatewayLogin', {
        'origin': origin,
        'username': username,
        'password': password,
      });
      if (map == null) return const BridgeLoginResult(error: 'no answer from the bridge');
      return BridgeLoginResult(config: BridgeConfig.fromMap(map));
    } on MissingPluginException {
      return const BridgeLoginResult(error: 'this build has no phone bridge');
    } on PlatformException catch (e) {
      return BridgeLoginResult(error: e.message ?? e.code);
    }
  }

  /// Reads `dsh_gateway_token` out of the app's own WebView cookie store, i.e. after the
  /// user logged into the gateway once inside 网页模式. Null when the native side is
  /// missing or that origin has no such cookie yet.
  Future<String?> gatewayCookie(String origin) async {
    try {
      final value = await BridgeChannels.method.invokeMethod<String>('gatewayCookie', {'origin': origin});
      return (value == null || value.isEmpty) ? null : value;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> start() => _bool('start');

  Future<bool> stop() => _bool('stop');

  /// The app-local switch for bridge-driven automation (`Settings.a11yEnabled`). The system
  /// accessibility service has to be on as well; both must hold for a11y.* ops to run.
  Future<bool> a11yEnabled() async {
    try {
      return await BridgeChannels.method.invokeMethod<bool>('a11yEnabled') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> setA11yEnabled(bool enabled) => _bool('setA11yEnabled', {'enabled': enabled});

  /// Opens the system accessibility settings page; the native side forwards to
  /// the `dsh/phone` implementation (which doesn't need an Activity).
  Future<bool> openAccessibility() => _bool('openAccessibility');

  /// State changes, in order. Subscribes to [BridgeChannels.events]; a build
  /// without that channel (or one that never answers) is polled instead, so
  /// the page updates either way. The [fallbackInterval] poll only starts once
  /// the event channel has failed.
  Stream<BridgeStatus> watch({Duration fallbackInterval = const Duration(milliseconds: 1500)}) {
    late final StreamController<BridgeStatus> controller;
    StreamSubscription<Object?>? events;
    Timer? timer;
    var polling = false;

    Future<void> poll() async {
      final config = await this.config();
      if (config == null || controller.isClosed) return;
      controller.add(
        BridgeStatus(status: config.status, running: config.running),
      );
    }

    void startPolling() {
      if (polling) return;
      polling = true;
      unawaited(poll());
      timer = Timer.periodic(fallbackInterval, (_) => unawaited(poll()));
    }

    controller = StreamController<BridgeStatus>(
      onListen: () {
        events = BridgeChannels.events.receiveBroadcastStream().listen(
          (event) {
            if (controller.isClosed) return;
            if (event is Map) controller.add(BridgeStatus.fromMap(event.cast<Object?, Object?>()));
          },
          onError: (Object _) {
            // Not implemented here: no errors to wait for, ask config instead.
            unawaited(events?.cancel());
            events = null;
            startPolling();
          },
          cancelOnError: false,
        );
      },
      onCancel: () async {
        timer?.cancel();
        timer = null;
        await events?.cancel();
        events = null;
      },
    );
    return controller.stream;
  }

  Future<Map<Object?, Object?>?> _call(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await BridgeChannels.method.invokeMapMethod<Object?, Object?>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> _bool(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await BridgeChannels.method.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;

bool _flag(Object? value) => value == true;

List<String> _strings(Object? value) =>
    value is List ? [for (final item in value) if (item is String) item] : const [];

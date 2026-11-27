/// 网页登录主机的连接：网关登录 → 带会话 cookie 的 DshClient（HTTP + WebSocket）。
///
/// 没有 SSH：一次登录（两个 HTTPS 请求），然后所有 `/api/*` 与 `/api/remote.mux`
/// 走普通 HTTPS/WSS，网关自己把请求转给本机的 DSH Web。会话 12 小时过期，
/// 过期前回到前台（`kick`）会重新登录并换一条新连接，不用人去点。
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'gateway_login.dart';
import 'web_host_config.dart';

class WebHostLink implements HostLink {
  /// 同一台主机在整个 App 里只保留一条 link。
  ///
  /// 之前每个页面（抽屉、远程主机页、会话页）各建一条，每条 open() 都会重新走一次
  /// 网关登录并抢一次 mux：第二条抢不到就无限重试，界面就永远显示「登录…」，
  /// 同时把网关登录与 /api 往返拖慢（会话列表 6–8 s 的抖动）。[obtain] 返回已有实例。
  static final _live = <String, WebHostLink>{};

  static String keyOf(WebHostConfig config) => '${config.id}\u0000${config.connectionKey}';

  static WebHostLink obtain({
    required WebHostConfig config,
    required Future<String?> Function() loadPassword,
    Stream<void>? kicks,
    GatewayLogin? login,
  }) {
    final key = keyOf(config);
    final existing = _live[key];
    if (existing != null && !existing._closed) {
      existing.config = config;
      return existing;
    }
    final link = WebHostLink._(config: config, loadPassword: loadPassword, login: login, kicks: kicks);
    _live[key] = link;
    return link;
  }

  WebHostLink._({required this.config, required this.loadPassword, GatewayLogin? login, Stream<void>? kicks})
    : _login = login ?? GatewayLogin(),
      _backoff = Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  /// 直接构造（测试用；正式路径走 [obtain]）。
  WebHostLink({
    required this.config,
    required this.loadPassword,
    GatewayLogin? login,
    Stream<void>? kicks,
    Backoff? backoff,
  }) : _login = login ?? GatewayLogin(),
       _backoff = backoff ?? Backoff() {
    _kickSub = kicks?.listen((_) => kick());
  }

  WebHostConfig config;
  final Future<String?> Function() loadPassword;
  final GatewayLogin _login;
  final Backoff _backoff;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;

  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  GatewaySession? _session;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _published = false;
  int _attempt = 0;
  Future<void>? _relogin;

  @override
  HostLinkStatus get status => _status;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  /// 手上还握着客户端。相位可能滞后（重连/换新时先发过 connecting），
  /// [currentClient] 在那种时刻也报 null，所以读状态的人要靠它看真实连接。
  /// 只读，不改变任何连接行为。
  bool get hasClient => _client != null;

  /// 网关会话还有多久过期（诊断用）。
  DateTime? get sessionExpiresAt => _session?.expiresAt;

  void updateConfig(WebHostConfig next) => config = next;

  void _emit(HostLinkStatus next) {
    if (_closed) return;
    _status = next;
    _statuses.add(next);
  }

  HostLinkStatus _stage(HostLinkStep step, {String? detail}) =>
      HostLinkStatus(HostLinkPhase.connecting, step: step, completed: const {}, attempt: _attempt, detail: detail);

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = currentClient;
    if (client != null) return Future.value(client);
    return _opening ??= _run().whenComplete(() => _opening = null);
  }

  Future<DshClient> _run() async {
    final live = currentClient;
    if (live != null) return live;
    _backoff.reset();
    var last = HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed, retryable: true);
    while (!_closed) {
      try {
        return await _connectOnce();
      } on HostLinkError catch (error) {
        last = error;
      } catch (error) {
        last = HostLinkError(
          HostLinkErrorKind.other,
          appL10n.commonConnectionFailed,
          detail: '$error',
          retryable: true,
        );
      }
      if (_closed || !last.retryable || _backoff.exhausted) break;
      final delay = _backoff.next();
      _emit(
        HostLinkStatus(
          HostLinkPhase.reconnecting,
          step: HostLinkStep.login,
          attempt: _backoff.attempt,
          error: last,
          nextRetryAt: DateTime.now().add(delay),
        ),
      );
      await _delay.wait(delay);
    }
    _emit(HostLinkStatus(HostLinkPhase.failed, error: last));
    throw last;
  }

  Future<DshClient> _connectOnce() async {
    final attempt = ++_attempt;
    _emit(_stage(HostLinkStep.connect, detail: config.base.host));
    if (config.baseUrl.isEmpty || config.username.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.webLoginErrMissingAccount);
    }
    final password = await loadPassword();
    if (password == null || password.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.authFailed, appL10n.webLoginErrNoPassword);
    }
    if (_closed) throw StateError('link closed');
    // 旧 attempt 不能在新的 attempt 已经连上之后再发 connecting 事件，否则相位会被拉回
    // 「登录…」（根因 B）。所有 await 之后重新进场都要重新确认自己还是当次 attempt。
    if (attempt != _attempt) throw HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed);
    _emit(_stage(HostLinkStep.login, detail: config.username));

    final GatewaySession session;
    final cached = _session;
    if (cached != null && !cached.isExpiredAt(DateTime.now())) {
      session = cached;
    } else {
      try {
        session = await _login.login(config.base, username: config.username, password: password);
      } on GatewayLoginError catch (error) {
        throw _hostError(error);
      }
    }
    if (_closed) throw StateError('link closed');
    if (attempt != _attempt) throw HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed);

    if (attempt != _attempt) throw HostLinkError(HostLinkErrorKind.other, appL10n.commonConnectionFailed);
    _emit(_stage(HostLinkStep.login, detail: appL10n.webLoginOpeningDsh));
    final previous = _client;
    _client = null;
    if (previous != null) unawaited(previous.close().catchError((_) {}));
    final DshClient client;
    try {
      client = await DshClient.connect(
        baseUri: config.base,
        cookie: DshCookie(name: session.name, value: session.value, authority: config.authority),
        backgroundLists: true,
        startMux: true,
      );
    } catch (error) {
      throw HostLinkError(
        HostLinkErrorKind.loginFailed,
        appL10n.webLoginErrOpenFailed,
        detail: '$error',
        retryable: true,
      );
    }
    if (_closed) {
      await client.close();
      throw StateError('link closed');
    }
    _session = session;
    _client = client;
    _emit(
      HostLinkStatus(
        HostLinkPhase.connected,
        completed: const {HostLinkStep.connect, HostLinkStep.login},
        detail: config.base.host,
      ),
    );
    if (_published) {
      _clients.add(client);
    } else {
      _published = true;
    }
    return client;
  }

  HostLinkError _hostError(GatewayLoginError error) => switch (error.kind) {
    GatewayLoginErrorKind.unreachable => HostLinkError(
      HostLinkErrorKind.unreachable,
      error.message,
      detail: error.detail,
      retryable: true,
    ),
    GatewayLoginErrorKind.invalidCredentials => HostLinkError(
      HostLinkErrorKind.authFailed,
      error.message,
      detail: error.detail,
    ),
    GatewayLoginErrorKind.locked ||
    GatewayLoginErrorKind.throttled => HostLinkError(HostLinkErrorKind.authFailed, error.message, detail: error.detail),
    GatewayLoginErrorKind.notGateway => HostLinkError(
      HostLinkErrorKind.unavailable,
      error.message,
      detail: error.detail,
    ),
    GatewayLoginErrorKind.csrf || GatewayLoginErrorKind.badResponse => HostLinkError(
      HostLinkErrorKind.other,
      error.message,
      detail: error.detail,
      retryable: error.kind == GatewayLoginErrorKind.badResponse,
    ),
  };

  /// 网络变化 / 回到前台：连接还好就顺手让 mux 重连一次；会话快过期就重新登录。
  @override
  void kick() {
    if (_closed) return;
    final client = _client;
    if (client == null) {
      if (_status.phase == HostLinkPhase.failed || _status.phase == HostLinkPhase.reconnecting) retry();
      return;
    }
    if (_session?.isExpiredAt(DateTime.now()) ?? false) {
      unawaited(_reloginOnce());
      return;
    }
    client.mux.reconnect();
  }

  /// 会话过期后的换新：重新登录，用一个新客户端替换旧的（列表页会跟着换）。
  Future<void> _reloginOnce() => _relogin ??= _reloginNow().whenComplete(() => _relogin = null);

  Future<void> _reloginNow() async {
    if (_closed) return;
    _emit(_stage(HostLinkStep.login, detail: appL10n.webLoginRefreshing));
    final previous = _client;
    _client = null;
    if (previous != null) unawaited(previous.close().catchError((_) {}));
    _backoff.reset();
    try {
      await _run();
    } on Object {
      // _run 已经发过失败状态。
    }
  }

  @override
  void retry() {
    if (_closed) return;
    _backoff.reset();
    _attempt++;
    _delay.skip();
    _emit(HostLinkStatus(HostLinkPhase.idle));
    unawaited(open().then<void>((_) {}, onError: (Object _) {}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _live.removeWhere((_, link) => identical(link, this));
    _delay.skip();
    await _kickSub?.cancel();
    await _client?.close().catchError((_) {});
    _client = null;
    await _statuses.close();
    await _clients.close();
  }
}

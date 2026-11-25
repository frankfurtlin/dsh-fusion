/// 「网页登录」主机：和浏览器一样，打开 `https://<host>/`、用 dsh-passwords
/// 网关的账号密码登录，App 拿到网关会话 cookie 后直接连 DSH Web。
///
/// 为什么单独一种：SSH 主机要地址、端口、用户名、私钥/密码，还要认主机指纹，
/// 对「只想在手机上用同一个网页账号」的人太重。网页登录只有三样：网址、账号、
/// 密码（密码进安全存储，配置里不留）。
///
/// 协议（2026-11-25 在本机网关上核对过）：
///   GET  <base>gateway/login          → Set-Cookie: dsh_csrf.token.sig（表单里也有同值）
///   POST <base>gateway/login          → 表单 username/password/csrf，302 + Set-Cookie:
///                                       dsh_gateway_token=<jwt>; Path=/; HttpOnly;
///                                       SameSite=Lax; Max-Age=43200
///   之后每个 /api/* 请求与 WebSocket 升级都带 `Cookie: dsh_gateway_token=<jwt>`。
library;

import 'dart:math' as math;

/// One saved 网页登录 host. Persisted as JSON in SharedPreferences (no secret).
class WebHostConfig {
  const WebHostConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
  });

  /// Stable id (`web-<hex>`); also the secret-store namespace.
  final String id;

  /// What the person calls it ("dsh").
  final String name;

  /// Normalized origin, no trailing slash: `https://dsh.frankfurtlin.top`.
  final String baseUrl;

  final String username;

  /// The gateway's origin (with any path prefix it lives under).
  Uri get base => Uri.parse(baseUrl);

  Uri get loginUrl => base.replace(path: '${_prefix}gateway/login');

  /// Authority the Host sees: the Host header of every request.
  String get authority => base.hasPort ? '${base.host}:${base.port}' : base.host;

  String get _prefix => base.path.isEmpty || base.path == '/' ? '/' : '${base.path.replaceFirst(RegExp(r'/+$'), '')}/';

  /// Fields that need a new connection when changed (the name doesn't).
  String get connectionKey => [baseUrl, username].join('\u0000');

  String get displayName => name.trim().isEmpty ? base.host : name.trim();

  WebHostConfig copyWith({String? name, String? baseUrl, String? username}) => WebHostConfig(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    username: username ?? this.username,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'username': username,
  };

  static WebHostConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final baseUrl = raw['baseUrl'];
    final username = raw['username'];
    if (id is! String || id.isEmpty || baseUrl is! String || username is! String) return null;
    final normalized = normalizeBaseUrl(baseUrl);
    if (normalized == null) return null;
    final name = raw['name'];
    return WebHostConfig(
      id: id,
      name: name is String ? name : '',
      baseUrl: normalized,
      username: username,
    );
  }

  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    return 'web-${List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// What the form accepts → the stored origin: a bare host gets `https://`, a
  /// path prefix keeps its place, trailing slashes go. Null when unusable.
  ///
  /// `http://` is allowed for a LAN Host without TLS; it is never the default.
  static String? normalizeBaseUrl(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    if (uri.hasQuery || uri.hasFragment) return null;
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is WebHostConfig &&
      other.id == id &&
      other.name == name &&
      other.baseUrl == baseUrl &&
      other.username == username;

  @override
  int get hashCode => Object.hash(id, name, baseUrl, username);
}

/// Where this host's gateway password lives in the [SecretStore].
String webPasswordKey(String hostId) => 'web.$hostId.password';

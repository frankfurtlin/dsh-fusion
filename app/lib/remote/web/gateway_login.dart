/// dsh-passwords 网关的登录（网页登录主机的第一步）。
///
/// 与浏览器走同一条路：先 GET `/gateway/login` 拿一个 CSRF cookie（表单里也带同值），
/// 再 POST 账号密码 + csrf；成功是 302 + `Set-Cookie: dsh_gateway_token=<jwt>`。
/// 之后 App 把这条 cookie 挂在每个 `/api/*` 请求和 WebSocket 升级上。
///
/// 失败按网关的状态码分类：401 账号密码错、429 锁定/限流、403 CSRF、
/// 404/非 HTML 说明这个地址不是 dsh-passwords 网关。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 网关会话：给 `DshCookie` 用的名字/值，以及它大概什么时候过期。
class GatewaySession {
  const GatewaySession({required this.name, required this.value, required this.expiresAt, this.username});

  final String name;
  final String value;

  /// 网关给的是 Max-Age 12 小时；拿不到时按 12 小时估。
  final DateTime? expiresAt;

  /// 登录后网关认的账号名（可能是大小写归一后的）。
  final String? username;

  String get cookieHeader => '$name=$value';

  bool isExpiredAt(DateTime now, {Duration early = const Duration(minutes: 5)}) =>
      expiresAt != null && !now.isBefore(expiresAt!.subtract(early));
}

enum GatewayLoginErrorKind {
  /// 连不上（DNS、超时、证书）。
  unreachable,

  /// 地址不是 dsh-passwords 网关（404、其它页面）。
  notGateway,

  /// 账号或密码不对。
  invalidCredentials,

  /// 连续失败被锁。
  locked,

  /// 同一 IP 尝试太频繁。
  throttled,

  /// CSRF 校验没过（网关的 cookie 与表单不同源）。
  csrf,

  /// 返回了看不懂的东西。
  badResponse,
}

class GatewayLoginError implements Exception {
  const GatewayLoginError(this.kind, this.message, {this.detail, this.status});

  final GatewayLoginErrorKind kind;
  final String message;
  final String? detail;
  final int? status;

  @override
  String toString() => detail == null ? message : '$message ($detail)';
}

/// 登录一次。失败抛 [GatewayLoginError]。
class GatewayLogin {
  GatewayLogin({
    HttpClient Function()? http,
    this.timeout = const Duration(seconds: 20),
    this.userAgent = 'dsh-pocket/1.0 (web login)',
  }) : _http = http ?? HttpClient.new;

  final HttpClient Function() _http;
  final Duration timeout;
  final String userAgent;

  static const cookieName = 'dsh_gateway_token';
  static const csrfCookieName = 'dsh_csrf';

  /// 整个登录（取 CSRF + 提交 + 读响应体）都在 [timeout] 内完成。
  /// 早先只有连接与首包设了超时，网关偶发挂住时读 body 的 future 永不完成，
  /// 界面上就会永远停在「登录…」。
  Future<GatewaySession> login(Uri base, {required String username, required String password}) async {
    try {
      return await _loginOnce(
        base,
        username: username,
        password: password,
      ).timeout(timeout + const Duration(seconds: 5));
    } on TimeoutException {
      throw const GatewayLoginError(GatewayLoginErrorKind.unreachable, '登录超时，网络可能不稳');
    }
  }

  Future<GatewaySession> _loginOnce(Uri base, {required String username, required String password}) async {
    final client = _http();
    client
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = userAgent;
    try {
      final csrf = await _csrf(client, base);
      return await _submit(client, base, username: username, password: password, csrf: csrf);
    } on GatewayLoginError {
      rethrow;
    } on HandshakeException catch (error) {
      throw GatewayLoginError(GatewayLoginErrorKind.unreachable, '无法建立 HTTPS 连接', detail: '$error');
    } on SocketException catch (error) {
      throw GatewayLoginError(GatewayLoginErrorKind.unreachable, '连不上这个地址', detail: '$error');
    } on TimeoutException {
      throw const GatewayLoginError(GatewayLoginErrorKind.unreachable, '连接超时');
    } catch (error) {
      throw GatewayLoginError(GatewayLoginErrorKind.badResponse, '登录失败', detail: '$error');
    } finally {
      client.close(force: true);
    }
  }

  /// GET 登录页：拿 CSRF（优先 cookie，退路上表单里的隐藏域）。
  Future<String> _csrf(HttpClient client, Uri base) async {
    final uri = base.replace(path: '${_prefixOf(base)}gateway/login');
    final request = await client.getUrl(uri).timeout(timeout);
    // 登录页与登录本身都自己处理跳转：成功会 302 到首页，跟着走等于白拉一次。
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) {
      throw GatewayLoginError(GatewayLoginErrorKind.notGateway, '这个地址没有 dsh-passwords 网关', status: 404);
    }
    if (response.statusCode != HttpStatus.ok) {
      throw GatewayLoginError(
        GatewayLoginErrorKind.notGateway,
        '登录页返回了 ${response.statusCode}',
        status: response.statusCode,
      );
    }
    for (final cookie in response.cookies) {
      if (cookie.name == csrfCookieName && cookie.value.isNotEmpty) return cookie.value;
    }
    final fromForm = RegExp(r'name="csrf"\s+value="([^"]+)"').firstMatch(body)?.group(1);
    if (fromForm != null && fromForm.isNotEmpty) return fromForm;
    throw const GatewayLoginError(GatewayLoginErrorKind.notGateway, '页面上没有 CSRF 字段，这可能不是 dsh-passwords 网关');
  }

  Future<GatewaySession> _submit(
    HttpClient client,
    Uri base, {
    required String username,
    required String password,
    required String csrf,
  }) async {
    final uri = base.replace(path: '${_prefixOf(base)}gateway/login');
    final request = await client.postUrl(uri).timeout(timeout);
    request.followRedirects = false;
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded')
      ..set(HttpHeaders.acceptHeader, 'text/html')
      ..set(HttpHeaders.cookieHeader, '$csrfCookieName=$csrf');
    request.write(Uri(queryParameters: {'username': username, 'password': password, 'csrf': csrf, 'next': '/'}).query);
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == HttpStatus.found ||
        response.statusCode == HttpStatus.seeOther ||
        response.statusCode == HttpStatus.ok) {
      for (final cookie in response.cookies) {
        if (cookie.name != cookieName || cookie.value.isEmpty) continue;
        return GatewaySession(
          name: cookie.name,
          value: cookie.value,
          expiresAt: DateTime.now().add(Duration(seconds: (cookie.maxAge ?? 0) > 0 ? cookie.maxAge! : 12 * 3600)),
          username: _echoedUsername(body),
        );
      }
      // 302 但没有会话 cookie：网关改了协议。
      throw const GatewayLoginError(GatewayLoginErrorKind.badResponse, '登录成功了，但没拿到网关会话 cookie');
    }
    // 网关把失败原因写在登录页 HTML 里；只按状态码分类，不去解析多语言文案。
    throw switch (response.statusCode) {
      HttpStatus.unauthorized => const GatewayLoginError(
        GatewayLoginErrorKind.invalidCredentials,
        '账号或密码不对',
        status: 401,
      ),
      HttpStatus.forbidden => const GatewayLoginError(GatewayLoginErrorKind.csrf, '网关拒绝了这次登录（CSRF）', status: 403),
      HttpStatus.tooManyRequests => GatewayLoginError(
        body.contains('锁定') || body.toLowerCase().contains('locked')
            ? GatewayLoginErrorKind.locked
            : GatewayLoginErrorKind.throttled,
        body.contains('锁定') || body.toLowerCase().contains('locked') ? '连续失败次数太多，账号被临时锁定' : '尝试太频繁，稍后再试',
        status: 429,
      ),
      HttpStatus.notFound => const GatewayLoginError(
        GatewayLoginErrorKind.notGateway,
        '这个地址没有 dsh-passwords 网关',
        status: 404,
      ),
      _ => GatewayLoginError(
        GatewayLoginErrorKind.badResponse,
        '登录失败（HTTP ${response.statusCode}）',
        status: response.statusCode,
      ),
    };
  }

  static String _prefixOf(Uri base) =>
      base.path.isEmpty || base.path == '/' ? '/' : '${base.path.replaceFirst(RegExp(r'/+$'), '')}/';

  /// 登录页回显的账号（成功重定向时页面通常不含它，失败时才用得上）。
  static String? _echoedUsername(String body) {
    final match = RegExp(r'name="username"[^>]*value="([^"]*)"').firstMatch(body)?.group(1);
    return match == null || match.isEmpty ? null : match;
  }
}

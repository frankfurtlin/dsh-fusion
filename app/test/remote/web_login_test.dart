// 网页登录的两个零件：地址归一化/持久化，以及与 dsh-passwords 网关的登录协议。
// 网关用本地 HttpServer 按 2026-11-25 在本机网关上核对的形状模拟：
//   GET  /gateway/login → Set-Cookie: dsh_csrf=<token>.<sig>，页面里有同名隐藏域
//   POST /gateway/login → 校验 cookie 与表单的 csrf；成功 302 + dsh_gateway_token
// 这样不需要真账号，也能钉住「我们发的请求就是网关认的那一套」。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/web/gateway_login.dart';
import 'package:dsh_app/remote/web/web_host_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('web host config', () {
    test('a bare domain becomes https and keeps a path prefix', () {
      expect(WebHostConfig.normalizeBaseUrl('dsh.frankfurtlin.top'), 'https://dsh.frankfurtlin.top');
      expect(WebHostConfig.normalizeBaseUrl('  https://dsh.frankfurtlin.top/  '), 'https://dsh.frankfurtlin.top');
      expect(WebHostConfig.normalizeBaseUrl('http://192.168.1.5:3080/'), 'http://192.168.1.5:3080');
      expect(WebHostConfig.normalizeBaseUrl('https://example.com/dsh/'), 'https://example.com/dsh');
      expect(WebHostConfig.normalizeBaseUrl('ftp://example.com'), isNull);
      expect(WebHostConfig.normalizeBaseUrl(''), isNull);
      expect(WebHostConfig.normalizeBaseUrl('https://example.com/?x=1'), isNull);
    });

    test('round trips through JSON, and rejects an unusable address', () {
      const config = WebHostConfig(
        id: 'web-1',
        name: 'dsh',
        baseUrl: 'https://dsh.frankfurtlin.top',
        username: 'frank',
      );
      final back = WebHostConfig.fromJson(config.toJson())!;
      expect(back, config);
      expect(back.authority, 'dsh.frankfurtlin.top');
      expect(back.loginUrl.toString(), 'https://dsh.frankfurtlin.top/gateway/login');
      expect(
        const WebHostConfig(id: 'w', name: '', baseUrl: 'https://example.com/dsh', username: 'u').loginUrl.toString(),
        'https://example.com/dsh/gateway/login',
      );
      expect(WebHostConfig.fromJson({'id': 'w', 'baseUrl': '::', 'username': 'u'}), isNull);
      expect(WebHostConfig.fromJson('nope'), isNull);
    });

    test('the connection key follows the address and account, not the name', () {
      const a = WebHostConfig(id: 'w', name: 'a', baseUrl: 'https://h', username: 'u');
      expect(a.copyWith(name: 'b').connectionKey, a.connectionKey);
      expect(a.copyWith(username: 'v').connectionKey, isNot(a.connectionKey));
    });
  });

  group('gateway login', () {
    late HttpServer server;
    late Uri base;
    late String mode;

    /// mode: 'ok' | 'wrong-password' | 'csrf' | 'missing-gateway'
    Future<void> start() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        final path = request.uri.path;
        if (path != '/gateway/login') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          // 未登录时先给一个 CSRF cookie，并在表单里回显同值。
          request.response.headers.add(HttpHeaders.setCookieHeader, 'dsh_csrf=abc123.sig456; Path=/gateway');
          request.response.headers.contentType = ContentType.html;
          request.response.write('<input type="hidden" name="csrf" value="abc123.sig456" />');
          await request.response.close();
          return;
        }
        // POST：double-submit 校验
        final body = await utf8.decoder.bind(request).join();
        final form = Uri.splitQueryString(body);
        final cookie = request.headers.value(HttpHeaders.cookieHeader) ?? '';
        final csrfOk = cookie.contains('dsh_csrf=abc123.sig456') && form['csrf'] == 'abc123.sig456';
        if (!csrfOk) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        if (mode == 'wrong-password' || form['password'] != 'right-password') {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.found;
        request.response.headers.add(
          HttpHeaders.setCookieHeader,
          'dsh_gateway_token=test.jwt.token; Path=/; HttpOnly; SameSite=Lax; Max-Age=43200',
        );
        request.response.headers.set(HttpHeaders.locationHeader, '/');
        await request.response.close();
      });
      // 'missing-gateway' 用一个不响应登录页的端口：单独在建好 server 后关掉。
    }

    setUp(() async {
      mode = 'ok';
      await start();
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('a correct account gets the session cookie and its expiry', () async {
      final session = await GatewayLogin().login(base, username: 'frank', password: 'right-password');
      expect(session.name, 'dsh_gateway_token');
      expect(session.value, 'test.jwt.token');
      expect(session.cookieHeader, 'dsh_gateway_token=test.jwt.token');
      expect(session.expiresAt, isNotNull);
      expect(session.expiresAt!.difference(DateTime.now()).inHours, greaterThanOrEqualTo(11));
    });

    test('a wrong password is reported as credentials, not as a network problem', () async {
      await expectLater(
        GatewayLogin().login(base, username: 'frank', password: 'nope'),
        throwsA(isA<GatewayLoginError>().having((e) => e.kind, 'kind', GatewayLoginErrorKind.invalidCredentials)),
      );
    });

    test('an address that is not the gateway is told apart from a bad login', () async {
      await expectLater(
        GatewayLogin().login(base.replace(path: '/nope/'), username: 'u', password: 'p'),
        throwsA(isA<GatewayLoginError>().having((e) => e.kind, 'kind', GatewayLoginErrorKind.notGateway)),
      );
    });

    test('an unreachable host is a retryable network error', () async {
      await server.close(force: true);
      await expectLater(
        GatewayLogin(timeout: const Duration(seconds: 2)).login(base, username: 'u', password: 'p'),
        throwsA(isA<GatewayLoginError>().having((e) => e.kind, 'kind', GatewayLoginErrorKind.unreachable)),
      );
      // tearDown 会再关一次，忽略。
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
  });
}

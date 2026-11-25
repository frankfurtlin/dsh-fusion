// 兴趣推送点进来的去处：Kotlin 的 DigestSync 用 `dshgo://open/digest`
// （app/android/.../digest/DigestSync.kt TAP_URI）当通知的点击意图。
// 这里守 Dart 这一端：这条页面链接必须真的解析到「发现」页，否则推送点开
// 又会落回聊天页、内容无处可看。

import 'package:dsh_app/digest/digest_page.dart';
import 'package:dsh_app/links/page_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the digest push opens 发现 through its page link', () {
    final uri = Uri.parse('dshgo://open/digest');
    expect(pageLinkId(uri), 'digest');
    expect(pageForId('digest', null), isA<DigestPage>());
  });
}

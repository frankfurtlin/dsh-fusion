// 清单签名：与 tools/pocket/manifest_sign.py 是同一套规则。
// 夹具是「真」签名（用发布私钥签的），App 用内置公钥验 —— 两边一起改才算改对。

import 'dart:convert';

import 'package:dsh_app/update/manifest_signature.dart';
import 'package:dsh_app/update/release.dart';
import 'package:flutter_test/flutter_test.dart';

/// `release.py` 写出来的那种清单 + 签名（rollout 20 的那一版）。
const signedManifest = r'''
{
 "schema": 1,
 "version": "1.1.6+11",
 "tag": "v1.1.6",
 "assets": {
  "arm64": {
   "name": "dsh-pocket-1.1.6-11-arm64.apk",
   "url": "https://static.frankfurtlin.top/apps/pocket/apk/dsh-pocket-1.1.6-11-arm64.apk",
   "size": 76533152,
   "sha256": "611d53d3127095ca98c6294feffd07592f28b2b2c25ea2777918b662a48f4bdf"
  }
 },
 "notes": "- 新增：清单签名（Ed25519）—— `update.json` 现在带 `signature` 字段，App 内置公钥，\n  清单被换掉/改过就验不过，不会再被指向别的包或旧版本\n- 新增：灰度发布 —— `update.json` 可以带 `rollout` 百分比，只有落在这一批的设备会自动\n  被提示；手动检查不受影响。`release.py --rollout 20` 就是 20% 灰度\n- 新增：App 回到前台时也会补检查一次（距上次成功超过 24 小时才查），不用再靠重启\n- 修复：1.1.5 的会话列表快照在装完后的第一次启动还没有内容，这次是第二次启动就能立刻看到",
 "publishedAt": "2026-11-26T09:00:00+08:00",
 "rollout": 20,
 "signature": "zw+lOCN4efaZpiklwx8aCtc97O+w8kkBApAz5ha8NKdxjumKAdizuuLtx3Jy/yIVO6BhezC8vW7PdX6h9Uf4CA=="
}
''';

void main() {
  test('a signed manifest verifies and parses', () async {
    final json = jsonDecode(signedManifest) as Map<String, Object?>;
    expect(await UpdateManifestSignature.verify(json), isTrue);
    final release = parseUpdateManifest(json, base: Uri.parse('https://static.example/update.json'));
    expect(release.version.toString(), '1.1.6+11');
    expect(release.rollout, 20);
    expect(release.apkFor(ApkFlavor.arm64)?.sha256,
        '611d53d3127095ca98c6294feffd07592f28b2b2c25ea2777918b662a48f4bdf');
  });

  test('one changed byte fails the signature', () async {
    final json = jsonDecode(signedManifest) as Map<String, Object?>;
    final tampered = {...json, 'rollout': 100};
    expect(await UpdateManifestSignature.verify(tampered), isFalse);
    final downgraded = {...json, 'version': '1.1.5+10'};
    expect(await UpdateManifestSignature.verify(downgraded), isFalse);
  });

  test('no signature, bad base64 and a wrong key all fail', () async {
    final json = jsonDecode(signedManifest) as Map<String, Object?>;
    final unsigned = {...json}..remove('signature');
    expect(await UpdateManifestSignature.verify(unsigned), isFalse);
    expect(await UpdateManifestSignature.verify({...json, 'signature': 'not base64!'}), isFalse);
    // 长度对但内容不对（64 字节全 0 的签名）
    expect(await UpdateManifestSignature.verify({...json, 'signature': base64Encode(List<int>.filled(64, 0))}), isFalse);
    expect(await UpdateManifestSignature.verify(null), isFalse);
  });

  test('the canonical form is sorted, compact and keeps non-ASCII', () {
    expect(
      UpdateManifestSignature.canonicalJson({'b': 1, 'a': ['中', true, null]}),
      '{"a":["中",true,null],"b":1}',
    );
    expect(UpdateManifestSignature.canonicalJson({'note': '第一行\n第二行'}), '{"note":"第一行\\n第二行"}');
  });
}

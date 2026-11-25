// 清单签名：`update.json` 的 Ed25519 签名校验（与 tools/pocket/manifest_sign.py 配对）。
//
// 为什么需要：sha256 和 APK 签名只保护「下载下来的安装包」，保护不了清单本身。
// 一份被换掉的清单能把设备指向别的 APK，或者让版本比较读到旧数据（降级）。
// 现在签的是清单内容，App 内置公钥，改一个字就验不过。
//
// 签什么：去掉 `signature` 字段后的**规范化 JSON**（键按字典序、无空白、
// 非 ASCII 原样输出、只用整数）。两侧规则必须一致，改动要两个文件一起改。
//
// 哪些源强制要求签名：自己镜像上的清单（`UpdateEndpoint.mirrorId != null`，
// 也就是 COS 那份和它的加速镜像）。自定义 feed / beta 通道是构建者自己的来源，
// 有签名就验、没有就按原样接受（仍受 HTTPS 与 APK 校验保护）。
// GitHub API 走的是另一套格式，不在签名范围内。

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// 32 字节 raw Ed25519 公钥（base64）。与 `tools/pocket/manifest_sign.py`
/// 的 `PUBLIC_KEY_B64` 是同一把；换密钥要同时改两处并重新发版。
const updateManifestPublicKey = 'mbPz2/mRA9Cc+MknoWQvpyFed1ZQdAzNN1TAbh+Txx8=';

abstract final class UpdateManifestSignature {
  /// 清单是否带着有效签名。缺签名、格式坏、内容被改过都算 false。
  static Future<bool> verify(Object? manifest) async {
    if (manifest is! Map) return false;
    final signature = manifest['signature'];
    if (signature is! String || signature.isEmpty) return false;
    final List<int> signatureBytes;
    final List<int> publicKey;
    try {
      signatureBytes = base64Decode(signature);
      publicKey = base64Decode(updateManifestPublicKey);
    } on FormatException {
      return false;
    }
    final String message;
    try {
      message = canonicalJson({
        for (final entry in manifest.entries)
          if (entry.key != 'signature') entry.key: entry.value,
      });
    } on FormatException {
      // 清单里有规范不出来的东西（浮点、非字符串键）：当作没有签名。
      return false;
    }
    try {
      return await Ed25519().verify(
        utf8.encode(message),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      // 长度不对等异常一律算验不过。
      return false;
    }
  }

  /// 规范化 JSON：与 Python 的
  /// `json.dumps(..., sort_keys=True, separators=(',', ':'), ensure_ascii=False)` 一致。
  static String canonicalJson(Object? value) {
    final out = StringBuffer();
    _write(out, value);
    return out.toString();
  }

  static void _write(StringBuffer out, Object? value) {
    switch (value) {
      case null:
        out.write('null');
      case final String text:
        // Dart 的编码器与 Python 一样只转义引号、反斜杠和控制字符，非 ASCII 原样。
        out.write(jsonEncode(text));
      case final bool flag:
        out.write(flag ? 'true' : 'false');
      case final int number:
        out.write(number);
      case final num _:
        // 清单里不用浮点：两侧的浮点格式化规则不保证一致，宁可不签。
        throw const FormatException('floats are not canonicalised');
      case final List<Object?> list:
        out.write('[');
        for (var i = 0; i < list.length; i++) {
          if (i > 0) out.write(',');
          _write(out, list[i]);
        }
        out.write(']');
      case final Map<Object?, Object?> map:
        final keys = <String>[];
        for (final key in map.keys) {
          if (key is! String) throw const FormatException('non-string key');
          keys.add(key);
        }
        // Python 按码点排序；清单的键都是 ASCII，两种排序在这里一致。
        keys.sort();
        out.write('{');
        for (var i = 0; i < keys.length; i++) {
          if (i > 0) out.write(',');
          out.write(jsonEncode(keys[i]));
          out.write(':');
          _write(out, map[keys[i]]);
        }
        out.write('}');
      default:
        throw FormatException('cannot canonicalise ${value.runtimeType}');
    }
  }
}

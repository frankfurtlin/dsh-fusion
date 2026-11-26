import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_features.dart';

/// How 语音输入 listens. [auto]: whatever can listen (the phone's service, or
/// the cloud recognizer chosen below); [cloud]: an OpenAI-compatible service
/// set up in 设置 › 语音; [system]: the phone's own service.
///
/// [deepseek] (DeepSeek's own recognizer) and [engine] (the engine's voice
/// model) are left over from before 1.2.0: the on-device engine and the
/// DeepSeek account were removed from the app, so neither can be chosen or
/// stored any more. The names stay because the recognizer code (and the pet
/// voice dialog) still spells them; nothing reaches them from 设置.
enum VoiceMode { auto, deepseek, system, engine, cloud }

/// What 识别方式 offers, in order: every value a person can pick, and every
/// value [VoiceSettingsController] can read back. [VoiceMode.deepseek] and
/// [VoiceMode.engine] are not here (1.2.0).
const voiceModeChoices = [VoiceMode.auto, VoiceMode.system, VoiceMode.cloud];

/// [mode] as it works on HarmonyOS's own engine, which has no voice model: one
/// chosen for a remote host's recognizer is automatic here.
VoiceMode voiceModeOnHarmonyLocal(VoiceMode mode) => mode == VoiceMode.engine ? VoiceMode.auto : mode;

/// HarmonyOS, talking to its own engine, which has no voice model.
final harmonyLocalVoiceProvider = Provider<bool>(
  // 手机本地引擎已删除：OS 语音朗读不再跟本机主机绑定（保留 ohos 判断）。
  (ref) => ref.watch(operatingSystemProvider) == 'ohos',
);

class VoiceSettingsController extends Notifier<VoiceMode> {
  static const preferenceKey = 'voice_recognition_mode';
  late Future<void> _loaded;

  @override
  VoiceMode build() {
    _loaded = _load();
    return VoiceMode.auto;
  }

  /// What a stored value means now. 端侧引擎与 DeepSeek 账号已于 1.2.0 移除：
  /// 「语音模型」(engine) 与「DeepSeek」(deepseek) 的旧选择静默归一到 自动，别的
  /// 认不出的值也一样。
  static VoiceMode _read(String? stored) {
    for (final mode in voiceModeChoices) {
      if (mode.name == stored) return mode;
    }
    return VoiceMode.auto;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = _read(prefs.getString(preferenceKey));
    } catch (_) {
      // Unreadable preferences: stay on auto for this run.
    }
  }

  Future<VoiceMode> ready() async {
    await _loaded;
    return ref.mounted ? state : VoiceMode.auto;
  }

  Future<void> setMode(VoiceMode mode) async {
    await _loaded;
    if (!ref.mounted) return;
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, mode.name);
  }
}

final voiceSettingsProvider = NotifierProvider<VoiceSettingsController, VoiceMode>(VoiceSettingsController.new);

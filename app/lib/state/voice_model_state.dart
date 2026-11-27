// 端侧语音模型（SenseVoice）留下的名字。模型本身随手机本地引擎在 1.2.0 一起
// 删除：没有引擎就没有放模型的地方，设置 › 语音 的「语音模型」卡片和它的下载
// 通道（原来的 VoiceModelController、voice/voice_model_download.dart，以及
// voice/voice_model_assets.dart 里的文件清单与镜像表）整条不可达，代码已经移除。
//
// 这里只留还有人在读的三样东西：首启写下的偏好键、模型的字节数（首启与系统
// 权限页说的大小），以及字节数的显示格式（实时字幕的模型卡片借用）。

/// 首启「想让 DSH Pocket 帮你做哪些事」里选了语音输入时写下的键
/// （lib/state/access_state.dart 的 onboardingWantsVoiceKey）。
///
/// 过去 VoiceModelController 读它来决定要不要开始下载；下载通道已删除，现在
/// 没有代码读它。键保留：首启仍会写，测试也用它断言首启没有再去开这条通道。
const voiceModelOnboardingKey = 'onboarding_wants_voice';

/// 过去表示「模型还没下完，下次引擎起来接着下」。下载通道已删除，没有代码再
/// 写它；保留常量，测试用它断言首启不会去开这条通道。
const voiceModelWantedKey = 'voice_model_wanted';

/// SenseVoice INT8 + tokens + Silero VAD，引擎 lock（0.2.1-rc.2）里那三份的
/// 大小之和。
const voiceModelDefaultBytes = 239233841 + 315894 + 1807522;

/// 字节数按设置页的说法显示：「240 MB」。
String voiceModelMegabytes(int bytes) => '${(bytes / 1000000).round()} MB';

// 端侧语音模型（SenseVoice）的识别器 id：现在只剩宠物语音在用。
//
// 模型本身、它的文件清单与镜像表、以及下载通道都随手机本地引擎在 1.2.0 删除
// （见 state/voice_model_state.dart 的说明）。这个常量与模型在不在本地无关：
// 它说明引擎该用哪个识别器，`speech/*` 的调用方都要带上它。

/// The recognizer id the voice-input bundle registers (`sensevoice-local`).
const voiceModelProviderId = 'sensevoice-local';

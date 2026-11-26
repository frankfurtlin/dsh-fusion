import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../phone/phone_channel.dart';
import 'connection_state.dart';
import 'sessions_state.dart';

/// UI provenance only. Native independently binds its original attachment/root.
class PhoneSkillUseOrigin {
  const PhoneSkillUseOrigin._(this.client, this.generation, this.sessionId, this.selectionRevision);
  final DshClient client;
  final MuxGeneration generation;
  final String sessionId;
  final int selectionRevision;

  static PhoneSkillUseOrigin? capture(ProviderContainer container, String sessionId) {
    // 手机本地引擎已删除：这份来源记录跟着当前活动连接（远程主机）走。
    final active = container.read(activeConnectionProvider);
    if (active.isLoading || active.hasError || active.value == null ||
        container.read(currentSessionProvider) != sessionId) {
      return null;
    }
    final client = active.value!.client;
    final generation = client.mux.generation;
    if (generation == null) return null;
    return PhoneSkillUseOrigin._(client, generation, sessionId,
      container.read(currentSessionProvider.notifier).selectionRevision);
  }

  bool current(ProviderContainer container) {
    final now = capture(container, sessionId);
    return now != null && identical(now.client, client) && identical(now.generation, generation) &&
      now.selectionRevision == selectionRevision;
  }
}

/// One prepared choice, handed to the composer without replacing its source.
class PreparedPhoneSkill {
  const PreparedPhoneSkill({required this.origin, required this.ready, required this.channel, required this.text});
  final PhoneSkillUseOrigin origin;
  final PhoneSkillReplayReady ready;
  final PhoneChannel channel;
  final String text;
  Future<bool> discard() => channel.discardSkillReplay(ready.invocation);
}

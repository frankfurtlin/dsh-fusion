# AGENTS.md

给在本仓库里工作的 agent 的项目约定。只写会真实影响改动对错的规则，细节指到权威文档。

## 这是什么

DSH Fusion：Android 端 Flutter 应用 + 服务器端 Node 手机桥。App 用 SSH 连自己的
DSH 主机，并常驻一条 WSS 让 Agent 能操作这台手机。

## 布局

```
app/lib/             Flutter 界面、Riverpod 状态、l10n
app/android/         Android 宿主：BridgeService（WSS）、A11yService（无障碍）
app/assets/pets/     内置宠物包（pack.json + 平铺 PNG）
packages/bridge-server/  服务器端手机桥（MCP + 手机 WebSocket）
packages/dsh_client/     纯 Dart 客户端：HTTP/SSE、mux、会话与工作区 API
packages/dsh_remote/     远程传输
tooling/                 构建脚本
tools/                   build-apk.sh / verify-bridge.sh
```

## 命令

```bash
(cd app && flutter pub get && flutter analyze)          # 改 Dart 必跑
(cd packages/bridge-server && node --check src/*.js)     # 改桥服务必跑
node packages/bridge-server/tools/smoke.mjs              # 桥服务冒烟（91 项）
source /root/toolchain/env.sh && tools/build-apk.sh --debug
```

## 硬规则

- **不手改生成物**：`app/build/`、`.dart_tool/`、`app/lib/l10n/gen/*`。界面文案改
  `app/lib/l10n/parts/*.arb`（中英同步）后重新生成，不要直接编辑 gen 结果。
- **只暂存明确路径**，不要 `git add .`。
- **手机桥的 caps 与实现必须一致**：`BridgeService.CAPS` 里每一条都要有一个
  `case`，服务端 `packages/bridge-server/src/tools.js` 与 `tools/fake-phone.mjs`
  同步加对应工具，否则会出现"宣告了但调用失败"。
- **宠物包**按 `docs/pets/README.md` 的硬限制来，`app/lib/pets/pet_pack_validator.dart`
  是唯一裁判；新增内置包要同时进 `app/lib/pets/pet_prefs.dart` 的 `builtInPets`
  和 `app/pubspec.yaml` 的 assets。
- **凭据与隐私**：不记录、不回显、不持久化完整的 API key / token / cookie。
- **常驻在后台**，任何新增的定时器、心跳、轮询都要说清频率和退出条件——这是这个
  App 的耗电大头。

## 构建

正式包走 GitHub Actions（`.github/workflows/android-apk.yml`），本机只做 debug
增量。真机行为（手机桥、无障碍、通知、后台保活）只有装机才能证明，桌面测试不算。

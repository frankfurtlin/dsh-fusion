# AGENTS.md

给在本仓库里工作的 agent 的项目约定。只写会真实影响改动对错的规则，细节指到权威文档。

## 这是什么

DSH Pocket：Android 端 Flutter 应用 + 服务器端 Node 手机桥。App 用 SSH 连自己的
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

## 构建（2026-11-23 起，硬规则）

- **只在本地构建**，不要用 GitHub Actions 做日常构建。跨云链路实测不可靠
  （GitHub runner → COS 传 66MB 卡死；本机 → GitHub 下载 0 B/s）。
- **给用户装机的一律用 release**（2026-11-23 用户明确要求）：`tools/build-apk.sh --release ...`。debug 包只用于我自己排查，不发给用户——debug 是 JIT，UI 慢 2–5 倍，用户会当成卡顿。
- 内部调试可在本地用 debug 构建，但**不发布**。
- 发到手机一条命令：`tools/pocket/publish_local.sh [debug|release]`（传 COS 并打印
  直链 + 字节数 + sha256）。
- debug 与 release **同密钥签名**，可互相覆盖安装且保留数据；换包不用卸载。
- R8 **默认关闭**（1.0.1 开过一次，真机一启动就退）；要开必须真机验证主要路径。
- **发布只跑一条命令**：`python3 tools/pocket/release.py`（先改版本两处 + 写 CHANGELOG，再 `--release` 构建）。它校验版本一致、CHANGELOG 有段、APK 签名与版本号，然后同步 COS 包 / GitHub Release / `update.json` 三处并回验。
- CI 仅用于「干净机器复现构建」，不是日常发布通道。

细节、环境坑、版本号约定见 [`docs/build.md`](docs/build.md)。
真机行为（手机桥、无障碍、通知、后台保活）只有装机才能证明，桌面测试不算。

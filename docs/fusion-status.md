# fusion 现状（2026-11-20）

把 dsh-Go（Flutter 原生客户端）与 dsh-mobile（作者自己的 Capacitor 套壳）合成的工作仓库。
架构决策见 [merge-architecture.md](merge-architecture.md)，逐文件移植方案见 [port-map.md](port-map.md)，
源码核实记录见 [verify-notes.md](verify-notes.md)，工具链见 [toolchain.md](toolchain.md)。

## 已经做进去的东西

| 块 | 状态 | 位置 |
|---|---|---|
| 桥服务（WSS 守护、前台服务、退避重连） | 已编译进包 | `app/android/app/src/main/java/.../bridge/BridgeService.java` |
| 桥的 Flutter 通道 | 已编译进包 | `.../bridge/BridgePlugin.kt` ↔ `app/lib/bridge/bridge_channel.dart` |
| 设置页「手机桥」 | 已编译进包 | `app/lib/bridge/bridge_settings_page.dart`、`ui/settings/index/{spots,settings_pages}.dart` |
| 端点/凭据/文件/文件浏览/收件箱 | 已编译进包 | `.../bridge/{Endpoint,Settings,CredentialStore,Files,FileBrowser,Inbox}.java` |
| 网关登录换令牌 | 已编译进 debug3 包 | `BridgePlugin.gatewayLogin`（GET 登录页取 CSRF → POST 账号密码 → 存 `dsh_gateway_token`）+ 设置页「网关登录」 |
| 从网页登录态读网关令牌 | 已编译进 debug3 包 | `BridgePlugin.gatewayCookie` + 设置页「从网页登录态读取」 |
| 无障碍自动化（A11yService） | **已搬**（第二个无障碍服务 `bridge.A11yService`），22 个 op 全宣告 | `.../bridge/A11yService.java` + `res/xml/bridge_a11y_service.xml` + `values/bridge_a11y_strings.xml` |
| 无障碍双开关 | 已做 | 系统服务开关 + 设置页「允许手机桥使用无障碍」（`Settings.a11yEnabled`） |

## 与原版 dsh-Go 的差异（身份与联网）

- **改名**：显示名 `DSH Fusion`（`AppInfo.name` + `android:label`），version `1.0.0`，包名 `top.frankfurtlin.dshfusion`。
- **去掉 GitHub star 引导**：`ui/shell/home_shell.dart` 不再挂 `StarPromptHost`，「关于」页的 star 行与 `Spots.star` 索引项一并删除。
- **去掉更新检查**：不再挂 `UpdateLaunchCheck`（原来每次启动 6 秒后打 GitHub API 查上游 release），
  「关于」页的更新项与 `Spots.updateCheck/updateAuto` 索引项删除。理由：它查的是上游仓库，会引导安装原版 App。
- **去掉上游作者信息**：「关于」页的 Bilibili / X / GitHub 作者条目与该页对应 helper 删除。
- **匿名使用统计已关闭**：原来 `app.dart` 在启动时就会起 `usageStatsProvider`，release 包里
  `UsageBuild.active` 恒为 true，每天 `POST https://go.dshtui.com/api/usage/v1` 上报
  「发了几条消息 / 用了几次语音 / 几次手机操作 / 几次分享 / 几次生成」。现在 `UsageBuild.active = false`、
  启动不再起控制器、设置里的开关置灰显示「关闭」。
- **插件市场**：内置市场（go.dshtui.com 的 index.json + dshfind 目录）不再随 App 提供；
  插件页的「浏览」改为打开**你自己 DSH 上的 dsh-market**（`https://dsh.frankfurtlin.top/dsh-market`，
  可在 `lib/links/dsh_market.dart` 或 `--dart-define=DSH_MARKET_ORIGIN=…` 改）。
- **托管分享链接已移除**：`conversationLinkMakerProvider` 恒为 null，「分享」面板不再出现「链接」；
  「我的分享链接」设置页从索引中移除。
- **论坛 / 社区已移除**：功能目录里的论坛卡片、社区页的论坛入口、`dshgo://` 论坛链接处理都删了
  （社区页本身取的是上游仓库的 community.json，也一并去掉入口）。
- **保留的功能**：分享卡与对话回放、酒馆、远程主机与中继、手机桥、无障碍、文件与相册能力。
  这些不会被砍，但其中「插件市场 / 托管分享链接 / 论坛」仍指向作者的 `go.dshtui.com`，
  属于用到才联网的功能（不是后台上报）。

## 和原版 dsh-Go 的代码差异

1. `applicationId` 改为 `top.frankfurtlin.dshfusion` —— 与原版共存，互不覆盖。
2. 多一个前台服务 `.bridge.BridgeService` + `FOREGROUND_SERVICE_CONNECTED_DEVICE` 权限 + OkHttp 依赖。
3. 设置里多一页「手机桥」（origin / 设备名 / 令牌 / 连接开关 / 无障碍入口）。
4. 手机能力宣告 22 个 op（`ping info shares clipboard.get clipboard.set notify open files.save files.open fs.roots fs.list fs.read fs.write fs.mkdir apps.list apps.launch a11y.status a11y.tree a11y.screenshot a11y.tap a11y.swipe a11y.global`）。
   bridge-server 按 `hello.caps` 决定暴露哪些 `phone_*` 工具，所以服务端零改动。
5. 许可证整体 **AGPL-3.0**（dsh-Go 的许可），移植自 dsh-mobile 的部分原为 MIT。

## 构建

```bash
tools/build-apk.sh --debug            # 153MB，秒级增量
tools/build-apk.sh --release          # ~66MB，R8 要跑 20–30 分钟（7GB 内存的机器会吃 swap）
```

环境在 `/root/toolchain/env.sh`（JDK17 / Android SDK / Flutter）。注意两件事：
- AGP 9.1.0 比 Flutter 要求的 9.1.1 低一个 patch，构建脚本默认加 `--android-skip-build-dependency-validation` 旁路；
  手动跑 gradle 时对应属性是 **`-PskipDependencyChecks=true`**。
- `sqlite3` 的 build hook 要从 github.com 下 `libsqlite3.arm64.android.so`，本机网络拿不到；
  已用代理下载并塞进 `app/.dart_tool/hooks_runner/shared/sqlite3/build/download-e684ef86/libsqlite3.so`（sha256 校验通过）。
  清过 `.dart_tool` 之后要重新塞。

## 验证

```bash
tools/verify-bridge.sh          # 一次性：桥在不在、有没有手机连上、caps、MCP 接线
tools/verify-bridge.sh --watch  # 等手机连上再报
```

判定「手机上这套真能用」的链路：
1. App 里「手机桥」填 origin + 网关令牌 → 连接；
2. 服务器 `curl 127.0.0.1:3082/healthz` 的 `phones` 变成 1；
3. `journalctl -u dsh-mobile-bridge` 里 `phone connected` 的 `caps=` 有 22 项（含 `a11y.tree`），与旧 DSH Mobile 的 caps 相同，区分靠设备名（App 里填的那个）；
4. 任一 dsh 会话里调用 `phone_ping` / `phone_info` 拿到响应。

## 已发布的可安装包（/srv/hermes/dshfusion/，公网 https://hermes.frankfurtlin.top/dshfusion/）

| 文件 | 大小 | 说明 |
|---|---|---|
| `dshfusion-release-arm64.apk` | 66,824,043 | R8 release，v2 签名，体积最小 |
| `dshfusion-release-v23-arm64.apk` | 66,876,394 | 旧代码，重签 v2+v3（小米挑剔签名时试） |
| `DSH-Fusion-1.0.0-arm64.apk` | 66,748,154 | v1+v2+v3 正式签名（CN=DSH Fusion），去掉了「发送匿名使用统计」入口 | **当前交付物**（改名 DSH Fusion、去 star/去更新检查、桥+登录+无障碍），sha256 `9b9a0d45…a729` |
| `dshfusion-release3-arm64.apk` | 66,931,803 | 旧版（未改名、含 star/更新检查）：网关登录 + 读网页登录态 + 无障碍 22 op，sha256 `393774d4…accf` —— 装这个 |
| `dshfusion-release2-arm64.apk` | 66,926,607 | 少无障碍，上一版 |
| `dshfusion-debug3-arm64.apk` | 153,661,759 | debug，**含「网关登录」+「从网页登录态读取」**，sha256 `36763d6f…84c6` —— 推荐先用这个完成首次配置 |
| `dshfusion-debug2-arm64.apk` | 153,651,695 | 上一版，只有「从网页登录态读取」 |

## 连接方式只剩一种

首启与主机管理都只留「远程主机 · SSH（只连接）」这一条路：

| 位置 | 处理 |
|---|---|
| 首启「DSH 在哪里运行」 | 删掉「本机（装 Linux 运行时）」与「和角色聊天（酒馆）」两个选项，只剩远程主机 |
| 远程主机页 | 删掉 DSH Remote 账号（中继）区块、Web 控制台、RemoteWebEntry |
| 主机切换抽屉 | 删掉「这台手机」与所有中继主机，只列 SSH 主机 |
| 新建 SSH 主机 | 默认模式从「托管启动」改为「只连接」，端口 3080 —— 不会在服务器上另起一个 dsh 实例 |

底层的中继/本机代码仍在（未删），只是没有任何入口。

## 尚未完成

- 真机安装（小米报 `packageinfo is null`，已换 66MB release 包重试）。
- 网关令牌：三条路都已实现（账号密码登录 / 从网页登录态读 / 粘贴）。release 包（R8）还停在旧代码，
  需要用 `tools/build-apk.sh --release` 重打一次才带登录功能；这台 7GB 机器跑 R8 很慢，留到验证完再做。
- 无障碍已进源码并编译通过，等下一次打包上机验证（系统里会出现第二个无障碍服务「DSH 手机桥 · 无障碍」）。
- 仓库还没整理成干净的 git 历史（当前 `.git` 是半残的 partial clone）。

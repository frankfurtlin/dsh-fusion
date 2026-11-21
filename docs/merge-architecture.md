# dshgo-fusion 合并架构

把 **DSH Go**（ccch1mneyyy/dsh-Go，Flutter 原生客户端）与 **DSH Mobile**（/root/workspace/dsh-mobile，作者本人的 Capacitor 套壳）合成一个新项目：
界面与连接层用 DSH Go，手机能力桥与外设接入层用 DSH Mobile 已被验证的实现。

## 1. 分工：谁出什么

| 层 | 来源 | 处理方式 |
|---|---|---|
| 原生聊天 UI / mux 客户端 | dsh-Go `app/` | 原样保留 |
| 三路内核（本机 Node / SSH / relay） | dsh-Go `Host` 抽象 | 原样保留 |
| SSH attachOnly（连既有 dsh 实例） | dsh-Go `app/lib/remote/ssh/**` | 原样保留，是连自己服务器的路径 |
| 手机能力 WSS 守护（BridgeService） | dsh-mobile | 移植进 `app/android` |
| 无障碍自动化（A11yService） | dsh-mobile | 移植进 `app/android` |
| 凭据加密存储（CredentialStore） | dsh-mobile | 按需移植或换 Flutter 安全存储 |
| 文件/分享入口（Files、Inbox、ShareTarget） | dsh-mobile | 二期再评估 |
| bridge-server（MCP + 手机 WSS） | dsh-mobile | **不合并**，继续独立跑在同一台服务器 |
| WebView 壳（MainActivity、Capacitor） | dsh-mobile | **丢弃** |
| mobile-ux 窄屏插件 | dsh-mobile | **丢弃**（原生 UI 不需要） |

理由：BridgeService/A11yService 只依赖 OkHttp + org.json，不依赖 Capacitor，可整类搬进 Flutter 工程的 Android 层；界面层则是 dsh-Go 明显更强，没有合并价值。

## 2. 连接拓扑（保持不变）

```
手机 App ──SSH tunnel──> 服务器 127.0.0.1:3080   (dsh web，原生 UI 走 /api/remote.mux)
手机 App ──wss://──> 服务器 /bridge/ws (Caddy → 127.0.0.1:3082 bridge-server)
                        bridge-server ──MCP──> dsh 的 mcp-phone 工具
```

两个通道互相独立：聊天不依赖桥，桥挂了只是 `phone_*` 工具不可用。合并后的手机 App 同时做这两件事，所以手机端只要装这一个 App，DSH Mobile 可以卸载。

## 3. 关键设计决定

1. **桥的鉴权沿用现状**：`Cookie: dsh_gateway_token=<token>` 连 `wss://<public-origin>/bridge/ws`。App 里给一个设置项让用户填 endpoint + 网关令牌，存在 Android Keystore 加密存储里。
2. **不把桥塞进 SSH 隧道**：Dart 侧的 SSH 隧道与 Android 原生前台服务生命周期耦合太深，二期若真需要再单独设计，不做在最小可用版本里。
3. **Flutter 与原生只通过一个 MethodChannel 交互**：查询桥状态（是否配置、是否已连、上次错误）、开关桥。其余逻辑全在原生，避免把 WSS 心跳搬进 Dart。
4. **App 启动即拉起桥**（若已配置）：前台通知常驻，符合 DSH Mobile 现在的行为，也是 Android 后台存活的最可行路径；再引导用户关掉电池优化。
5. **包名先不动**（仍为 `io.github.ccch1mneyyy.dsh_app`），降低改包名带来的 Manifest/Kotlin 目录搬迁风险；需要与原版共存时再改。

## 4. 许可证

dsh-Go 是 **AGPL-3.0**，本仓库作为其衍生作品同样是 AGPL-3.0：保留 `LICENSE`，在 `NOTICE`/`THIRD_PARTY_NOTICES.md` 里注明移植自 dsh-mobile（MIT，作者本人）的部分。自用不涉及分发义务，但对外发布时必须整仓 AGPL。

## 5. 阶段与验收

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| P0 | 构建工具链（JDK17 + Android SDK + Flutter） | `flutter build apk --debug` 在 dsh-Go 原始代码上成功 |
| P1 | 移植方案定稿 | `docs/port-map.md` 具体到文件与 Manifest 条目 |
| P2 | 桥移植 + 设置页 | 装 APK 后桥能连上：服务器 `curl 127.0.0.1:3082/healthz` 里 `phones: 1` |
| P3 | 无障碍移植 + 开启引导 | `phone_a11y_status` 返回 `service:true` |
| P4 | 真机端到端 | 在 App 里发起对话，让 agent 调 `phone_ping` / `phone_screenshot` 成功返回 |
| P5 | 打磨 | 名称/图标/文档；可选：attachOnly 的 token 自动刷新 |

## 6. 已知风险

- **后台存活**：小米的省电策略会杀前台服务之外的连接；需要"无限制"+ 自启动 + 通知常驻，P4 要专门验证锁屏 10 分钟后桥是否还在。
- **token 轮换**：attachOnly 依赖 `dsh web` 启动 token，重启即失效（cookie 30 天内可能仍有效）；P5 考虑用同一 SSH 连接自动抓取新 token。
- **构建环境**：本机网络对 GitHub / pub.dev 很慢，工具链与依赖需要走国内镜像或预下载。
- **AGPL 传染**：若将来想闭源分发，必须放弃 dsh-Go 代码，另写客户端。

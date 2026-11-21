# dshgo-fusion

dsh-Go（Flutter 原生 DSH 客户端，AGPL-3.0）与作者自己的 dsh-mobile（Capacitor 套壳 + 手机桥）的合并版。

**目标**：一个 App 里既保留 dsh-Go 的原生聊天体验与 Host 抽象（本机 / SSH / 中继），
又把 dsh-mobile 里那套经过验证的手机能力桥搬进来——手机常驻一条已认证 WSS 到服务器
的 `bridge-server`，Agent 侧的 `phone_*` 工具链就能在 App 里继续可用，不再需要单独装 DSH Mobile。

## 现在有什么

- 原生 UI / mux 客户端 / SSH attachOnly：原样来自 dsh-Go。
- 桥服务 `BridgeService`（前台服务 + 退避重连）、`BridgePlugin` 通道、设置页「手机桥」：移植自 dsh-mobile。
- 令牌获取三条路：网关账号密码登录（推荐）、从 App 网页登录态读 cookie、手动粘贴。
- 无障碍动作（`a11y.tree/tap/screenshot/...`）**还没接**，v1 只宣告只读的 `a11y.status`。

细节、差异清单、构建方式、验证步骤都在 [docs/fusion-status.md](docs/fusion-status.md)；
移植方案在 [docs/port-map.md](docs/port-map.md)，架构决策在 [docs/merge-architecture.md](docs/merge-architecture.md)。

## 快速开始

```bash
source /root/toolchain/env.sh          # JDK17 + Android SDK + Flutter
tools/build-apk.sh --debug             # 快，153MB
tools/build-apk.sh --release           # 慢（R8），~66MB
tools/verify-bridge.sh                 # 看桥和手机的连接状态
```

App 首次使用：设置 → 手机桥 → 服务器地址填自己的 DSH 域名 → 用网关账号密码登录 →
「连接手机桥」。然后在手机系统里把本 App 的省电策略设为无限制，保证后台不断线。

## 许可证

整体 **AGPL-3.0**（沿用 dsh-Go）。移植自 dsh-mobile 的代码原为 MIT，作者相同。

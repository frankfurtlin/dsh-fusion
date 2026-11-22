# DSH Fusion

把 DeepSeek Harness（DSH）装进口袋的 Android 客户端：原生 Flutter 界面，
通过 SSH 连接你自己的 DSH 主机，并把手机本身变成 Agent 的一双手。

## 它做什么

- **远程主机**：填 SSH 地址就能连上服务器上的 `dsh web`，对话、会话、工作区文件都在
  手机原生界面里操作，不再受手机浏览器排版之苦。
- **手机桥**：App 常驻一条已认证 WSS 到服务器上的 `bridge-server`，于是 DSH 里的
  Agent 获得 `phone_*` 工具——列文件、读写手机文件、读剪贴板、发通知、启动应用，
  以及无障碍自动化（截图、控件树、点击、滑动、手势返回）。
- **工作区文件**：浏览、搜索、文本 / 图片 / PDF / 表格预览，产物文件可直接保存分享。
- **宠物**：内置「水豚噜噜」等宠物包，随对话状态联动。

## 为什么是「融合」

这个项目合并了两条独立走过的路：

| 来源 | 贡献 |
|---|---|
| Flutter 原生 DSH 客户端 | 原生 UI、纯 Dart 客户端、SSH / mux 传输、会话与工作区 API |
| 早期 Capacitor 套壳版 | 手机桥（桥服务、端点/凭据、文件与无障碍）、移动端交互经验 |

当前实现状态与真机验证记录见 [`docs/fusion-status.md`](docs/fusion-status.md)，其余设计文档在 `docs/`。

## 构建

正式包走 GitHub Actions（`.github/workflows/android-apk.yml`）：手动触发，选
release/debug 与目标 ABI，产出经正式密钥签名并校验指纹的 APK。

本机调试构建（较慢，2 核机器上 release 的 R8 要 20–70 分钟）：

```bash
source /root/toolchain/env.sh      # JDK17 + Android SDK + Flutter
tools/build-apk.sh --debug
```

## 目录

```
app/                Flutter App：原生界面、Riverpod 状态、l10n、手机操控
packages/           纯 Dart 包：客户端、远程传输、SSH、酒馆
runtime/           引擎运行时与补丁
tooling/           APK 构建、构建号与各平台工具
tools/             构建与桥验证脚本
docs/              架构、设计、运维文档
port/              早期移植的 staging 源码（历史留档）
```

## 许可

整体 **AGPL-3.0**。本项目是 AGPL-3.0 项目的衍生作品，许可与第三方声明见
[LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与
[NOTICE.md](NOTICE.md)。

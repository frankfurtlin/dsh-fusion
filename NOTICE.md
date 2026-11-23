# NOTICE

DSH Pocket（下称「本项目」）是 **AGPL-3.0** 项目的衍生作品。

## 上游

- **dsh-Go**（<https://github.com/ccch1mneyyy/dsh-Go>，AGPL-3.0，作者 ccch1mneyyy）：
  本项目的 Flutter 客户端主体、UI 结构与大量实现细节来自该项目。
- **dsh-mobile**（同一作者的早期 Capacitor 套壳实现，MIT）：手机桥（WSS）、无障碍
  自动化与桥服务器（`packages/bridge-server`）的一部分从该实现移植而来。该部分的
  原始许可（MIT）被尊重，其声明列在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本项目与上述上游**没有隶属、赞助或背书关系**，上游作者不对本项目负责。

## 修改

相对上游，本项目做了大量修改，包括但不限于：包名与身份、第三方托管服务的移除
（论坛、官方插件市场、托管分享、创意工坊后端、更新镜像）、手机桥与无障碍能力的
移植与扩展、内置宠物包、远程文件预览修复、常驻连接功耗优化、品牌与图标重做。
逐项状态见 [`docs/pocket-status.md`](docs/pocket-status.md)。

## 许可与义务

本项目整体按 **AGPL-3.0** 分发：衍生作品必须延续同一协议，不能改为更宽松的协议。

- [LICENSE](LICENSE) — AGPL-3.0 全文
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — 随附的第三方代码与素材声明

按 AGPL-3.0 第 4、5 条：分发本软件的二进制时，须一并提供**对应源码**（即本仓库）、
保留上游的版权声明与许可文本，并保留上述文件；通过网络提供本软件的服务时，须向
使用者提供获取源码的方式。

## 版权

- 上游部分：© 其原作者（见上）。
- 本项目新增与修改的部分：© 2026 frankfurtlin。

随包分发的第三方素材（宠物、图标、字体、仿真器组件等）各有其授权，见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；它们**不在**本项目的 AGPL 授权范围内。

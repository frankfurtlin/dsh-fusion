# DSH Pocket 1.2.0 回归测试（真机）

- 日期：2026-11-26 21:40–22:10
- 版本：`1.2.0+18`（71.4 MB，sha256 `ed28b977…`）
- 设备：Xiaomi 24031PN0DC / Android SDK 36，网页登录主机 `dsh`
- 方式：手机桥（`phone_*`）远程操作真机，agent 自己点击与读屏

## 结论

| 项 | 结果 |
|---|---|
| 1.2.0 安装与启动 | ✅ boot 79 ms / first_page 149 ms |
| P1「登录…」修复 | ✅ 三处均显示「已连接」 |
| P3 列表 diff 合并 + 新诊断字段 | ✅ 新字段生效，`same=201 changed=0` 时不重建 |
| 启动快照 | ✅ `session_list_cached 0ms rows=93 total=201 ageS=…` |
| 会话打开 | ✅ 162 ms（1.1.10 为 8938 ms） |
| 设置：无「本机引擎」「登录 DeepSeek 账号」「酒馆」 | ✅ |
| 终端 | ✅ 直接拿到**远程主机**的 shell（`root@VM-0-12-opencloudos`） |
| 兴趣推送页 + 推送历史 | ✅ 页面正常；历史已有 3 批（09:59 / 12:17 / 18:17） |
| 酒馆残留 | ✅ 二进制中 `tavern` / 酒馆 0 次 |

## P1 证据

- 抽屉 chip：`当前主机：dsh，已连接`（修复前是「尚未连接/登录…」）
- 远程主机页：`正在使用「dsh」 · 已连接 · 端到端加密`；网页登录行 `dsh / 已连接`
- 根因（已修）：`hostLinkStatusProvider` 先 `yield link.status` 再 `yield* link.statuses`，
  而 statuses 是无缓冲广播流，async* 恢复订阅前的 `connected` 事件被丢弃；另并发 attempt 的
  迟到 `connecting` 会盖住已连接相位。现在只对当前主机建 link、先订阅后读快照、`hasClient` 兜底、
  `_connectOnce` 补 attempt 守卫。

## P3 证据（诊断 → 性能）

```
boot 79ms
first_page 149ms
session_list_cached 0ms rows=93 total=201 ageS=2674
session_open 162ms records=340 building=true
session_list 1229ms rows=201 top=93 same=0   changed=93 added=108 removed=0
session_list 833ms  rows=201 top=93 same=201 changed=0  added=0   removed=0
session_list 612ms  rows=201 top=93 same=200 changed=1  added=0   removed=0
```

- `rows=201` 里只有 `top=93` 会进抽屉（其余是 subagent 会话），与 1.1.x 的核实一致
- `same=201 changed=0` 时整表不重建 —— 抽屉不动、滚动位置不跳

## 新发现（未修，供下一版）

1. **终端输入不是可访问文本控件**：终端页能打开并拿到远程 shell，但输入区是自绘控件，
   `a11y` 无法聚焦/输入（`phone_type` 报 "focused node is not an editable text field"）。
   TalkBack 用户同样无法用读屏输入，建议给终端加一个可访问的输入通道或备用输入框。
2. **`dshgo://open/<page>` 在前台时可能不响应**：App 处于前台（会话流式中）时打开
   `dshgo://open/digest` 无反应；把 App 切到后台再从外部打开同一链接则正常跳转。
   通知点击走的是后台/冷启动路径，因此当前可用，但前台场景值得查。
3. `本机引擎` / `登录 DeepSeek 账号` 文案仍残留在二进制（l10n 类整体保留所致），无入口引用。

## 尚未覆盖（本轮没扫）

无主机首屏（需要清空当前主机，破坏性）、产出的文件 / 文件预览 / 导出对话日志 / 后台任务 /
计划与目标 / 技能 / 子代理 / 引用文件和对话、设置的插件 / 手机操控 / 联网搜索 / 图像与视频 /
通知 / 语音 / 社区 / 使用帮助 / 对话备份。

---

## 补充扫描（2026-11-26 23:40–11-27 00:10，1.2.0 真机）

| 入口 | 结果 |
|---|---|
| 设置 → 插件 | ✅ 插件市场 + 已装插件（dsh-skin 等） |
| 设置 → 手机操控 | ✅ 状态「未开启」 |
| 设置 → 图像与视频 | ✅ 空态「这台主机还没有图像与视频插件」 |
| 设置 → 通知 | ✅ 开关 + 系统设置入口 + 锁屏内容说明 |
| 设置 → 语音 | ⚠️ 仍列三项依赖已删能力的选项（见下） |
| 全部功能 → 自动化任务（`schedules`） | ✅ 全部 10 / 已开启 0 / 已结束 10，条目带耗时 |
| 全部功能 → 智能体团队（`agent-team`） | ✅ 当前会话 1 成员（lead 运行中）、0 任务 |
| 全部功能 → 工作区（`workspaces`） | ✅ 1 个工作区 root（2 个对话）、可添加 |
| 全部功能 → 产出的文件 | ✅ 空态「还没有产出文件」 |
| 全部功能 → 后台任务 | ✅ 已结束 8 条，完成/停止状态与耗时正确 |
| 全部功能 → 技能 | ✅ 技能列表（/a-stock-analysis-pro、/aihot、/arxiv、/ccf-* …） |
| `dshgo://open/community` | ⚠️ 不跳转（catalog 链接，settings 链接均正常） |

### 新发现：语音页残留已删能力

1. 识别方式「语音模型」→ 状态「当前引擎不支持语音模型」（端侧 SenseVoice 随本机引擎移除）
2. 识别方式「DeepSeek」→ 需 DeepSeek 账号（账号层已删）
3. 朗读音色「DeepSeek · 海星」→ 同账号依赖

建议 1.2.1：移除或置灰这三项，`自动` 的选择逻辑改为「系统 / 其他云端服务」，并把上表

### 未扫（时间/上下文所限）

全部功能 → 文件（浏览与预览）、导出对话日志、引用文件和对话；设置 → 使用帮助、对话备份。

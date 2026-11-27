# 1.2.0 交接单（2026-11-26 19:20）

## 代码状态
- HEAD `f5b5a85`（release: 1.2.0 版本号 + CHANGELOG），已推 CNB + GitHub
- 1.2.0 三个提交：`c758937`(P1 状态修复) / `3be3b1c`(P3 列表) / `f5b5a85`(版本+CHANGELOG)
- 前面两步删除已入主线：`17f4304`(删酒馆 597 文件) / `1c419c0`(删本地引擎 + 账号层)
- 每步都过了 `flutter analyze lib` 0 error / 0 warning
- 工作区还有 7 个 app/lib 的未提交改动（P3 之后留下的），下一轮先看是什么再决定提交或回退

## 卡点：CNB 构建拿不到产物
- `git rev-parse HEAD` = f5b5a85 的 `commit-assets/download/<sha>/app-release-unsigned.apk` 一直 404（隔 50 分钟再试仍 404）
- `cnb_fetch_sign.py` 于是取到旧 APK（1.1.12），`release.py` 版本守卫中止 → **没有发错包**
- 下一步：看 CNB 构建日志。最可能的失败原因：删掉 48 个引擎文件后，`app/android`（Kotlin 侧）仍有对本地引擎/运行时的引用（analyze 看不见）

## 已确认的产品决定
- 只连远程主机；无主机时首屏 = 「远程主机」页（用户拍板）
- 酒馆不再打包（用户拍板）
- 删本机引擎 + DeepSeek 账号/余额/云端语音/中继账号前置（用户选 A）

## 已修复 / 已完成
- P1 主机状态卡「登录…」：根因是状态流订阅前丢了 connected 事件；改为只对当前主机建 link、先订阅后读快照、hasClient 兜底、_connectOnce 补 attempt 守卫。**真机未验证**
- P3：快照写入串行化 + 超限按最旧丢弃；刷新按 id diff 合并（无变化不重建）；诊断新增 top/same/changed/added/removed/total/ageS。**真机未验证**
- 更正：`session_list_cached rows=93` 不是掉行（93 = 全部非子会话行，另 96 是 subagent 会话被过滤）；Host 的 `session/list` 不支持分页

## 待办（按顺序）
1. 查 CNB 1.2.0 构建失败原因（先看 `app/android` 对 runtime/lib 的引用）→ 修 → 重推
2. 产物就绪后：`python3 tools/pocket/cnb_fetch_sign.py` → `python3 tools/pocket/release.py --apk dist/app-arm64-release.apk --rollout 100`
3. 真机复跑 `docs/regression-checklist.md`，重点：无主机首屏、抽屉主机 chip 是否变「已连接」、远程主机页三处文案、冷启动/列表耗时
4. 补扫未覆盖入口：会话内（产出的文件/文件预览/终端/导出日志/后台任务/计划与目标/技能/子代理/引用文件）、设置里（插件/手机操控/联网搜索/图像与视频/通知/语音/社区/使用帮助/对话备份）

## 环境要点
- 仓库是 `blob:none` 部分克隆：git 要带 `GIT_NO_LAZY_FETCH=1`，删除项用 `git update-index --force-remove`，提交用 `write-tree --missing-ok` + `commit-tree` + `update-ref`；不要 `git add -A`
- 手机桥 MCP：`phone_*`；覆盖安装后 Android 常把无障碍关掉，先 `phone_a11y_status`
- CNB 构建约 10–15 分钟；产物 URL `https://cnb.cool/frankslin/frankfurtlin/dsh-pocket/-/commit-assets/download/<sha>/app-release-unsigned.apk`

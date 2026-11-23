# 参与开发

个人项目，欢迎 issue 与 PR，但不保证响应时间。

## 开发环境

- Flutter 3.50+ / Dart 3.14+、JDK 17、Android SDK 36
- 构建流程、签名、提速与已知环境坑见 [`docs/build.md`](docs/build.md)

## 提交前

```bash
(cd app && flutter analyze lib)                      # 改 Dart
(cd packages/bridge-server && node --check src/*.js) # 改桥服务
node packages/bridge-server/tools/smoke.mjs          # 桥服务冒烟（91 项）
```

## 约定

- 界面文案改 `app/lib/l10n/parts/*.arb`（中英同步）后重新生成，不要手改 `l10n/gen/`
- 提交时暂存明确路径，不要 `git add .`
- 手机桥的 `BridgeService.CAPS` 每一条都要有对应实现、服务端工具与 fake-phone 条目
- 涉及后台常驻、心跳、轮询的改动，请在 PR 里说明频率与退出条件

## 许可

提交的代码按 AGPL-3.0 授权。第三方素材需同时更新
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

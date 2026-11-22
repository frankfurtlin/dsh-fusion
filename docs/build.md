# 构建约定（2026-11-23 起）

> 决策人：Frankfurtlin。以下是硬规则，agent 默认照这个做，不要再走 GitHub Actions。

## 一句话

**构建只在本地跑；开发阶段用 debug；CI 只留给正式发布。**

## 为什么

2026-11-22/23 那一轮踩了三个坑，都是"在云上构建"带来的：

1. GitHub runner → 广州 COS 传 66 MB 会卡死（两次超过 25 分钟没完成）；而本机 → COS 是
   **86 MB/s**。跨云链路不可靠，本机是可信的。
2. 本机 → GitHub 下载 0 B/s，CI 产物拉不回来，出问题只能靠猜。
3. 第一次开 R8 的包在真机上一启动就闪退（`packageinfo is null` / 一开就退），
   而在本地构建时能当场用 `aapt` / `apksigner` 验包名、版本、ABI、签名。

本地构建 = 产物在手、可验、可立刻传到 COS 给手机装。

## 怎么构建

```bash
cd /root/workspace/dsh-fusion

# 开发：debug，单 ABI，最快
tools/build-apk.sh /root/workspace/dsh-fusion/app

# 需要验 release 行为时才用（R8 默认关闭，详见下）
tools/build-apk.sh --release /root/workspace/dsh-fusion/app
```

产物：`app/build/app/outputs/flutter-apk/app-arm64-{debug,release}.apk`，
脚本同时拷一份到 `dist/`。日志：`dist/build-{debug,release}.log`。

脚本内置工具链（JDK / Android SDK / Flutter 都在 `/root/toolchain/`），不依赖外部 env。
本机 2C/8G，debug 首次约 10–20 分钟，增量会快得多；跑的时候别同时开别的重活。

## 签名：debug 与 release 同钥

`app/android/build.gradle.kts` 里 `debug { if (hasWholeReleaseKey) signingConfig = release }`，
所以**本地 debug 包也用发布密钥签**。好处：

- debug 覆盖安装 release、release 覆盖安装 debug 都可以，**数据保留**；
- 不需要为了换包而卸载（也就不会丢配置）。

## 版本号

开发阶段不必每次改版本，但**要发出去给手机装之前**，改这两个地方（必须一致，
否则 App 里的「关于」和 APK 的 versionName 会对不上）：

- `app/pubspec.yaml` 的 `version:`（例如 `1.0.3+4`）
- `app/lib/state/app_info.dart` 的 `defaultValue`（同一个字符串）

## 发到手机（一条命令）

```bash
tools/pocket/publish_local.sh            # debug 包 → COS → 打印直链 + sha256
tools/pocket/publish_local.sh release    # 用 release 包
```

产物会传到 COS 的 `pocket/apk/`，走 `https://static.frankfurtlin.top` 出链；
下载完可以核对脚本打印的字节数与 sha256。

## R8 / 压缩

**默认关闭**。1.0.1 是第一次开 R8 的构建，真机一启动就退出（`androidx.startup`
的 Initializer 与 `ListenableWorker` 都是按类名反射实例化的，被砍即崩）。
keep 规则已补（`app/android/app/proguard-rules.pro`），要重新开启必须：

1. `flutter build apk --release -Pminify`（或直接在 gradle 里恢复默认）；
2. **真机装上跑一遍主要路径**（启动、连主机、预览文件、手机桥）再发布。

没真机验证过就别开。

## CI 的定位

`.github/workflows/android-apk.yml` 保留，但只在**正式发布**时手动触发
（`workflow_dispatch`，mode=release）。它会：

- 构建 → 校验签名指纹 → 建 GitHub Release 挂 APK → 更新 COS 上的 `update.json`。

开发阶段的 debug 包不要走它：慢、拿不回产物、还容易和本地产物混淆。

## 已知的环境坑

| 现象 | 处理 |
|---|---|
| `sqlite3` build hook 要联网下 so，本机拿不到 | 已塞进 `app/.dart_tool/hooks_runner/shared/sqlite3/build/`；清过 `.dart_tool` 要重塞 |
| `flutter test` 卡住（同上，网络） | 开发阶段以 `flutter analyze` + 真机为准 |
| Gradle 首次跑要下依赖 | 走 `storage.flutter-io.cn` / 国内镜像，已配在脚本里 |
| 本机 checkout 缺部分文件（`app/test` 等） | partial clone 拉不齐；CI 用全新 clone 不受影响，本地以 `app/lib` 为准 |

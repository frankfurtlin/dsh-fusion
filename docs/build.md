# 怎么编译（含踩过的坑）

> 2026-11-23 定稿。**这是构建的唯一权威文档**，和别的说法冲突时以本文为准。

## 0. 三条硬规则

1. **只在本地构建**。不要用 GitHub Actions 做日常构建（理由见 §8 的跨云实测）。
2. **给用户装机的包一律是 release**（2026-11-23 用户明确要求）。debug 只用于我自己排查，不发给用户 —— debug 是 JIT，UI 慢 2–5 倍，用户会当成卡顿（§6）。
3. **R8 默认关闭**；要开必须先在真机上跑通主要路径（§7 的事故复盘）。

## 1. 环境

全部内置在 `/root/toolchain/`，脚本自己 export，不依赖外部 env：

| 组件 | 路径 |
|---|---|
| Flutter | `/root/toolchain/flutter`（3.50.0 / Dart 3.14.0） |
| JDK | `/root/toolchain/jdk` |
| Android SDK | `/root/toolchain/android`（compileSdk 36，NDK 28.2） |
| 发布密钥 | `app/android/key.properties` → `/root/.secrets/dshfusion-release.jks` |

机器：**2 vCPU / 8 GB**（可用约 3.7 GB）。这是构建慢的根因，也是"不要并行跑两个构建"
的原因——两个 Gradle daemon 会把内存吃光，整机进 D 状态。

## 2. 命令速查

```bash
cd /root/workspace/dsh-pocket

tools/build-apk.sh /root/workspace/dsh-pocket/app              # debug（默认单 ABI arm64）
tools/build-apk.sh --release /root/workspace/dsh-pocket/app    # release（R8 关闭）
tools/build-apk.sh --keep-daemon ...                           # 保留 Gradle daemon（开发循环必用）
tools/build-apk.sh --all-abis ...                              # arm64 + x64（慢一倍）
tools/build-apk.sh --pub-get-only ...                          # 只解析依赖
tools/build-apk.sh --detach ...                                # 丢后台跑，agent 环境推荐
```

产物：

```
app/build/app/outputs/flutter-apk/app-<abi>-<mode>.apk        ← 脚本按这个找
app/build/app/outputs/apk/<abi>/<mode>/app-<abi>-<mode>.apk   ← Gradle 真正产在这里
dist/app-<abi>-<mode>.apk                                     ← 脚本拷一份
dist/build-<mode>.log                                         ← 完整日志
```

## 3. 耗时实测（2C / 8G）

| 场景 | 耗时 |
|---|---|
| 首次 / 清理后全量 debug | **464 s** |
| 冷 daemon、无改动 | 76 s |
| 热 daemon + pub get 跳过 + 无改动 | **8 s** |
| 改几行 Dart 后增量 | 15–40 s |
| 改 Kotlin/Java 后增量 | 60–120 s |

## 4. 提速手册（已落地）

1. **`--keep-daemon`**：daemon 冷启动是分钟级。开发循环里开着，无改动重建从 76s → 8s。
   代价：常驻 1–2.5 GB；收工 `cd app/android && ./gradlew --stop` 释放。
2. **跳过 `pub get`**：`pubspec.yaml` + `pubspec.lock` 的 sha256 存在
   `app/.dart_tool/.pub-get.stamp`，没变就跳过（省 10–20 s）。
3. **只编 arm64**：脚本默认 `--target-platform android-arm64`，别随手 `--all-abis`。
4. **配置缓存 / 并行 / build cache**：`app/android/gradle.properties` 已开
   `org.gradle.configuration-cache`、`org.gradle.caching`、`org.gradle.parallel`
   （`workers.max=2` 对齐 2 核）。别关。
5. **增量优先**：只改 Dart 就跑增量；不要为了"干净"随手 `flutter clean`（全量 7 分钟起）。
6. **别并行**：同一时间只跑一个构建。

## 5. 发到手机

```bash
tools/pocket/publish_local.sh            # debug → COS → 打印直链 / 字节数 / sha256
tools/pocket/publish_local.sh release    # release
```

走 `https://static.frankfurtlin.top/pocket/apk/...`（COS + EdgeOne），本机上传实测
**86 MB/s**。装完核对字节数，对不上就是没下全。开发包**不进** `update.json`
（那是正式发布通道），只给直链。

## 6. debug 与 release 的取舍

| | debug | release |
|---|---|---|
| UI 流畅度 | JIT，慢 2–5 倍 | 正常 |
| 体积 | ~149 MB | ~72 MB |
| 用途 | 抓日志、调试 | 日常使用、发给别人 |
| 签名 | **同一把发布密钥** | 同 |

`app/android/app/build.gradle.kts` 里 `debug { if (hasWholeReleaseKey) signingConfig = release }`，
所以 debug ↔ release 可以**互相覆盖安装且保留数据**，换包不用卸载。
（这条很重要：早期因包名不同 / 卸载重装，配置丢过两次。）

## 7. R8 事故复盘（2026-11-23）

**现象**：1.0.1 装上后"一开就自动关闭"。

**原因**：那是第一版开启 R8 的构建。R8 会删除/改名只在运行时按类名引用的类：

- `androidx.startup` 的 `Initializer`（WorkManager 靠 manifest meta-data 里的类名实例化）
- 继承 `ListenableWorker` 的 `DigestWorker`

任何一类被砍，进程启动就 `ClassNotFoundException`。

**处置**（已落地，别回退）：

- release 默认**不压缩**，要开得显式 `-Pminify`；
- `app/android/app/proguard-rules.pro` 补齐 `androidx.work` / `androidx.startup` /
  `ListenableWorker` / `digest` 包的 keep；
- `MainActivity` 里排期调用包 `runCatching`——WorkManager 出任何问题都不该拖死 App。

**重开 R8 的门槛**：真机跑过「启动 / 连主机 / 预览文件 / 手机桥」四条主路径，否则不许发。

## 8. CI 的定位（为什么不让它日常构建）

`.github/workflows/android-apk.yml` 保留，只用于**正式发布**（`workflow_dispatch`，mode=release）：
构建 → 校验签名指纹 → 建 GitHub Release 挂 APK → 更新 COS 上的 `update.json`。

实测理由：

| 链路 | 实测 |
|---|---|
| 本机 → COS | 86 MB/s（65 MB 用 0.8 s） |
| GitHub runner → 广州 COS | 传 66 MB **超过 25 分钟没完成**（两次） |
| 本机 → GitHub 下载 | **0 B/s**（直连与 ghfast 都拉不动） |

产物拉不回来 → 出问题只能猜；本地构建能当场用 `aapt` / `apksigner` 验。

## 9. 坑清单（照这个查，别重犯）

| 现象 | 原因 | 处理 |
|---|---|---|
| 装上"packageinfo is null"或一启动就退 | ①APK 没下全 ②R8 砍了反射类 | 先核字节数/sha256；再看 §7 |
| 脚本报 `build FAILED — fresh_apks=0`，但 `outputs/apk/*/release/` 里有 APK | Gradle 判定 UP-TO-DATE，不产新文件 | **已修**：脚本识别 flutter 那句 `failed to produce an .apk file`，复用既有产物并返回 0 |
| `Gradle build failed to produce an .apk file` | Flutter 按 `outputs/flutter-apk/app-<mode>.apk` 找，实际在 per-ABI 子目录 | 脚本已处理；手动时从 `outputs/apk/<abi>/<mode>/` 拷 |
| `sqlite3` build hook 卡住 / 下载失败 | hook 要联网下 `libsqlite3.*.so`，本机到不了 | 已塞进 `app/.dart_tool/hooks_runner/shared/sqlite3/build/`；清了 `.dart_tool` 要重塞 |
| `flutter test` 长时间无输出 | 同上 | 开发阶段以 `flutter analyze` + 真机为准 |
| `git checkout` 报缺 blob / 缺 `app/test`、`app/ohos` | partial clone（`blob:none`）+ 稀疏检出，约 3000 个文件没落盘 | **别** `git checkout -- .`（会覆盖未提交改动）；按需 `git show HEAD:<path> > <path>`；CI 用全新 clone 不受影响 |
| `pkill -f <模式>` 把当前 shell 杀掉 | 模式匹配到自己的命令行 | 用 `pgrep` 取 PID 再按 PID 杀 |
| `gh release upload` 资产名不对 / 改名后 URL 404 | gh 保留本地文件名；API 改名后 CDN 路径 404 | 上传前把文件复制成目标名字（见 `publish_ci.py`） |
| `--keep-daemon` 后整机变卡 | daemon 常驻 1–2.5 GB | 收工 `./gradlew --stop`；别同时开两个构建 |
| 版本号对不上（关于页 vs APK） | `pubspec.yaml` 与 `app_info.dart` 两处 | 发出去之前两处一起改（§10） |

## 10. 版本号

两处必须一致，否则「关于」显示与 APK 的 versionName 会打架：

- `app/pubspec.yaml` → `version: 1.0.3+4`
- `app/lib/state/app_info.dart` → `defaultValue: '1.0.3+4'`

开发阶段可以不改；**要发到手机之前**改。

## 11. 提交前必须跑

```bash
(cd app && flutter analyze lib)                          # 改 Dart 必跑
(cd packages/bridge-server && node --check src/*.js)     # 改桥服务必跑
node packages/bridge-server/tools/smoke.mjs              # 桥服务冒烟（91 项）
```

# Flutter / Android 工具链（本机实装）

这台机器（腾讯云 OpenCloudOS 9.6，root，7.6G 内存）原本没有任何 Android 构建能力。
下面是**已经实际跑通**的那条路：JDK 17 → Android SDK → Flutter 3.50.0 → Gradle 9.5.0（走腾讯镜像）
→ Maven 依赖（走阿里云镜像）→ `flutter build apk --debug` 产出 APK。

所有组件都在 `/root/toolchain` 下，不污染系统（dnf 只有 openjdk 8，没用它）。

```
/root/toolchain/
├── env.sh                      # 全部环境变量，source 它即可
├── jdk/                        # Temurin JDK 17.0.21+9
├── android/                    # ANDROID_HOME：cmdline-tools/ platform-tools/ platforms/ build-tools/ ndk/
├── flutter/                    # Flutter 3.50.0 stable（Dart 3.14.0）
├── hello/                      # 冒烟测试工程（flutter create 生成）
└── downloads/                  # 安装包与构建日志
```

## 用法

```bash
source /root/toolchain/env.sh          # 之后 java / sdkmanager / adb / flutter / dart 都可用

# 一键构建（默认目标 /root/workspace/dsh-pocket/app）
/root/workspace/dsh-pocket/tools/build-apk.sh                       # debug APK
/root/workspace/dsh-pocket/tools/build-apk.sh --release <项目目录>   # release APK
/root/workspace/dsh-pocket/tools/build-apk.sh --detach              # 后台 systemd 单元，防断连
```

产物：`<项目>/build/app/outputs/flutter-apk/app-debug.apk`

> 2026-11-20 起这个脚本默认只构建 arm64（`--all-abis` 回退），构建结束会 `gradlew --stop`，
> `--detach` 的 systemd 单元带 `MemoryHigh=3G / MemoryMax=4G`。正式包的 CI 构建与发布签名见
> [`docs/ops/android-ci.md`](ops/android-ci.md)。

## 已安装版本

| 组件 | 版本 | 位置 | 环境变量 |
|---|---|---|---|
| JDK (Temurin) | 17.0.21+9 | `/root/toolchain/jdk` | `JAVA_HOME` |
| Android cmdline-tools | 19.0 (sdkmanager 12.0) | `/root/toolchain/android/cmdline-tools/latest` | `ANDROID_HOME` |
| platform-tools | 36.x | `/root/toolchain/android/platform-tools` | `adb` |
| platforms | android-35, android-36 | `/root/toolchain/android/platforms` | — |
| build-tools | 35.0.0, 36.0.0 | `/root/toolchain/android/build-tools` | — |
| NDK | 28.2.13676358（Flutter 默认要求，AGP 自动装的） | `/root/toolchain/android/ndk` | — |
| Flutter | 3.50.0 stable（revision ab2912035e） | `/root/toolchain/flutter` | `FLUTTER_ROOT` |
| Dart | 3.14.0（随 Flutter） | `/root/toolchain/flutter/bin/cache/dart-sdk` | — |
| Gradle | 9.5.0（wrapper 预置） | `/root/.gradle/wrapper/dists/gradle-9.5.0-all` | `GRADLE_USER_HOME=/root/.gradle` |
| AGP / Kotlin | 9.3.1 / 2.4.20（由工程模板决定，非本机安装） | — | — |

`flutter doctor` 结论（2026-11-20）：

```
[✓] Flutter (Channel stable, 3.50.0, on OpenCloudOS 9.6 6.6.119-51.5.oc9.x86_64, locale en_US.UTF-8)
[✓] Android toolchain - develop for Android devices (Android SDK version 36.0.0)
[✗] Chrome - develop for the web          ← 主机没装浏览器，与 Android 构建无关
[✗] Linux toolchain                        ← 缺 cmake/ninja/GTK，与 Android 构建无关
[!] Network resources                      ← 只因 github.com 不通（超时），不影响构建
[✓] Connected device (1 available)         ← Linux (desktop)
```

> `flutter doctor` 的 Network resources 检查会卡 ~135 秒等 github 超时，日常别跑；
> 需要时 `flutter doctor --no-version-check`。

## 各环节的坑（按遇到顺序）

### 1. JDK 17：dnf 没有，用清华 Adoptium 镜像 tarball
```bash
curl -L -o jdk17.tar.gz https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz
mkdir -p /root/toolchain/jdk && tar -xzf jdk17.tar.gz -C /root/toolchain/jdk --strip-components=1
```
（tarball 名要自己 `ls` 那个目录，版本号会变。2.5MB/s，约 190MB。）

### 2. Android SDK：走 dl.google.com，快
```bash
curl -L -o cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
mkdir -p /root/toolchain/android/cmdline-tools/tmp && cd $_
unzip -q ~/downloads/cmdline-tools.zip && mv cmdline-tools ../latest
yes | sdkmanager --sdk_root=/root/toolchain/android \
  "platform-tools" "platforms;android-36" "platforms;android-35" "build-tools;36.0.0" "build-tools;35.0.0"
yes | flutter doctor --android-licenses      # 必须，否则 doctor 报 licenses
```
NDK **不用手动装**：AGP 发现缺 `28.2.13676358` 时会自动用 sdkmanager 下载（1.3GB，走 dl.google.com 很快），
第一次构建会因此多花一点时间，之后就走缓存了。

### 3. Flutter SDK：storage.flutter-io.cn 实测很快（~4-17MB/s，1.5GB）
```bash
curl -L -o flutter.tar.xz https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux/flutter_linux_3.50.0-stable.tar.xz
mkdir -p /root/toolchain/flutter && tar -xJf flutter.tar.xz -C /root/toolchain/flutter --strip-components=1
```
- 版本清单：`https://storage.flutter-io.cn/flutter_infra_release/releases/releases_linux.json`
  （选 stable 且 `dart_sdk_version` 满足工程 `sdk:` 约束的版本；3.50.0 带 Dart 3.14.0）
- 必须的镜像环境变量：`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`、`PUB_HOSTED_URL=https://pub.flutter-io.cn`
  （pub.dev 直连只有 38KB/s）
- **两个必做的修坑**（否则每次 `flutter` 调用都卡 136 秒 github 超时，甚至直接失败）：

  ```bash
  # a) release tarball 里的 .git 属主是 1000:1000，git 会报 "dubious ownership" 直接退出 128
  chown -R root:root /root/toolchain/flutter
  git config --global --add safe.directory '*'

  # b) flutter 启动时会 `git fetch --tags` 探测版本 → origin 指向本地自身，瞬间返回
  git -C /root/toolchain/flutter config remote.origin.url "file:///root/toolchain/flutter"
  ```
  修好之后 `flutter --version` 0.26s，`flutter doctor` 3s。没修之前连 `flutter build` 都会被
  子进程 `compileFlutterBuildDebug` 拖死（报 `Process 'command .../bin/flutter' finished with non-zero exit value 128`）。

### 4. Gradle 发行包：腾讯/华为镜像，预置进 wrapper 缓存
`services.gradle.org` 只有 20KB/s。做法是**不改工程文件**，直接把发行包塞进 wrapper 缓存目录
（目录名 = base36(md5(distributionUrl))，Gradle 就是这么算的）：

```bash
/root/workspace/dsh-pocket/tools/seed-gradle-dist.sh <项目>/android
```
脚本会自动读 `gradle/wrapper/gradle-wrapper.properties` 里的版本，从
`mirrors.cloud.tencent.com/gradle/`（失败再试 `mirrors.huaweicloud.com/gradle/`）拉包并解压到
`/root/.gradle/wrapper/dists/<name>/<hash>/`，再 touch `.ok`。之后 wrapper 不再联网。

### 5. Maven 依赖：阿里云镜像（repo.maven.apache.org 只有 53KB/s）
`/root/.gradle/init.d/mirrors.gradle` 会自动生效（所有构建，包括 Flutter 的 included build），
它把慢源**原地改写**成阿里云镜像，不打乱仓库顺序：

| 原仓库 | 改写为 |
|---|---|
| dl.google.com/dl/android/maven2 | https://maven.aliyun.com/repository/google |
| repo.maven.apache.org / repo1.maven.org | https://maven.aliyun.com/repository/central |
| plugins.gradle.org/m2 | https://maven.aliyun.com/repository/gradle-plugin |

实测：maven central 直连 53KB/s → 阿里云 707KB/s。首次全量解析 AGP 9.3.1 + Kotlin 2.4.20
大概要下 1.5GB 依赖，缓存到 `/root/.gradle/caches`（最终约 1.5–2GB）。

> Gradle daemon 的堆是工程 `gradle.properties` 里写死的 `-Xmx8G`；本机只有 7.6G 内存且还有别的服务在跑，
> 内存紧张时构建会明显变慢（swap 打满）。不是工具链问题。

### 6. 构建过程要脱离调用会话
这台机器上 DSH/agent 的 shell 会话结束时，前台子进程会被连带杀掉（实测 flutter 客户端被 SIGTERM，
而 gradle daemon 活着空转 → 构建"看起来卡住"）。所以：

```bash
systemd-run --unit=my-build --collect --setenv=HOME=/root \
  bash -lc 'source /root/toolchain/env.sh; cd <项目> && flutter build apk --debug'
journalctl -u my-build -f          # 跟日志
```
`HOME` 必须显式传：systemd 单元默认没有 `HOME`，dart 会报
`Could not find the pub cache. No 'HOME' environment variable exists.`（exit 65）。
`tools/build-apk.sh --detach` 已经封装好这些。

## 已验证的构建结果

| 工程 | 命令 | 结果 |
|---|---|---|
| `/root/toolchain/hello`（`flutter create` 空工程） | `flutter build apk --debug` | ✅ `Built build/app/outputs/flutter-apk/app-debug.apk`（157MB，47s，含 debug 全 ABI） |

`/root/workspace/dsh-pocket/app` 的真实工程构建结论见下一节。

## 真实工程（dshgo-fusion）现状

**阻塞点不在工具链，在源码**：`/root/workspace/dsh-pocket` 是
`git clone --filter=blob:none --sparse --depth 1` 来的（对象库里只有 tree，没有 blob），
`app/` 目录一直没被 checkout 出来（工作区里只有 `docs/`、`tools/`）。
补 checkout 需要回 github 拉 blob，而到 github.com / raw.githubusercontent.com 的连接是超时的。
所以本机目前**没有** `app/pubspec.yaml` 可构建。

拿到源码后（`app/` 出现，或从别处拷来完整工程），直接：

```bash
source /root/toolchain/env.sh
/root/workspace/dsh-pocket/tools/build-apk.sh --pub-get-only /root/workspace/dsh-pocket/app   # 先验证依赖解析
/root/workspace/dsh-pocket/tools/build-apk.sh /root/workspace/dsh-pocket/app                 # 再构建
```

已知的工程级风险（不是本机环境问题，构建时才会暴露）：
- `pubspec.yaml` 要求 `sdk: ^3.13.4`，本机 Dart 3.14.0 满足；若工程还要求别的 Flutter 版本，`pub get` 会直接报版本冲突。
- 工程若自带 `gradle-wrapper.properties` 指向别于 9.5.0 的 Gradle，先跑一次 `tools/seed-gradle-dist.sh`。
- release 构建若开了 R8/混淆或签名，需要 `android/key.properties`，属于工程配置问题。

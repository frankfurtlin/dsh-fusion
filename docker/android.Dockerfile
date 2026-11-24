# Android 构建镜像：Flutter 3.50.0 + Android SDK 36 + JDK 17
#
# 为什么要预烤成镜像（2026-11-24）：
#   CNB 的数据卷（docker.volumes）在本仓库不可写——容器用 userns 重映射，卷的
#   属主在容器里没有写权限，探测后只能退回 /tmp，等于没有缓存。每次现装
#   Flutter+SDK+引擎产物要 13.6 分钟。改成预建镜像后由 CNB 按 `by:` 的哈希缓存，
#   只有改动本文件才重建。
#
# 基础镜像必须是 ubuntu（不能用 eclipse-temurin）：temurin 下 Flutter 解压自己的
# gradle-wrapper 会报 "Cannot mkdir: Function not implemented"。
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 \
    FLUTTER_HOME=/opt/flutter \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    PUB_HOSTED_URL=https://pub.flutter-io.cn \
    FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
    # 容器 userns 未映射 Flutter 产物里的 uid/gid，tar 的 chown 会失败
    TAR_OPTIONS=--no-same-owner

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl unzip xz-utils ca-certificates openjdk-17-jdk-headless \
 && rm -rf /var/lib/apt/lists/*

# Flutter 3.50.0（Dart 3.13.4，与 app/pubspec.yaml 的 ^3.13.4 对齐）
RUN git clone --depth 1 --branch 3.50.0 \
      https://mirrors.tuna.tsinghua.edu.cn/git/flutter-sdk.git "$FLUTTER_HOME" \
 && git config --global --add safe.directory "$FLUTTER_HOME"

# Android SDK 36
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
 && curl -fL --retry 3 -o /tmp/cmdline.zip \
      https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
 && unzip -q /tmp/cmdline.zip -d "$ANDROID_HOME/cmdline-tools" \
 && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
 && rm -f /tmp/cmdline.zip \
 && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true

RUN "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install \
      "platform-tools" "platforms;android-36" "build-tools;36.0.0"

ENV PATH="$FLUTTER_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

# 把 dart-sdk 与 android 引擎产物烤进镜像（否则每次构建还要再下 ~700MB）
RUN flutter --version \
 && flutter precache --android --no-ios --no-web --no-linux --no-windows --no-macos

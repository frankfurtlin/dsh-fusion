# Android 构建镜像：Flutter 3.50.0 + Android SDK 36 + JDK 17
#
# 为什么用镜像而不是在流水线里现装：CNB 流水线沙箱的文件系统对 tar 的
# mkdir/open 返回 ENOSYS（"Function not implemented"），Flutter 自己解压
# 引擎产物时必然失败。docker build 的执行上下文没有这个限制。
FROM eclipse-temurin:17-jdk

ENV DEBIAN_FRONTEND=noninteractive \
    FLUTTER_HOME=/opt/flutter \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    PUB_HOSTED_URL=https://pub.flutter-io.cn \
    FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip xz-utils git file ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Flutter 3.50.0（Dart 3.13.4，与 app/pubspec.yaml 的 ^3.13.4 匹配）
RUN git clone --depth 1 --branch 3.50.0 \
      https://mirrors.tuna.tsinghua.edu.cn/git/flutter-sdk.git "$FLUTTER_HOME" \
 && git config --global --add safe.directory "$FLUTTER_HOME"

# Android SDK
RUN mkdir -p "$ANDROID_HOME/cmdline-tools" \
 && curl -fL -o /tmp/cmdline.zip \
      https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
 && unzip -q /tmp/cmdline.zip -d "$ANDROID_HOME/cmdline-tools" \
 && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
 && rm -f /tmp/cmdline.zip \
 && yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true

RUN "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install \
      "platform-tools" "platforms;android-36" "build-tools;36.0.0"

ENV PATH="$FLUTTER_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

# 预跑一次，把 dart-sdk / engine 产物烤进镜像（避免每次构建再下 700MB）
RUN flutter --version && flutter precache --android --no-ios --no-web --no-linux --no-windows --no-macos

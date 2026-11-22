# R8 rules for the release build (Flutter adds its own on top).

# Conscrypt's pre-Lollipop socket adapters reference platform classes that
# don't exist on minSdk 26; those paths are never reached.
-dontwarn com.android.org.conscrypt.SSLParametersImpl
-dontwarn org.apache.harmony.xnet.provider.jsse.SSLParametersImpl

# 不打扰模式: the privileged process is started by class name, outside R8's
# view (Shizuku UserService, `app_process … PrivilegedDisplayMain` over self-ADB),
# and talks to the app through a hand-written Binder and Parcel/Bundle protocol.
-keep class top.frankfurtlin.dshfusion.phone.background.** { *; }

# Independent Shizuku service and self-ADB/app_process command entry points.
-keep class top.frankfurtlin.dshfusion.phone.shell.** { *; }

# The one-attempt self-update UserService is loaded by Shizuku outside R8 references.
-keep class top.frankfurtlin.dshfusion.update.privileged.** { *; }

# ONNX JNI looks up exception/value classes and constructors by their original names.
# Without these, an inference error aborts the process instead of throwing OrtException.
-keep class ai.onnxruntime.** { *; }

# Bouncy Castle and Conscrypt look providers and algorithms up by name;
# libadb-android drives both for wireless-debugging pairing and TLS.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class org.conscrypt.** { *; }
-keep class io.github.muntashirakon.adb.** { *; }

# Agent/phone bridge (ported from dsh-mobile): the foreground service, its ops and the
# Flutter plugin are all reached by name from the framework (Service/FlutterPlugin), and
# OkHttp's WebSocket listener is invoked reflectively by its own internals.
-keep class top.frankfurtlin.dshfusion.bridge.** { *; }
-keep class okhttp3.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**

# WorkManager / androidx.startup：Initializer 与 Worker 都是按类名反射实例化的，
# 被 R8 改名或删除后进程一启动就崩（2026-11-23 的事故）。
-keep class androidx.work.** { *; }
-keep class androidx.startup.** { *; }
-keep class * extends androidx.work.ListenableWorker { *; }
-keepnames class * extends androidx.work.ListenableWorker
-keep class top.frankfurtlin.dshfusion.digest.** { *; }

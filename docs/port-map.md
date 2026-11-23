# port-map：dsh-mobile 手机桥 → dsh-Go 移植方案


> 本文记录当时的合并方案与路径。**实现已经变化**：Android 包名已改为
> `top.frankfurtlin.dshfusion`，仓库目录为 `/root/workspace/dsh-pocket`，
> 技能包为 `dsh-pocket-*`。阅读时以当前代码为准。

> 读者：直接照此改代码的 agent。
> 目标仓库 `/root/workspace/dsh-pocket`（dsh-Go fork），源仓库 `/root/workspace/dsh-mobile`。
> 上位文档：`docs/merge-architecture.md`（分工、拓扑、阶段 P0–P5）。本文只回答“具体改哪个文件、加哪几条 Manifest、写哪些方法”。
> 结论以文中“**已核实**”标注者为据；标“**待复核**”的条目在 `app/` 源码完整 checkout 后必须再读一遍原文。

---

## 0. 结论摘要

1. **搬 5 个纯 Java 类 + 1 个服务**：`Endpoint`、`CredentialStore`(改名 TokenStore)、`Files`、`FileBrowser`、`Inbox`、`BridgeService`。它们只依赖 `android.*` + `org.json` + `okhttp3`，与 Capacitor 无关（已核实逐 import）。
2. **只加一个依赖**：`com.squareup.okhttp3:okhttp:4.12.0`。dsh-Go 现在没有 OkHttp（已核实 `app/android/app/build.gradle.kts` 的 `dependencies {}`）。
3. **一个 MethodChannel `dsh/bridge`**（+ `EventChannel dsh/bridge/events`），命名沿用 dsh-Go 现有 `dsh/phone` 约定（已核实 `PhonePlugin.kt:80-82`）。桥的连接、心跳、重连全部留在原生；Dart 只读状态和开关。
4. **v1 只宣告 16 个 op**（15 个非无障碍 + 只读的 `a11y.status`；再把 `shares` 搬上则 17 个）。`a11y.tree/screenshot/tap/swipe/global` 这 5 个动作 op 留到 P3。理由：bridge-server 按 hello 里的 `caps` 决定暴露哪些工具，不宣告就等于关闭，服务端零改动。
5. **最有价值的一条警告**：dsh-Go 的 `network_security_config.xml` **只允许 127.0.0.1 / localhost 明文**（已核实），而 dsh-mobile 是 `usesCleartextTraffic="true"`。用 `http://192.168.x.x:3081` 这类局域网地址配桥一定连不上，且报错是 `WebSocket 握手失败`，看不出根因。见 §7.1。

工程量：接到能用的“桥 + 设置页”约 **1200–1500 行**（其中 900 行是原样搬过去的），无障碍另算 **300–800 行**取决于选哪条路线（§6）。

---

## 1. 边界：搬什么、不搬什么

### 1.1 为什么值得搬

dsh-Go 已经有一套**本机**手机能力：Linux rootfs 里的 agent 通过 abstract unix socket / loopback TCP 连 `phone/PhoneBridge.kt`，由 `phone/McpServer.kt` 提供 `mcp__phone__*` 工具（已核实两个文件）。这条链路的模型是“agent 跑在手机上，操控这台手机”。

dsh-mobile 的 `BridgeService` 是**反方向**：手机主动连到 `wss://<公网 origin>/bridge/ws`，由服务器上的 bridge-server 把它当成一台远端设备，向服务器上的 agent 暴露 `phone_*` 工具。两套东西不重复，合并后的 App 两条链路可以同时存在：

```
                 ┌──────────── 手机 (io.github.ccch1mneyyy.dsh_app) ────────────┐
 服务器 dsh web ──SSH mux──> Flutter UI   (dsh-Go 原有)
                 │                                                              │
 服务器 bridge-server <──wss /bridge/ws── BridgeService ──> Files/FileBrowser/A11y │ ← 本次移植
                 │                                                              │
 rootfs 内 agent <──abstract socket── PhoneBridge/McpServer ──> phone/a11y/*      │ (dsh-Go 原有)
                 └──────────────────────────────────────────────────────────────┘
```

### 1.2 明确不搬

| 源文件 | 行数 | 不搬的理由 |
|---|---|---|
| `MainActivity.java` | 1119 | Capacitor WebView 壳；dsh-Go 是 `FlutterActivity`。只借它的 `startBridge()/seedCookie()/webToken()` 三个方法的**语义**（§5.1、§4.2） |
| `SetupActivity.java` | 346 | 手填 endpoint 的备用 UI；功能被 Flutter 设置页替代 |
| `ShareTargetActivity.java` | 82 | dsh-Go 已有 `share/ShareActivity.kt` + `SharePlugin.kt`（已核实 Manifest 里同一职责的 SEND/SEND_MULTIPLE 入口），再注册一个会出两个分享目标 |
| `mobile-ux` 插件 | — | 窄屏 Web UI 适配，原生 UI 不需要 |
| bridge-server | — | 保持独立进程、独立 systemd unit，本次不动 |

`Inbox.java` 只在 `shares`（分享收件箱）这个 op 里用；dsh-Go 有自己的分享入库路径，**v1 可以不搬**，把 `shares` 从 CAPS 里去掉（见 §2.3 的可选行）。

---

## 2. 文件级映射

源目录（下称 `$SRC`）= `/root/workspace/dsh-mobile/packages/mobile-shell/android/app/src/main/java/top/frankfurtlin/dshmobile/`
目标目录（下称 `$DST`）= `/root/workspace/dsh-pocket/app/android/app/src/main/java/io/github/ccch1mneyyy/dsh_app/bridge/`

> 包名保持 `io.github.ccch1mneyyy.dsh_app`（merge-architecture §3.5 已决定），只加子包 `.bridge`。
> **注意**：Kotlin 源在 `src/main/kotlin/`，Java 源放 `src/main/java/`，AGP + kotlin-android 会自动一起编译，**不需要**往 `build.gradle.kts` 里加 `java.srcDirs`。`src/main/java` 目录当前不存在，新建即可。

### 2.1 原样搬（改动只有 `package` 行和几处引用）

| 源 | 目标 | 行数 | 需要改的地方 |
|---|---|---|---|
| `Endpoint.java` | `bridge/Endpoint.java` | 139 | 只改 `package`。纯 JDK（`java.net.URI`），有 `EndpointTest` 可一起搬成 JVM 单测 |
| `CredentialStore.java` | `bridge/TokenStore.java` | 175 | 类名改 `TokenStore`；prefs 名 `dsh_mobile_creds` → `dsh_bridge_creds`；Keystore 别名 `dsh_mobile_gateway_token` → `dsh_bridge_gateway_token`。`seal/open` 两个静态方法保留（JVM 可测，且 `AndroidKeyStore` 不允许调用方给 IV，见源码注释） |
| `Files.java` | `bridge/Files.java` | 140 | 只改 `package`。MediaStore 落盘 + `IS_PENDING`，不弹系统框，正好满足无人值守 |
| `FileBrowser.java` | `bridge/FileBrowser.java` | 677 | 只改 `package`。仅依赖 `android.*`（`DocumentsContract`/`MediaStore`），无第三方。**待复核**：是否要保留 SAF `tree` 这一扇门（dsh-Go 已有 `MANAGE_EXTERNAL_STORAGE` 的“访问手机文件”模式，两套文件视图并存会让人困惑） |
| `Inbox.java` | `bridge/Inbox.java` | 165 | 可选（仅 `shares` 用）。要搬则只改 `package` |
| `res/xml/a11y_service.xml` | `res/xml/bridge_accessibility_service.xml` | 30 | 见 §2.2 最后一节 |

### 2.2 需要改写的三处

**(a) `BridgeService.java`（749 行）→ `bridge/BridgeService.java`**

保留全部协议逻辑（hello/call/res、`BACKOFF_MS={2,4,8,15,30,60}s`、`pingInterval(20s)` + `readTimeout(0)`、两个通知渠道 `dsh_bridge_status`/`dsh_agent_messages`、`STATUS_NOTIFICATION_ID=71`、`FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE` 与“系统拒绝前台服务时降级并写状态”的 try/catch）。改动清单：

1. `package` → `io.github.ccch1mneyyy.dsh_app.bridge`。
2. `import top.frankfurtlin.dshmobile.R` → `import io.github.ccch1mneyyy.dsh_app.R`（同模块，`R.drawable.ic_stat_dsh` **已存在**于 dsh-Go 的 `res/drawable/ic_stat_dsh.xml`，无需拷贝图标）。
3. `Settings.getEndpoint()` / `Settings.a11yEnabled()` → `BridgeConfig.get(this)`（§2.2(b)）。
4. `CredentialStore(this).load(endpoint.host)` → `TokenStore(this).load(endpoint.host)`。
5. 静态字段 `public static volatile String status` 不再对外（旧的 `DshMobile.bridgeStatus()` 桥接口随 Web 壳一起消失），改成 `BridgeState.status`（`@Volatile var`），并在 `updateStatus()` 里额外 `BridgeState.emit(text)` 推给 EventChannel。
6. `FileProvider.getUriForFile(ctx, ctx.getPackageName() + ".fileprovider", f)` → **`.files`**（dsh-Go 的 authority 是 `${applicationId}.files`，见 Manifest）。其 `<external-path name="storage" path="."/>` 已覆盖 `Downloads/DSH`，复用即可，不要再注册第二个 provider。
7. `startForeground(...)` 保持原样即可：dsh-Go `targetSdk = 28`（已核实），Android 14 的 FGS 类型强校验只在 `targetSdk>=34` 时生效；`FOREGROUND_SERVICE_CONNECTED_DEVICE` 在旧系统上是未知权限，被忽略，加上无害。
8. **保留中文状态串原文**（`未配置服务器` / `未登录，桥未连接` / `已连接手机桥` / `连接失败，稍后重试 (code)` / `连接已断开，重连中` / `前台服务被系统拒绝（…）`）——它们是排查时唯一的证据来源，也是 DSH Mobile 文档与截图里出现的字样。
9. `CAPS` 数组按 §2.3 调整。

**(b) `Settings.java`（92 行）→ `bridge/BridgeConfig.kt`（新写，Kotlin，~90 行）**

不要原样搬 `Settings`：它混了 Web 壳专用的 `last_url`、SAF 的 `files_root`，还是全局单例。新写一个小类，SharedPreferences 文件 `dsh_bridge`：

```
键                      类型      用途
endpoint                String   规范化后的 origin，如 https://dsh.example.com
allow_insecure          Boolean  允许 http / 自签证书（默认 false）
device_id               String   首次启动 UUID.randomUUID()，持久化；用作 hello.device.id
a11y_enabled            Boolean  桥的无障碍总开关（默认 false）
```

方法：`endpoint(): Endpoint?`、`setEndpoint(raw: String): Endpoint?`（内部走 `Endpoint.parse`）、`allowInsecure()`、`setDeviceId()` 惰性生成、`a11yEnabled()/setA11yEnabled()`、`clear()`。**不要**把 token 放这里（token 走 TokenStore）。

**(c) 无障碍服务与它的 xml**

`A11yService.java`（323 行）→ `bridge/BridgeA11yService.java`：改 `package`、类名（Manifest 里 `android:name` 要一致）、`TAG="DshBridgeA11y"`，`Settings.a11yEnabled()` → `BridgeConfig.a11yEnabled()`。业务代码（`onMain`、`tree`、`screenshot` 的多级 JPEG 压缩、`tap/swipe` 的 `dispatchGesture` 等待、`global`）**一行都不要动**——特别是这条注释里的坑：等待必须在**调用线程**上做，不能放进 `onMain`，否则冻结 UI → ANR → 拖死 bridge socket（历史上表现为“每次点击后手机掉线”）。

`res/xml/bridge_accessibility_service.xml` 直接复制 `a11y_service.xml` 的 30 行，只把 `android:description` / `android:summary` 指向新字符串（`@string/bridge_a11y_desc` / `@string/bridge_a11y_summary`）。

### 2.3 op → 能力对照表（决定 CAPS 与工作量）

bridge-server 的 `phones.js` 有 `KNOWN_OPS` 白名单（22 项），但**工具是否暴露取决于手机 hello 里的 `caps`**，所以手机少宣告就等于没实现，服务端不用改。

| op | v1 | 依赖的搬移文件 | 备注 |
|---|---|---|---|
| `ping` | ✔ | — | `{pong:true,at}` |
| `info` | ✔ | BridgeConfig | `{id,model,caps}` |
| `shares` | 可选 | Inbox | 不搬就从 CAPS 去掉 |
| `clipboard.get` / `clipboard.set` | ✔ | — | `ClipData.newPlainText("DSH", text)`，`set` 要回主线程 |
| `notify` | ✔ | — | 独立渠道 `dsh_agent_messages`，**待复核** dsh-Go `notify/NotificationGate.kt` 会不会丢弃非自己渠道的通知 |
| `open` | ✔ | — | `ACTION_VIEW` + `FLAG_ACTIVITY_NEW_TASK` |
| `files.save` | ✔ | Files | `data`/`url`/`path` 三选一；`url` 下载要带 `Cookie: dsh_gateway_token=` |
| `files.open` | ✔ | Files + FileProvider | authority 改 `.files` |
| `fs.roots` / `fs.list` / `fs.read` / `fs.write` / `fs.mkdir` | ✔ | FileBrowser | 5 个 op 共用一个类 |
| `apps.list` / `apps.launch` | ✔ | — | `queryIntentActivities` + `getLaunchIntentForPackage` |
| `a11y.status` | ✔ | BridgeA11yService | 只读；`{service,allowed,sdk}` |
| `a11y.tree` | P3 | BridgeA11yService | BFS 出 `{package,count,nodes[]}` |
| `a11y.screenshot` | P3 | BridgeA11yService | Android 11+；默认 600000 字节预算 |
| `a11y.tap` / `a11y.swipe` | P3 | BridgeA11yService | `dispatchGesture` |
| `a11y.global` | P3 | BridgeA11yService | back/home/recents/notifications/quick_settings/lock(API 28+) |

v1 的 `CAPS`（16 项；`shares` 见上表“可选”，搬了就等于 17 项）：

```
ping, info, clipboard.get, clipboard.set, notify, open,
files.save, files.open,
fs.roots, fs.list, fs.read, fs.write, fs.mkdir,
apps.list, apps.launch,
a11y.status
```

---

## 3. Gradle 与 Manifest 改动（逐条）

### 3.1 `app/android/app/build.gradle.kts`

在文件末尾 `dependencies { ... }` 里加一行（其余不动）：

```kotlin
dependencies {
    // ... 现有的 onnxruntime / mlkit / xz / shizuku / libadb / conscrypt / webkit

    // 手机桥: OkHttp WebSocket (dsh-mobile BridgeService 的唯一第三方依赖)
    implementation("com.squareup.okhttp3:okhttp:4.12.0") // Apache-2.0
}
```

JVM 单测已经满足：`testImplementation("org.json:json:20240303")` 与 `testImplementation("junit:junit:4.13.2")` 都在（已核实），所以 `EndpointTest`、`TokenStore.seal/open` 的测试可以照搬。OkHttp 4.12 要求 Kotlin stdlib ≥1.8、JDK 8+，与现有 `JVM_17` 目标兼容。

> 不需要 `java.srcDirs`、不需要 `packaging`、不需要新 flavor。

### 3.2 `app/android/app/src/main/AndroidManifest.xml`

**权限**（`<manifest>` 下，加 2 条；`INTERNET` / `ACCESS_NETWORK_STATE` / `FOREGROUND_SERVICE` / `POST_NOTIFICATIONS` **已存在**，不要重复加）：

```xml
<!-- 手机桥: connectedDevice 前台类型 (Android 14+ 需要设备连接类权限之一) -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<!-- 断网/切网时尽快触发 WebSocket 的 onFailure，从而走退避重连 -->
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
```

**服务**（`<application>` 下，挨着现有的 `DshService` / `PhoneA11yService` 放）：

```xml
<!-- 手机桥: 维持到 bridge-server 的 wss:// 连接，供远端 agent 调用 phone_* 工具 -->
<service
    android:name=".bridge.BridgeService"
    android:exported="false"
    android:foregroundServiceType="connectedDevice" />

<!-- 手机桥的无障碍自动化 (P3). 与 .phone.a11y.PhoneA11yService 是两个服务，标签要能区分 -->
<service
    android:name=".bridge.BridgeA11yService"
    android:label="@string/bridge_a11y_label"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"
    android:exported="true">
    <intent-filter>
        <action android:name="android.accessibilityservice.AccessibilityService" />
    </intent-filter>
    <meta-data
        android:name="android.accessibilityservice"
        android:resource="@xml/bridge_accessibility_service" />
</service>
```

**FileProvider**：**不加**新 provider。现有的是 `androidx.core.content.FileProvider` + `authorities="${applicationId}.files"` + `@xml/dsh_file_paths`（已核实），其 `<external-path name="storage" path="."/>` 能覆盖 `Downloads/DSH`、`Pictures/DSH` 等所有 `Files.save` 落盘位置。`BridgeService.files.open` 里把 authority 从 `.fileprovider` 改成 `.files` 即可。

**深链**（可选，接 `dshmobile://pair?v=1&e=...` 二维码）：在现有 `.links.LinkTrampolineActivity` 的第一个 `<intent-filter>` 里追加一条 `<data android:scheme="dshmobile" android:host="pair" />`，然后在 `app/lib/.../links/LinksPlugin.kt` 里把它交给桥的设置页（**待复核** `LinksPlugin.kt` 的分支写法）。dsh-Go 自己的 `dshgo://` 不受影响。

### 3.3 资源

| 文件 | 动作 |
|---|---|
| `res/drawable/ic_stat_dsh.xml` | **已存在**，直接复用（状态通知的小图标） |
| `res/values/bridge_strings.xml` | 新增：`bridge_label`(“DSH 手机桥”)、`bridge_a11y_label`(“DSH Go · 远程手机桥”)、`bridge_a11y_desc`、`bridge_a11y_summary`、`bridge_no_endpoint`、`bridge_no_credential`、`bridge_start_failed`、`bridge_store_error`。dsh-Go 把字符串按功能拆文件（`phone_a11y_strings.xml` 等），沿用这个习惯 |
| `res/values-zh/bridge_strings.xml` | 同上中文（dsh-Go 有 `values-zh`） |
| `res/xml/bridge_accessibility_service.xml` | 新增，复制 `a11y_service.xml`（`canPerformGestures` / `canRetrieveWindowContent` / `canTakeScreenshot` 全 true，`flags` 含 `flagRetrieveInteractiveWindows\|flagReportViewIds`，`notificationTimeout=100`） |

> 注意：`BridgeService` 的 `a11y.status` 分支要引用 `BridgeA11yService.ready()`，所以**服务类、服务条目、xml 在 S3 一起加**（三件事同一次提交），否则编译不过。加了不等于启用：CAPS 不宣告 5 个动作 op，用户不打开无障碍开关时 `a11y.status` 返回 `{service:false,allowed:false}`，其余 op 完全不受影响。

---

## 4. 桥配置与配对 token：存哪、用户怎么填

### 4.1 存哪

| 数据 | 位置 | 说明 |
|---|---|---|
| endpoint / allow_insecure / device_id / a11y_enabled | `SharedPreferences("dsh_bridge")`，见 `BridgeConfig.kt` | 非机密 |
| **token**（`dsh_gateway_token` 的值） | `TokenStore`：`SharedPreferences("dsh_bridge_creds")` + **AndroidKeyStore 里 AES-256-GCM 加密**，键 `token`/`host`/`saved_at` | 原 `CredentialStore` 照搬。`load(host)` 必须校验 `savedHost` 与当前 endpoint 的 host 一致才返回——这条是防止“换服务器带旧令牌”的核心，别删 |

token 的本质是 dsh-passwords 网关签发的 HttpOnly cookie，是 **bearer 凭证**：不要写日志、不要放进 `hello`/`info`、不要进备份（`android:allowBackup="false"` 已由 dsh-Go 设好）。

### 4.2 用户怎么填（三条路，按推荐顺序）

网关**没有** token 签发 / 设备码 API（ADR-0008 已确认），所以 App 只能“替用户登录一次，然后把 cookie 抄下来”。

**路线 A（推荐）：App 内 WebView 登录一次，自动取 cookie**

dsh-Go 已有 web island（`islands/IslandsPlugin.kt`、`androidx.webkit:webkit`）。流程：

1. 设置页里输/扫 origin（`https://dsh.example.com`）；
2. 点「登录并连接」→ 打开 island 指向 `<origin>/gateway/login?next=/`；
3. 用户在网关页输口令（dsh-passwords 写入 `dsh_gateway_token`，`Path=/`）；
4. 登录完成后读 `CookieManager.getInstance().getCookie(<origin>)`，抠出 `dsh_gateway_token=` 之后的值（dsh-mobile 的 `MainActivity.webToken()` 就是这么做的：HttpOnly 也能被 `CookieManager` 读到，这正是“从浏览器复制会话”可行的原因）；
5. `TokenStore.save(host, token)` → `BridgePlugin.start()`。

> **待复核**：island 的 cookie 是否落在应用级 `CookieManager`（Flutter 的 `webview_flutter` 默认是，Android 实现共享同一个 `CookieManager`）；若 islands 用了独立 profile，就在 `BridgePlugin` 里直接 `CookieManager.getInstance().getCookie(origin)` 读。

**路线 B（兜底）：粘贴 token**

设置页一个多行输入框 + `TokenStore.save`。文案必须写清来源：「在电脑浏览器打开 `https://<origin>/`，登录后 F12 → Application → Cookies → 复制 `dsh_gateway_token` 的值」。这条路径丑陋但可靠，也是排查“是 token 问题还是网络问题”的最快手段。

**路线 C（可选）：扫配对二维码**

服务器侧 `plugins/mobile-ux` 的 `GET /pwa/pair` 会渲染 `dshmobile://pair?v=1&e=<percent-encoded origin>[&i=1]`（ADR-0008）。dsh-Go 的 `app/lib/ui/remote/pairing_page.dart` 已用 `mobile_scanner`（Manifest 注释已核实）。接法：把 `PairLink.java`（143 行，纯 JDK + JVM 单测）一起搬进 `bridge/`，扫码 → `PairLink.parseScan(raw)` → 若是裸 URL 也接受 → 写 `BridgeConfig.setEndpoint` → 走路线 A。`i=1`（明文 http）**必须**仍然受 `allow_insecure` 开关约束，深链不能单独放宽 TLS 策略。

三条路的共同点：**先写 endpoint，再拿 token；换 origin 一定先 `TokenStore.clear()`**（token 按 host 存，绝不跟着链接走）。

### 4.3 UI 放哪

- 新页面 `app/lib/ui/phone/remote_bridge_page.dart`（Dart），入口加在 `app/lib/ui/phone/phone_control_screen.dart` 的“手机操控”里一条「远程手机桥」。
- 页面内容：origin 输入 + 「登录并连接」（路线 A）/「粘贴令牌」（路线 B）/ 扫码。状态区显示 `BridgeState.status` 原文（未配置服务器 / 未登录，桥未连接 / 已连接手机桥 / 连接失败，稍后重试 (code)）+ 开关 + 「打开无障碍设置」（§6）。
- 不新建设置页体系，避免和 dsh-Go 现有设置导航打架（**待复核** `app/lib/ui/settings*` 的实际结构）。

---

## 5. 启动链路与 MethodChannel

### 5.1 原生侧：`bridge/BridgePlugin.kt`（新写，~160 行）

照 `phone/PhonePlugin.kt` 的样子写（`FlutterPlugin` + `MethodChannel` + `EventChannel`）：

```kotlin
class BridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object { const val METHOD = "dsh/bridge"; const val EVENTS = "dsh/bridge/events" }
    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(b.binaryMessenger, METHOD).also { it.setMethodCallHandler(this) }
        events = EventChannel(b.binaryMessenger, EVENTS).also { it.setStreamHandler(this) }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = when (call.method) {
        "status"     -> result.success(BridgeState.snapshot(context))       // 含 configured/hasToken/running/status/error
        "setOrigin"  -> result.success(BridgeConfig.get(context).setEndpoint(call.argument<String>("origin")!!) != null)
        "login"      -> openGatewayLogin(call.argument<String>("origin")!!, result) // 路线 A
        "setToken"   -> { TokenStore(context).save(host, call.argument<String>("token")!!); start(context); result.success(true) }
        "clearToken" -> { TokenStore(context).clear(); stop(context); result.success(true) }
        "start"      -> { start(context); result.success(true) }
        "stop"       -> { stop(context); result.success(true) }
        "probe"      -> probeHealthz(result)   // HTTP GET <origin>/bridge/healthz? 见 §8 注
        else -> result.notImplemented()
    }
}
```

`start()` 必须走 `ContextCompat.startForegroundService(intent.setAction(BridgeService.ACTION_START))`；`stop()` 用普通 `startService(ACTION_STOP)`（和 dsh-mobile 一致）。

**Android 12+ 的后台限制**：`startForegroundService` 从后台调用会抛 `ForegroundServiceStartNotAllowedException`。所以：

- **不要**在 `Application.onCreate` 或 `BOOT_COMPLETED` 里拉起桥；
- 只在**用户在前台操作时**（设置页点保存/连接、或 App 冷启动后 Flutter 首帧回调 `start`）拉起；
- `onStartCommand` 返回 `START_STICKY` 让系统在进程被杀后自己拉起（这是合法路径，不受上面限制）。

### 5.2 Dart 侧

| 文件 | 内容 |
|---|---|
| `app/lib/bridge/bridge_channel.dart` | 薄封装 `MethodChannel('dsh/bridge')` + `EventChannel('dsh/bridge/events')`，写法照 `app/lib/phone/phone_channel.dart` 里的 `_bool` / `_result` / `MissingPluginException` 兜底 |
| `app/lib/state/bridge_state.dart` | 一个 `ChangeNotifier`/riverpod provider：`configured` / `hasToken` / `connected` / `statusText` / `lastError`，监听 events |
| `app/lib/ui/phone/remote_bridge_page.dart` | §4.3 |

**要不要 MethodChannel**：要。理由是“状态可见 + 可开关”这两件事 Dart 必须知道（dsh-mobile 是通过 WebView 里的 `DshMobile.bridgeStatus()` 拿到的，Flutter 里没有等价物）。但**不要**把 WebSocket、重连、心跳搬到 Dart——`FlutterEngine` 与 Activity 生命周期解耦（dsh-Go 用 `FlutterEngineCache` 单引擎、`shouldDestroyEngineWithHost()=false`，已核实），原生服务更抗后台。

### 5.3 注册

`app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/MainActivity.kt` 的 `provideFlutterEngine()` 里，和现有 20 多个 plugin 一起：

```kotlin
engine.plugins.add(io.github.ccch1mneyyy.dsh_app.bridge.BridgePlugin())
```

（位置：`engine.plugins.add(PhonePlugin())` 附近，已核实该函数的写法。）

---

## 6. a11y 的开启引导与三条技术路线

### 6.1 系统层面（必须用户手动开）

无障碍服务不能代码打开，只能：`Settings.ACTION_ACCESSIBILITY_SETTINGS` 跳转 + 文案教用户选哪一个。**直接复用 dsh-Go 现成能力**：

- `PhonePlugin` 已有 `"openAccessibilitySettings"` 方法（`app/android/.../phone/PhonePlugin.kt:288`，内部 `startActivity(control.accessibilitySettingsIntent())`），Dart 侧 `phone_channel.dart` 已封装成 `openAccessibilitySettings()`。桥的设置页直接调它，**不要**再写一个 Intent。
- Android 13+ 侧载 APK 会命中「受限设置」（Restricted Settings），无障碍开关被灰掉。dsh-Go 有 `phone/RestrictedSettings.kt` + `app/lib/ui/phone/restricted_settings_guide.dart`，桥的引导页复用这个组件。
- 文案里要写服务名：v1 只有 `DSH Go · 手机操控`（现有 `PhoneA11yService`）；P3 后会多一个 `DSH Go · 远程手机桥`。**两个都必须开**，这点要写在页面上，否则用户开了一个、另一个不工作。

### 6.2 三条路线

| 路线 | 做法 | 代价 | 何时选 |
|---|---|---|---|
| **A. 直搬第二个无障碍服务**（推荐先走） | `bridge/BridgeA11yService.java` = 原 `A11yService.java` 323 行 + 新 xml + 服务条目 | 用户在无障碍列表里看到两个 DSH Go 条目；两个服务都会收到窗口事件（Android 支持多服务并存，不报错） | P3 要最快跑通 `a11y.tree/screenshot/tap` 时 |
| **B. 适配到 dsh-Go 现有 a11y**（最终形态） | 在 `bridge/` 里写一个薄适配器，调 `phone/a11y/` 的既有实现：树 → `UiTree`/`TreeCapture`、截图 → `ScreenShooter`、点滑 → `CoordinateDispatch`/`Actuator`、返回/主页 → `SystemActions` | 省掉一个无障碍服务，事件只收一份；但要读懂约 45 个 Kotlin 文件的 API，且 dsh-Go 的截图有 128KB/800px 预览上限（`phone_channel.dart` 的 `PhonePreviewFrame` 校验），bridge 侧默认预算是 600000 字节，需要另一条全尺寸出口 | P5 打磨，或发现双服务互相干扰时 |
| **C. v1 不做** | CAPS 里只留 `a11y.status` | 远端 agent 不能自动点屏幕，但文件/剪贴板/通知/打开 App 全部可用 | 想先把“桥”这条链路的运维风险跑干净 |

推荐节奏：**P3 走 A，P5 评估 B**。A 的唯一硬要求是“改类名 + 改 xml + 改 Manifest”，业务代码零改动，风险最低；B 是重构，不该和首次联调混在一起。

### 6.3 双服务的两个坑

1. **状态栏/悬浮窗归属**：dsh-Go 的 `PhoneA11yService` 会接管状态栏与确认浮层（`ControlOverlay`/`StatusOwnership`）。搬来的服务只做“读树 + 派发手势”，**不要**让它加浮层，否则两块 UI 抢同一区域。
2. **屏幕关闭语义**：dsh-Go 在熄屏时 `stopAll("屏幕关闭了")`；搬来的服务没有这个逻辑，桥侧要自己决定：`a11y.*` 调用前检查 `PowerManager.isInteractive`，熄屏直接回 `{ok:false,error:"screen is off"}`，别让远端 agent 对着黑屏点。

---

## 7. 风险与坑

### 7.1 明文 HTTP 会被 dsh-Go 的网络配置拦掉（**最容易被忽略**）

`app/android/app/src/main/res/xml/network_security_config.xml`（已核实全文）只允许 `127.0.0.1` / `localhost` 明文，其余一律 HTTPS。dsh-mobile 是 `usesCleartextTraffic="true"`，能连 `http://192.168.1.10:3081`。

后果：用户填局域网 http 地址 → `Endpoint.parse` 通过（它允许 http）→ OkHttp 握手抛 `java.io.IOException: Cleartext HTTP traffic to … not permitted` → `onFailure` 只显示“连接失败，稍后重试”，根因看不出来。

对策（三选一，写进设置页文案）：

1. **v1 只支持 https origin**（最省事），`allow_insecure` 只在 endpoint 是 `http://127.0.0.1` 时可用；
2. 给 debug 构建放一份 `app/android/app/src/debug/res/xml/network_security_config.xml`，`<base-config cleartextTrafficPermitted="true">`，开发期用局域网地址联调；
3. 用户自签证书场景：`allow_insecure` 打开时给 OkHttp 装一个只信任用户证书的 `X509TrustManager` + `HostnameVerifier`（**这是安全决策，需用户确认**，ADR 里没定，别默默实现）。

并且在 `BridgeService.connect()` 之前做一次**前置校验**：`endpoint.base.startsWith("http://")` 且 host 不是 loopback → 直接 `updateStatus("明文 HTTP 地址被系统网络策略拦截（需要 https 或 debug 构建）")` 并 `stopSelf()`，不要等 OkHttp 抛一个天书。

### 7.2 1 MiB 的帧上限 vs 32 MiB 的 `files.save`

bridge-server `maxMessageBytes = 1048576`（已核实 config.js）。dsh-mobile 的 `BridgeService.MAX_BYTES = 32*1024*1024` 只在**手机侧**限制 `data`/`url`/`path`，但一条 `{t:"call"}` 消息超过 1 MiB 会被 bridge 直接断开。base64 膨胀 4/3 → **实际能走 `data` 的原始文件上限约 750 KiB**。

对策：`files.save` 只用 `data` 传小图；大文件走 `url`（服务器 `/bridge/download/<file>` 或任意可访问 URL）+ 手机带 cookie 下载。这条要写进 bridge-server 的 README 和工具的 description。

### 7.3 认证相关的失败模式（排查顺序）

| 现象 | 根因 | 查什么 |
|---|---|---|
| `phones: 0`，日志无 `phone connected` | 没连上：DNS/端口/Caddy 路由错 | 手机 `adb logcat -s DshBridge`；服务器 `journalctl -u dsh-mobile-bridge.service` |
| 日志有 `401 Unauthorized` | token 失效（网关重启/过期），bridge 的 `session-expired` | 重走 §4.2 登录；`curl -H 'Cookie: dsh_gateway_token=…' -o /dev/null -w '%{http_code}' http://127.0.0.1:3081/` 应为 200 |
| 日志有 `403` | `PUBLIC_ORIGIN` 与手机发的 `Origin: <endpoint.base>` 不相等 | 两端 origin 必须逐字相同（scheme+host+port，无尾斜杠） |
| 连上但立刻掉，反复 `replaced` | 同一个 `device.id` 有两台/两个进程在连，bridge 会 detach 旧的 | 检查 `device_id` 是否被复制（备份/多用户），换 UUID |

### 7.4 其它

- **双前台服务常驻通知**：dsh-Go 已有 `DshService`（本地内核，`specialUse`）+ 本桥（`connectedDevice`）。两个常驻通知会让用户以为是 bug。要么在设置里给“只在需要时开桥”的开关（默认关），要么把桥并入 `DshService` 的通知组（后者要改 dsh-Go 的通知策略，不建议 v1 做）。
- **ROM 杀后台**：小米/OPPO 会杀前台服务之外的连接。dsh-Go 已有“无限制/自启动”引导体系（`phone_background_guide.dart`、`PrivilegedKeepJob`），桥的页面复用，不要另写一套。验收必须包含“锁屏 10 分钟后 `phones` 仍为 1”。
- **两个控制面同时驱动手机**：本机 rootfs 的 agent 和远端 agent 都可能点屏幕。v1 不做 a11y 时不存在此问题；P3 起要在 UI 上明说“远端操控时别同时让本机 agent 操作手机”。
- **`org.json`**：Android 框架自带；JVM 单测靠 `testImplementation("org.json:json:20240303")`（已有）。别把 `org.json` 加进 `implementation`。
- **`device_id` 与 rootfs 身份的区分**：bridge-server 里同一 `id` 重连会顶掉旧连接。`BridgeConfig.device_id` 是独立 UUID，不要复用 dsh-Go 已有的任何设备标识。

---

## 8. 验证方法（四层，逐层过）

### L1 本机（不需要手机）

```sh
cd /root/workspace/dsh-pocket/app/android
./gradlew :app:testArm64DebugUnitTest --tests 'io.github.ccch1mneyyy.dsh_app.bridge.*'
```

应覆盖：`EndpointTest`（`javascript:` 拒绝、`[ipv6]:port`、`bridgeUrl()` 的 `http→ws`）、`TokenStore.seal/open`（往返 + 截断报错）、`PairLinkTest`（v=1、`i=1`、裸 origin）。这几个测试从 dsh-mobile 直接搬，**先让它们在 dsh-Go 里通过再动服务**。

### L2 服务端（桥没连上也能测）

```sh
curl -s http://127.0.0.1:3082/healthz | jq '{ok,phones}'      # 期望 {"ok":true,"phones":N}
systemctl status dsh-mobile-bridge.service --no-pager
journalctl -u dsh-mobile-bridge.service -n 50 --no-pager | grep -E 'phone connected|401|403|replaced'
```

`phones` 的语义是 `phones.list().length`，即**已 attach（完成 hello）的连接数**，不是“认证过的设备数”。所以 `phones:1` 就等于“握手 + hello 都成功”。

回归（不需要真机）：`cd /root/workspace/dsh-mobile/packages/bridge-server && node tools/smoke.mjs`（29 项断言）、`node tools/fake-phone.mjs`（假手机）。

### L3 真机（只看桥本身）

```sh
adb install -r app-arm64-debug.apk
adb logcat -c && adb logcat -s DshBridge:V
# 设置页填 origin → 登录 → 点连接，然后：
adb shell dumpsys activity services io.github.ccch1mneyyy.dsh_app | grep -A2 BridgeService
adb shell dumpsys notification --noredact | grep -i "DSH 手机桥"
```

要看的三件事：`BridgeService` 是 `isForeground=true`；通知标题是「DSH 手机桥」、内容从“未配置服务器”→“已连接手机桥”；`logcat` 里出现 `onOpen` 之后没有 `onFailure`。

最小验证顺序（任一环失败就停，别往下走）：**配置 origin 能保存 → token 能存/能读回（重进 App 还在）→ 服务能启动并能 stop → 连上后服务端 `phones:1` → kill -9 后 60 秒内自动重连**。

### L4 端到端（远端 agent 真的能操作手机）

在服务器上通过 MCP 调工具（工具名 `mcp__<serverName>__phone_call`，通用直通口）：

```jsonc
{"op":"ping"}                              // {pong:true,at:...}
{"op":"info"}                              // caps 里应看到 16 项（含 shares 则 17）
{"op":"clipboard.set","args":{"text":"hello"}}
{"op":"files.save","args":{"name":"a.txt","data":"aGVsbG8=","dest":"downloads"}}
{"op":"fs.list","args":{}}
{"op":"apps.list"}                         // 应有 20+ 条
{"op":"a11y.status"}                       // P3 前: {service:false,allowed:false}
```

P3 后追加：`a11y.tree`（前台是设置页时应 >10 个节点）→ `a11y.screenshot`（返回 base64，解开是 JPEG）→ `a11y.tap`（点到自己能看见的变化，比如打开开关）→ `a11y.global back`。

失败时的定位顺序：`journalctl` 里有没有 `call <id> op <name>` → 手机 `logcat` 里有没有 `DshBridge` 的异常 → 用 `phone_call` 直接重发同一个 op，看 `error` 字符串（`requireA11y()` / `no such file on this phone` / `payload too large` 都是原样字符串，能直接对应到源码分支）。

---

## 9. 工作量分级与实施顺序

| 阶段 | 内容 | 规模 | 依赖 | 验收 |
|---|---|---|---|---|
| **S0 脚手架** | 建 `bridge/` 包、`src/main/java` 目录、gradle 加 okhttp、Manifest 加 2 条权限 + 1 个 service、`bridge_strings.xml` | **S**（半天） | — | `./gradlew :app:assembleArm64Debug` 仍能过 |
| **S1 纯逻辑类** | `Endpoint`、`TokenStore`、`PairLink` + 三个 JVM 单测 | **S** | S0 | L1 全绿 |
| **S2 文件能力** | `Files`、`FileBrowser`（先不搬 SAF tree 那扇门） | **M**（`FileBrowser` 677 行要读懂 `tree`/`downloads` 两个门，建议先只留 `downloads`） | S0 | 单测 + 手动过 `Files.save` 到 `Downloads/DSH` |
| **S3 桥服务** | `BridgeService`（16 op）+ `BridgeState` + `BridgeA11yService` 只留 `status` | **M**（749 行，但 90% 是协议代码，改动集中在 9 处，见 §2.2(a)） | S1,S2 | L2 + L3 的 1–4 环 |
| **S4 通道** | `BridgePlugin.kt`、`bridge_channel.dart`、`bridge_state.dart`、`remote_bridge_page.dart`、`MainActivity` 注册 | **M** | S3 | 设置页能存、能连、能看到状态原文、能停 |
| **S5 登录** | 路线 A（WebView 取 cookie）+ 路线 B（粘贴），换 origin 清旧 token | **M**（路线 A 要摸清 islands 的 cookie 域，**待复核**） | S4 | 重装 App 后一次登录即可连上；换 origin 后旧 token 被清 |
| **S6 无障碍** | 路线 A：`BridgeA11yService` 全量 + xml + 引导页复用 `openAccessibilitySettings` + 熄屏短路 | **L**（323 行代码，但调试成本高：必须真机、每次改都要重开无障碍；再叠加 §6.3 的双服务语义） | S3 | `a11y.status.service=true`；`a11y.tree/tap` 端到端可用 |
| **S7 打磨** | 扫码（路线 C）、超时/错误文案、锁屏 10 分钟存活、AGPL/NOTICE | **M** | S5/S6 | 见 §8 全绿 |

**最大的一块是 S6（无障碍）**——不是代码量，而是“必须真机 + 用户手动开系统开关 + 两个无障碍服务共存语义”的调试成本。其次是 S3+S2 的阅读量（约 1400 行要逐行对）。

**建议顺序**：S0 → S1 → S3（先把桥连通，用 `ping`/`info` 验证全链路）→ S2 → S4 → S5 → S6 → S7。先打通一条最窄的竖线（origin+token+ping），比先搬文件能力更快暴露“网络策略 / Origin / 令牌”这三个致命问题。

与 `merge-architecture.md` 的对应：本文 S0–S4 ≈ 其 P2，S5 ≈ P2 的设置页部分，S6 ≈ P3，S7 ≈ P4/P5。

---

## 附录 A：待源码完整 checkout 后逐条复核的清单

本方案写作时 `app/` 目录尚未 checkout（sparse clone，1% 文件），下列结论是从 GitHub raw 读到的单个文件确认的；**标 ⚠ 的必须复核**：

| # | 待确认 | 为什么重要 |
|---|---|---|
| 1 | ⚠ `phone/PhonePlugin.kt` 的 `startActivity(control.accessibilitySettingsIntent())` 在 bridge 页面调用时需要 Activity 附着（`ActivityAware`），而桥的页面是普通 Dart 页面 | 可能必须从 `dsh/phone` 的既有入口跳转，而不是直接调 |
| 2 | ⚠ `islands/IslandsPlugin.kt` 的 WebView 是否与应用共享 `CookieManager`（`CookieManager.setAcceptCookie` / 独立 profile） | 决定 §4.2 路线 A 能否“登录完自动拿 cookie” |
| 3 | ⚠ `notify/NotificationGate.kt` 会不会丢弃非自己渠道/非自己发起的通知 | 决定 `notify` op 是否需要绕过 gate |
| 4 | ⚠ `links/LinksPlugin.kt` 的 intent → 分支写法 | 决定 `dshmobile://pair` 深链怎么接（§3.2 最后一条） |
| 5 | ⚠ `app/lib/ui/settings*` 的实际导航结构 | 决定 `remote_bridge_page.dart` 的入口挂哪 |
| 6 | ⚠ `phone/a11y/{UiTree,TreeCapture,ScreenShooter,CoordinateDispatch,Actuator,SystemActions}.kt` 的 public API | 决定路线 B（适配器）可行性；影响 S6 规模 |
| 7 | ⚠ `dsh-Go` 是否已有设备标识（避免和 `BridgeConfig.device_id` 混淆） | 影响 §7.3 的 `replaced` 排查 |
| 8 | `app/android/app/proguard-rules.pro` 是否需要 OkHttp / `org.json` 的 keep 规则 | release 构建被混淆后 WebSocket 回调类名反射不到 |

## 附录 B：事实来源（可对照）

- dsh-mobile 源：`/root/workspace/dsh-mobile/packages/mobile-shell/android/app/src/main/java/top/frankfurtlin/dshmobile/{BridgeService,A11yService,Endpoint,CredentialStore,Settings,Files,FileBrowser,Inbox,PairLink,MainActivity}.java`；`.../app/src/main/res/xml/a11y_service.xml`；`.../app/build.gradle`；`.../app/src/main/AndroidManifest.xml`
- bridge-server：`/root/workspace/dsh-mobile/packages/bridge-server/src/{config,session,phones,http}.js`（`/healthz` 形状、1 MiB 上限、heartbeat 25s、`Origin` 校验、token 校验链）
- ADR：`/root/workspace/dsh-mobile/docs/adr/0003-agent-phone-bridge.md`（为何独立 bridge + MCP）、`0008-pairing-deep-link.md`（为何不能扫码即登录）
- dsh-Go：`app/android/app/build.gradle.kts`（targetSdk 28、无 okhttp、已有 org.json 测试依赖）、`app/android/app/src/main/AndroidManifest.xml`（FileProvider 权威 `.files`、`PhoneA11yService`、`DshService`）、`app/android/app/src/main/res/xml/{network_security_config,dsh_file_paths}.xml`、`app/android/app/src/main/kotlin/…/MainActivity.kt`（`provideFlutterEngine` 注册处）、`phone/PhonePlugin.kt`（`dsh/phone` 通道、`openAccessibilitySettings`）、`phone/McpServer.kt` + `phone/PhoneBridge.kt`（本机 MCP 通道，与本次移植互不影响）

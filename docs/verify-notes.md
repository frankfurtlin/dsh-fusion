# 源码核实笔记（附录 A 逐条，2026-11-20）

用 gh-proxy raw（`https://gh-proxy.com/https://raw.githubusercontent.com/ccch1mneyyy/dsh-Go/046b0c6/...`，单文件 1–3 秒）直接读原文，不等全量 checkout。

## 已闭合

| # | 结论 | 证据 |
|---|---|---|
| 1 | **无障碍设置入口不需要 Activity**。`PhonePlugin.startActivity` 有兜底：`if (host != null) host.startActivity(intent) else appContext.startActivity(intent.addFlags(FLAG_ACTIVITY_NEW_TASK))`，异常返回 false。桥页面直接走 `dsh/phone` 的 `openAccessibilitySettings` 即可 | `phone/PhonePlugin.kt:180-188`、`:288` |
| 2 | **island 的 WebView 来自 webview_flutter 的共享实例**（`WebViewFlutterAndroidExternalApi.getWebView(binding, id)`），没有独立 profile / 没有 `setAcceptThirdPartyCookies(false)` → 全局 `CookieManager` 里能读到登录后的 `dsh_gateway_token`，§4.2 路线 A 成立 | `islands/IslandsPlugin.kt:52` |
| 3 | **深链 scheme 是 `dshgo`，不是 `dshmobile`**（`LinksPlugin.SCHEME = "dshgo"`）。`ACTION_VIEW` 分支：`dshgo`/`https`/`http` → 交给 Dart；`content`/`file` → 复制进 cache/links 再交。**要支持 `dshmobile://pair` 必须自己加分支**，或者干脆复用 `dshgo://pair`（少改一处） | `links/LinksPlugin.kt:95-108`、`:173` |
| 6 | **a11y 六个实现类都是 `internal`**（`internal class Actuator`、`internal object TreeCapture`、`internal class ScreenShooter`、`internal class CoordinateDispatch`、`internal object InjectGuard`）→ 只有同 Kotlin module 能调，正好我们的桥就加在 `app` module 内；但**不能跨 module 复用**，路线 B 的代价比文档估的低（无需改可见性） | `phone/a11y/{Actuator,TreeCapture,ScreenShooter,CoordinateDispatch}.kt` |
| 8 | `proguard-rules.pro` 已存在（1445 字节），仍待确认是否含 WebSocket/org.json keep | `app/android/app/proguard-rules.pro` |

## 其它核实
- 插件注册全部集中在 `MainActivity.provideFlutterEngine()`（`MainActivity.kt:44-71`，已注册 20+ 个 `engine.plugins.add(...)`）→ 桥插件加一行即可，位置明确。
- Manifest 已有 `runtime.DshService`、`phone.a11y.PhoneA11yService`、`pet.PetOverlayService` 三个 service，加桥 service 时注意**前台服务类型声明**与 targetSdk。
- `dshgo` scheme 的 intent-filter 已在 Manifest（`LinksPlugin` 注释说冷启动走 launch intent，热启动走 `onNewIntent`）。

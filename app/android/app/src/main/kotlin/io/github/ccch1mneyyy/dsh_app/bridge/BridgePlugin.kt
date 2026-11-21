package io.github.ccch1mneyyy.dsh_app.bridge

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * Agent/phone bridge, Flutter side of the wiring: MethodChannel `dsh/bridge` + EventChannel
 * `dsh/bridge/events` (Dart: lib/bridge/bridge_channel.dart).
 *
 * This plugin owns no protocol itself. [BridgeService] keeps the WebSocket to the public bridge
 * origin, and the config/token it needs already live in [Settings] / [CredentialStore] (the same
 * places the old WebView shell kept them), so everything here is a thin translation layer:
 *
 *  - `config`  read what the service would use right now + the live status string
 *  - `saveConfig` / `setToken` / `clearToken`  write it
 *  - `start` / `stop`  walk the foreground service up and down
 *  - `openAccessibility`  forward to the existing `dsh/phone` entry so there is one guide, not two
 *
 * Status is pushed, not polled from Dart: [BridgeService.status] is a volatile field, so a
 * 1 s main-thread ticker watches it while a listener is attached and emits only on change.
 */
class BridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var context: Context
    private lateinit var messenger: BinaryMessenger

    private var handler: Handler? = null
    private var sink: EventChannel.EventSink? = null
    private var lastStatus: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        messenger = binding.binaryMessenger
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, EVENTS).also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        stopTicker()
    }

    // EventChannel -----------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        lastStatus = null
        emit()
        startTicker()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stopTicker()
    }

    private fun startTicker() {
        if (handler != null) return
        val h = Handler(Looper.getMainLooper())
        handler = h
        h.post(object : Runnable {
            override fun run() {
                if (sink == null) return
                emit()
                h.postDelayed(this, TICK_MS)
            }
        })
    }

    private fun stopTicker() {
        handler?.removeCallbacksAndMessages(null)
        handler = null
    }

    private fun emit() {
        val s = sink ?: return
        val status = BridgeService.status
        if (status == lastStatus) return
        lastStatus = status
        s.success(mapOf("status" to status, "running" to running(), "connected" to connected(status)))
    }

    // MethodChannel ----------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val settings = Settings(context)
        val store = CredentialStore(context)
        when (call.method) {
            "config" -> result.success(config(settings, store))
            "saveConfig" -> {
                val origin = (call.argument<String>("origin") ?: "").trim()
                val endpoint = Endpoint.parse(origin)
                if (endpoint == null) {
                    result.error("bad_origin", "origin is not a URL: $origin", null)
                    return
                }
                // Token is bound to the host it was minted for; a new origin must not inherit it.
                val previous = settings.endpoint?.host
                if (previous != null && previous != endpoint.host) store.clear()
                settings.setEndpoint(endpoint.base)
                settings.deviceName = (call.argument<String>("deviceName") ?: "").trim().ifBlank { defaultDeviceName() }
                result.success(config(settings, store))
            }
            "setToken" -> {
                val token = (call.argument<String>("token") ?: "").trim()
                val host = settings.endpoint?.host
                if (host == null) {
                    result.error("no_origin", "save an origin before pasting a token", null)
                    return
                }
                if (token.isEmpty()) {
                    result.error("bad_token", "token is empty", null)
                    return
                }
                store.save(host, token)
                result.success(config(settings, store))
            }
            "clearToken" -> {
                store.clear()
                result.success(config(settings, store))
            }
            "start" -> {
                val ep = settings.endpoint
                if (ep == null) {
                    result.error("no_origin", "save an origin first", null)
                    return
                }
                if (store.load(ep.host) == null) {
                    result.error("no_token", "paste the gateway token first", null)
                    return
                }
                val intent = Intent(context, BridgeService::class.java).setAction(BridgeService.ACTION_START)
                context.startService(intent)
                result.success(true)
            }
            "stop" -> {
                context.startService(Intent(context, BridgeService::class.java).setAction(BridgeService.ACTION_STOP))
                result.success(true)
            }
            "gatewayLogin" -> {
                // Signs in to dsh-passwords the way its own HTML form does: fetch the page for the
                // CSRF cookie, then POST it back with the credentials. The gateway answers with
                // `dsh_gateway_token`, which is exactly what the bridge WebSocket presents.
                val origin = (call.argument<String>("origin") ?: "").trim().trimEnd('/')
                val username = (call.argument<String>("username") ?: "").trim()
                val password = call.argument<String>("password") ?: ""
                val resultChannel = result
                if (origin.isEmpty() || username.isEmpty() || password.isEmpty()) {
                    result.error("bad_credentials", "origin, username and password are required", null)
                    return
                }
                Thread {
                    val outcome = runCatching { signIn(origin, username, password) }
                    Handler(Looper.getMainLooper()).post {
                        val token = outcome.getOrNull()
                        if (token.isNullOrEmpty()) {
                            val why = outcome.exceptionOrNull()?.message ?: "sign-in refused"
                            resultChannel.error("login_failed", why, null)
                        } else {
                            val host = Endpoint.parse(origin)?.host
                            if (host == null) {
                                resultChannel.error("bad_origin", "origin is not a URL", null)
                            } else {
                                CredentialStore(context).save(host, token)
                                resultChannel.success(config(Settings(context), CredentialStore(context)))
                            }
                        }
                    }
                }.start()
            }
            "gatewayCookie" -> {
                // The dsh-passwords gateway sets dsh_gateway_token as an HttpOnly cookie on the
                // app's own WebView store, so after the user logs in through 网页模式 the value is
                // reachable here without asking them to copy it out of a desktop browser.
                val origin = (call.argument<String>("origin") ?: "").trim()
                if (origin.isEmpty()) {
                    result.error("bad_origin", "origin is empty", null)
                    return
                }
                val cookies = android.webkit.CookieManager.getInstance().getCookie(origin)
                val token = cookies
                    ?.split(';')
                    ?.map { it.trim() }
                    ?.firstOrNull { it.startsWith("$GATEWAY_COOKIE=") }
                    ?.substringAfter('=')
                    ?.trim()
                result.success(token?.takeIf { it.isNotEmpty() })
            }
            "a11yEnabled" -> result.success(settings.a11yEnabled())
            "setA11yEnabled" -> {
                val on = call.argument<Boolean>("enabled") ?: false
                settings.setA11yEnabled(on)
                result.success(on)
            }
            "openAccessibility" -> {
                // Reuse the one guide the phone-control settings page already uses.
                MethodChannel(messenger, "dsh/phone")
                    .invokeMethod("openAccessibilitySettings", null, object : MethodChannel.Result {
                        override fun success(r: Any?) = result.success(r == true)
                        override fun error(code: String, msg: String?, details: Any?) = result.error(code, msg, details)
                        override fun notImplemented() = result.success(false)
                    })
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Fetches the gateway login page, posts the credentials with the CSRF pair, and returns the
     * `dsh_gateway_token` the gateway minted. Throws when the credentials are refused.
     */
    private fun signIn(origin: String, username: String, password: String): String {
        val client = OkHttpClient.Builder()
            .followRedirects(false)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .build()
        val loginUrl = "$origin/gateway/login?next=/"
        val page = client.newCall(Request.Builder().url(loginUrl).get().build()).execute()
        val html = page.body?.string().orEmpty()
        val csrf = Regex("""name="csrf"\s+value="([^"]+)"""").find(html)?.groupValues?.getOrNull(1)
            ?: throw IllegalStateException("the gateway login page carried no csrf field")
        val csrfCookie = page.headers("Set-Cookie")
            .mapNotNull { header ->
                header.substringBefore(';').takeIf { it.startsWith("$CSRF_COOKIE=") }
            }
            .firstOrNull()
            ?: throw IllegalStateException("the gateway login page set no $CSRF_COOKIE cookie")
        page.close()

        val body = FormBody.Builder()
            .add("csrf", csrf)
            .add("next", "/")
            .add("username", username)
            .add("password", password)
            .build()
        val post = Request.Builder()
            .url("$origin/gateway/login")
            .post(body)
            .header("Origin", origin)
            .header("Referer", loginUrl)
            .header("Cookie", csrfCookie)
            .build()
        client.newCall(post).execute().use { response ->
            val minted = response.headers("Set-Cookie")
                .mapNotNull { header ->
                    header.substringBefore(';').takeIf { it.startsWith("$GATEWAY_COOKIE=") }
                }
                .firstOrNull()
                ?.substringAfter('=')
            if (!minted.isNullOrEmpty()) return minted
            throw IllegalStateException(
                if (response.code == 401 || response.code == 403) "the gateway rejected these credentials"
                else "the gateway answered HTTP ${response.code} and set no $GATEWAY_COOKIE"
            )
        }
    }

    // Helpers ----------------------------------------------------------------

    private fun config(settings: Settings, store: CredentialStore): Map<String, Any?> {
        val ep = settings.endpoint
        val token = ep?.let { runCatching { store.load(it.host) }.getOrNull() }
        val status = BridgeService.status
        return mapOf(
            "origin" to ep?.base,
            "deviceName" to settings.deviceName.ifBlank { defaultDeviceName() },
            "running" to running(),
            "connected" to connected(status),
            "status" to status,
            "tokenPresent" to !token.isNullOrBlank(),
            "caps" to BridgeService.caps().toList(),
        )
    }

    /** True while [BridgeService] is between ACTION_START and ACTION_STOP/onDestroy. */
    private fun running(): Boolean = BridgeService.alive

    private fun connected(status: String): Boolean = status == BridgeService.STATUS_OPEN

    companion object {
        const val CHANNEL = "dsh/bridge"

        /** Cookie the dsh-passwords gateway issues for a logged-in browser session. */
        const val GATEWAY_COOKIE = "dsh_gateway_token"

        /** Double-submit CSRF cookie the gateway login form pairs with its hidden field. */
        const val CSRF_COOKIE = "dsh_csrf"
        const val EVENTS = "dsh/bridge/events"
        private const val TICK_MS = 1000L

        /** Default device label when the user leaves the field empty. */
        fun defaultDeviceName(): String =
            listOf(Build.MANUFACTURER, Build.MODEL)
                .filter { it.isNotBlank() }
                .joinToString(" ")
                .trim()
    }
}

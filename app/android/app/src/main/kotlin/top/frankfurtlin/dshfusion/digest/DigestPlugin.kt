package top.frankfurtlin.dshfusion.digest

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Dart 侧的入口：读取缓存、手动刷新、开关推送。
 *
 * 方法：`load` / `refresh` / `enabled` / `setEnabled` / `markSeen` / `ensureScheduled`。
 * 真正干活的是 [DigestSync]；这里只把它包成 Flutter 插件。
 */
class DigestPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "top.frankfurtlin.dshfusion/digest"
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: run { result.error("detached", null, null); return }
        when (call.method) {
            "load" -> result.success(
                mapOf(
                    "json" to DigestSync.cached(ctx),
                    "enabled" to DigestSync.enabled(ctx),
                    "url" to DigestSync.url(ctx),
                ),
            )
            "refresh" -> worker.execute {
                val fresh = DigestSync.refresh(ctx, notify = false)
                val json = DigestSync.cached(ctx)
                main.post { result.success(mapOf("fresh" to fresh, "json" to json)) }
            }
            "enabled" -> result.success(DigestSync.enabled(ctx))
            "setEnabled" -> {
                DigestSync.setEnabled(ctx, call.arguments == true)
                result.success(DigestSync.enabled(ctx))
            }
            "markSeen" -> {
                DigestSync.markAllSeen(ctx)
                result.success(null)
            }
            "ensureScheduled" -> {
                DigestSync.ensureScheduled(ctx)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

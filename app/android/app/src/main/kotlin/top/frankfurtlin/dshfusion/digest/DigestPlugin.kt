package top.frankfurtlin.dshfusion.digest

import android.os.Handler
import android.os.Looper
import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Dart 侧的入口：读取缓存、手动刷新、开关推送。
 *
 * 方法：`load` / `refresh` / `enabled` / `setEnabled` / `markSeen` / `url`（只读）。
 */
class DigestPlugin(private val context: Context) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "top.frankfurtlin.dshfusion/digest"
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> result.success(
                mapOf(
                    "json" to DigestSync.cached(context),
                    "enabled" to DigestSync.enabled(context),
                    "url" to DigestSync.url(context),
                ),
            )
            "refresh" -> worker.execute {
                val fresh = DigestSync.refresh(context, notify = false)
                val json = DigestSync.cached(context)
                main.post { result.success(mapOf("fresh" to fresh, "json" to json)) }
            }
            "enabled" -> result.success(DigestSync.enabled(context))
            "setEnabled" -> {
                DigestSync.setEnabled(context, call.arguments == true)
                result.success(DigestSync.enabled(context))
            }
            "markSeen" -> {
                DigestSync.markAllSeen(context)
                result.success(null)
            }
            "ensureScheduled" -> {
                DigestSync.ensureScheduled(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

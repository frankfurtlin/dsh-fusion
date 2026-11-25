package top.frankfurtlin.dshfusion.digest

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import top.frankfurtlin.dshfusion.MainActivity
import java.util.concurrent.TimeUnit

/**
 * 兴趣推送：后台每 6 小时拉一次服务端的 digest.json，有没看过的条目就发一条本地通知。
 *
 * 为什么在 Kotlin 侧做：
 * - Flutter 的后台 isolate 要额外跑引擎，而这些活的全部内容就是"GET 一个 JSON + 发通知"；
 * - 网络用项目已有的 OkHttp，通知复用现有的通知渠道与 MainActivity 入口。
 *
 * 频率与退出：WorkManager 唯一周期任务，6 小时一次，带网络约束，指数退避。
 * 用户在设置里关掉 → cancelUniqueWork 并清空 seen；服务端地址为空 → 不排期。
 *
 * 点通知回到「发现」页（[TAP_URI]）：那是 App 自己的页面链接，Android 侧交给
 * Flutter 后由 links/page_links.dart 打开（页面 id 见 ui/settings/index/spots.dart）。
 */
object DigestSync {
    private const val PREFS = "pocket_digest"
    private const val KEY_URL = "url"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_CACHE = "cache"
    private const val KEY_SEEN = "seen"
    private const val CHANNEL = "dsh-pocket-digest"
    private const val WORK = "pocket-digest"
    private const val NOTIFY_ID = 7301

    /** 「发现」页（DigestPage）在 `dshgo://open/<id>` 里的 id 与整条链接。 */
    internal const val PAGE_ID = "digest"
    internal const val TAP_URI = "dshgo://open/$PAGE_ID"

    /** 默认摘要地址：公网可读，但路径不可枚举（不包含任何隐私数据）。 */
    const val DEFAULT_URL = "https://hermes.frankfurtlin.top/pocket/r4itxgctmgwxby1pw102/digest.json"

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun url(context: Context): String = prefs(context).getString(KEY_URL, DEFAULT_URL) ?: DEFAULT_URL

    fun enabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, true)

    /** 缓存的摘要原文（Dart 页面直接读这个，离线也能看）。 */
    fun cached(context: Context): String = prefs(context).getString(KEY_CACHE, "") ?: ""

    /** 已经提示过的条目 id。 */
    fun seen(context: Context): Set<String> =
        prefs(context).getStringSet(KEY_SEEN, emptySet()) ?: emptySet()

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
        if (enabled) ensureScheduled(context) else cancel(context)
    }

    fun ensureScheduled(context: Context) {
        if (!enabled(context) || url(context).isBlank()) {
            cancel(context)
            return
        }
        val request = PeriodicWorkRequestBuilder<DigestWorker>(6, TimeUnit.HOURS)
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
            )
            .setBackoffCriteria(androidx.work.BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
            .build()
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(WORK)
    }

    /** 拉一次；返回新条目的数量（0 表示没有新内容）。 */
    fun refresh(context: Context, notify: Boolean): Int {
        if (!enabled(context)) return 0
        val target = url(context)
        if (target.isBlank()) return 0

        val body = try {
            val client = OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(20, TimeUnit.SECONDS)
                .build()
            client.newCall(
                Request.Builder().url(target).header("User-Agent", "dsh-pocket/1.0").build(),
            ).execute().use { response ->
                if (!response.isSuccessful) return 0
                response.body?.string().orEmpty()
            }
        } catch (_: Exception) {
            return 0                                   // 网络问题：静默跳过，下次再来
        }
        if (body.isBlank()) return 0

        val items = try {
            JSONObject(body).optJSONArray("items") ?: JSONArray()
        } catch (_: Exception) {
            return 0
        }
        prefs(context).edit().putString(KEY_CACHE, body).apply()

        val known = seen(context)
        val fresh = mutableListOf<JSONObject>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val id = item.optString("id")
            if (id.isNotEmpty() && id !in known) fresh += item
        }
        if (fresh.isEmpty()) return 0

        val updated = known + fresh.mapNotNull { it.optString("id").takeIf { id -> id.isNotEmpty() } }
        prefs(context).edit().putStringSet(KEY_SEEN, updated).apply()
        if (notify) post(context, fresh)
        return fresh.size
    }

    /** 把当前缓存的条目全部标记为已提示（打开页面时调用，避免后又弹一次）。 */
    fun markAllSeen(context: Context) {
        val cached = cached(context)
        if (cached.isBlank()) return
        val items = try {
            JSONObject(cached).optJSONArray("items") ?: return
        } catch (_: Exception) {
            return
        }
        val ids = seen(context).toMutableSet()
        for (i in 0 until items.length()) {
            items.optJSONObject(i)?.optString("id")?.takeIf { it.isNotEmpty() }?.let(ids::add)
        }
        prefs(context).edit().putStringSet(KEY_SEEN, ids).apply()
    }

    private fun post(context: Context, fresh: List<JSONObject>) {
        ensureChannel(context)
        val first = fresh.first()
        val title = first.optString("title")
        val more = fresh.size - 1
        val text = if (more > 0) "$title 等 $more 条" else first.optString("summary")

        // 「发现」页的页面链接（ACTION_VIEW + dshgo://open/digest）：LinksPlugin 把
        // 它交给 Flutter，LinkHost 再压上那一页。只带一个 extra 没人读，点了就是
        // 回到上一次停留的页面 —— 内容看起来哪都没有。
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse(TAP_URI)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        }
        val pending = PendingIntent.getActivity(
            context, NOTIFY_ID, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val big = fresh.joinToString("\n") { "· " + it.optString("title") }
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("为你挑了 ${fresh.size} 条")
            .setContentText(text.take(120))
            .setStyle(Notification.BigTextStyle().bigText(big))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        try {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)
                ?.notify(NOTIFY_ID, notification)
        } catch (_: SecurityException) {
            // 没有通知权限：不打扰用户，页面里仍能看到内容
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(CHANNEL) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "兴趣推送", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "按你的兴趣方向挑的内容"
                setShowBadge(true)
            },
        )
    }
}

package top.frankfurtlin.dshfusion.links

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import top.frankfurtlin.dshfusion.MainActivity

/**
 * Receives `dshgo://` links and opened `.dshgo` files (the manifest's intent filters sit here,
 * not on MainActivity; shared ones go through share/ShareActivity) and hands them to the app's
 * own task.
 *
 * Apps like WeChat start a VIEW activity inside their own task, without
 * FLAG_ACTIVITY_NEW_TASK; aimed at MainActivity that would create a second Flutter activity
 * there. Forwarding with NEW_TASK | SINGLE_TOP | CLEAR_TOP brings the existing MainActivity
 * forward (closing a Custom Tab above it) and delivers the link through onNewIntent, or starts
 * the app with it. Read access to an opened `content:` URI is passed on with the intent.
 *
 * A link for an app that is already running is handed to its engine first
 * ([LinksPlugin.handOver]) and the forward then carries no data: this activity is NoDisplay and
 * finishes in onCreate, and the hop it starts can be coalesced while the app is already on
 * screen, so the link must not depend on that hop becoming an onNewIntent. Files keep the hop as
 * their only path — the URI read grant rides on this intent, and the copy happens in the app.
 */
class LinkTrampolineActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val scheme = intent?.data?.scheme?.lowercase()
        val link = scheme == LinksPlugin.SCHEME || scheme == "https" || scheme == "http"
        val handed = link && LinksPlugin.handOver(Intent(intent))
        val forward = Intent(intent).apply {
            setClass(this@LinkTrampolineActivity, MainActivity::class.java)
            // Already delivered: this intent only brings the app forward.
            if (handed) data = null
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        try {
            startActivity(forward)
        } catch (_: Exception) {
            // Nothing to hand over to: the link is dropped.
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}

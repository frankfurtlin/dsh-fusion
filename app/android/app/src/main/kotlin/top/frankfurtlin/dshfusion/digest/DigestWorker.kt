package top.frankfurtlin.dshfusion.digest

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

/** 周期任务的壳：真正的事在 [DigestSync.refresh] 里。 */
class DigestWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        return try {
            DigestSync.refresh(applicationContext, notify = true)
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        }
    }
}

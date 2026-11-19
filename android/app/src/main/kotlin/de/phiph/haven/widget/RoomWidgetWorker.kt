package de.phiph.haven.widget

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.Constraints
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Holt Licht, Temperatur und Bild der Raum-Widgets aus Home Assistant und
 * zeichnet sie neu. Läuft alle 15 Minuten (öfter erlaubt Android nicht),
 * nach dem Schalten und wenn die App eine Änderung meldet.
 */
class RoomWidgetWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val ctx = applicationContext
        val ids = inputData.getIntArray(KEY_IDS)?.toList() ?: RoomWidgetStore.ids(ctx)
        if (ids.isEmpty()) return@withContext Result.success()
        val url = RoomWidgetStore.url(ctx)
        val token = RoomWidgetStore.token(ctx)
        if (url == null || token == null) {
            for (id in ids) {
                val cfg = RoomWidgetStore.config(ctx, id) ?: continue
                RoomWidgetRender.message(ctx, id, cfg.optString("name"), "Haven öffnen, um zu verbinden")
            }
            return@withContext Result.success()
        }
        val ha = RoomWidgetHa(url, token)
        var failed = false
        for (id in ids) {
            val cfg = RoomWidgetStore.config(ctx, id) ?: continue
            try {
                refresh(ctx, ha, id, cfg)
            } catch (e: Exception) {
                failed = true
            }
        }
        if (failed && runAttemptCount < 2) Result.retry() else Result.success()
    }

    private fun refresh(ctx: Context, ha: RoomWidgetHa, id: Int, cfg: JSONObject) {
        val lights = cfg.optJSONArray("lights")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
        val states = lights.mapNotNull { ha.state(it) }
        if (lights.isNotEmpty() && states.isEmpty()) error("keine Zustände")
        val temp = cfg.optString("temp").takeIf { it.isNotEmpty() }?.let { ha.state(it) }
        val images = cfg.optJSONObject("image")
        val entity = images?.optString(if (RoomWidgetRender.isDark(ctx)) "dark" else "light")
            ?.takeIf { it.isNotEmpty() }
            ?: images?.optString("dark")?.takeIf { it.isNotEmpty() }
        val bmp = entity?.let { runCatching { ha.image(it) }.getOrNull() }
        RoomWidgetRender.update(
            ctx, id, cfg, RoomWidgetRender.lightOf(states), RoomWidgetRender.temperature(temp), bmp,
            // Ohne Bild-Entity ganz zeichnen; schlug nur das Bild fehl, bleibt das alte.
            full = entity == null || bmp != null,
        )
    }

    companion object {
        private const val KEY_IDS = "ids"
        private const val PERIODIC = "haven_room_widget_periodic"

        private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /** Jetzt (bzw. nach [delayMs]) neu zeichnen; `null`: alle. */
        fun enqueue(ctx: Context, ids: IntArray? = null, delayMs: Long = 0) {
            val data = Data.Builder().apply { if (ids != null) putIntArray(KEY_IDS, ids) }.build()
            val req = OneTimeWorkRequestBuilder<RoomWidgetWorker>()
                .setInputData(data)
                .setConstraints(online)
                .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
                .build()
            val name = "haven_room_widget_" + (ids?.sorted()?.joinToString("_") ?: "all")
            WorkManager.getInstance(ctx).enqueueUniqueWork(name, ExistingWorkPolicy.REPLACE, req)
            schedulePeriodic(ctx)
        }

        fun schedulePeriodic(ctx: Context) {
            val req = PeriodicWorkRequestBuilder<RoomWidgetWorker>(15, TimeUnit.MINUTES)
                .setConstraints(online)
                .build()
            WorkManager.getInstance(ctx)
                .enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, req)
        }

        fun cancelPeriodic(ctx: Context) {
            WorkManager.getInstance(ctx).cancelUniqueWork(PERIODIC)
        }
    }
}

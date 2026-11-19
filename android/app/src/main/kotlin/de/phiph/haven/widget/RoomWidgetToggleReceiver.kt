package de.phiph.haven.widget

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Tippen auf ein Raum-Widget: Licht des Raums schalten (eine Lampe an:
 * alle aus, sonst alle an) und kurz danach das Bild neu holen (Home
 * Assistant setzt es nach etwa einer Sekunde neu zusammen).
 */
class RoomWidgetToggleReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, -1)
        val cfg = RoomWidgetStore.config(ctx, id) ?: return
        val url = RoomWidgetStore.url(ctx) ?: return
        val token = RoomWidgetStore.token(ctx) ?: return
        val lights = cfg.optJSONArray("lights")?.let { a -> (0 until a.length()).map { a.getString(it) } }
            ?: return
        if (lights.isEmpty()) return
        val pending = goAsync()
        Thread {
            try {
                val ha = RoomWidgetHa(url, token)
                val states = lights.mapNotNull { runCatching { ha.state(it) }.getOrNull() }
                val anyOn = states.any { it.optString("state") == "on" }
                ha.call("light", if (anyOn) "turn_off" else "turn_on", lights)
                // Sofort den neuen Zustand zeigen, das Bild folgt.
                val after = states.map { s ->
                    org.json.JSONObject(s.toString()).put("state", if (anyOn) "off" else "on")
                }
                RoomWidgetRender.update(ctx, id, cfg, RoomWidgetRender.lightOf(after), null, null)
            } catch (_: Exception) {
            } finally {
                RoomWidgetWorker.enqueue(ctx, intArrayOf(id), delayMs = 1500)
                pending.finish()
            }
        }.start()
    }
}

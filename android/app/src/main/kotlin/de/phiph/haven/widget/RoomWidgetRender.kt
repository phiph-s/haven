package de.phiph.haven.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.view.View
import android.widget.RemoteViews
import de.phiph.haven.MainActivity
import de.phiph.haven.R
import org.json.JSONObject
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt

/** Licht eines Raums aus den Zuständen seiner Lampen. */
data class RoomLight(val total: Int, val on: Int, val brightness: Int, val color: Int)

object RoomWidgetRender {

    fun isDark(ctx: Context): Boolean =
        (ctx.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    /** Licht aus den Zuständen (`light.*`), wie die Kachel in der App. */
    fun lightOf(states: List<JSONObject>): RoomLight {
        val on = states.filter { it.optString("state") == "on" }
        var r = 0.0; var g = 0.0; var b = 0.0; var w = 0.0; var bri = 0.0
        for (s in on) {
            val a = s.optJSONObject("attributes") ?: JSONObject()
            val b255 = a.optDouble("brightness", 255.0)
            val pct = (b255 / 255 * 100).coerceIn(1.0, 100.0)
            bri += pct
            val rgb = a.optJSONArray("rgb_color")
            val c = if (rgb != null && rgb.length() >= 3) {
                Triple(rgb.getDouble(0), rgb.getDouble(1), rgb.getDouble(2))
            } else {
                kelvin(a.optDouble("color_temp_kelvin", 2700.0))
            }
            r += c.first * pct; g += c.second * pct; b += c.third * pct; w += pct
        }
        val color = if (w > 0) Color.rgb((r / w).roundToInt(), (g / w).roundToInt(), (b / w).roundToInt())
        else Color.TRANSPARENT
        return RoomLight(states.size, on.size, if (on.isEmpty()) 0 else (bri / on.size).roundToInt(), color)
    }

    /** Wie `kelvinToRgb` der App. */
    private fun kelvin(kelvin: Double): Triple<Double, Double, Double> {
        val k = kelvin.coerceIn(1000.0, 40000.0) / 100
        val r = if (k <= 66) 255.0 else 329.698727446 * (k - 60).pow(-0.1332047592)
        val g = if (k <= 66) 99.4708025861 * ln(k) - 161.1195681661 else 288.1221695283 * (k - 60).pow(-0.0755148492)
        val b = if (k >= 66) 255.0 else if (k <= 19) 0.0 else 138.5177312231 * ln(k - 10) - 305.0447927307
        return Triple(r.coerceIn(0.0, 255.0), g.coerceIn(0.0, 255.0), b.coerceIn(0.0, 255.0))
    }

    fun status(l: RoomLight): String = when {
        l.total == 0 -> "Keine Lampen"
        l.on == 0 -> "Aus"
        l.on == 1 -> "Licht · ${l.brightness} %"
        else -> "${l.on} Lichter · ${l.brightness} %"
    }

    fun temperature(state: JSONObject?): String? {
        val v = state?.optString("state")?.toDoubleOrNull() ?: return null
        return String.format(java.util.Locale.GERMANY, "%.1f°", v)
    }

    /**
     * Widget [id] zeichnen. Mit [full] `false` und ohne [image] bleibt das
     * letzte Bild stehen (nur Texte und Schein ändern sich).
     */
    fun update(
        ctx: Context,
        id: Int,
        cfg: JSONObject,
        light: RoomLight,
        temp: String?,
        image: Bitmap?,
        full: Boolean = image != null,
    ) {
        val v = RemoteViews(ctx.packageName, R.layout.room_widget)
        v.setTextViewText(R.id.room_name, cfg.optString("name"))
        v.setTextViewText(R.id.room_status, status(light))
        if (temp != null) {
            v.setTextViewText(R.id.room_temp, temp)
            v.setViewVisibility(R.id.room_temp, View.VISIBLE)
        } else {
            v.setViewVisibility(R.id.room_temp, View.GONE)
        }
        if (image != null) v.setImageViewBitmap(R.id.room_render, image)
        // Schein in der Mischfarbe der Lampen, wie der Farbverlauf der Kachel.
        if (light.on > 0) {
            v.setInt(R.id.room_glow, "setColorFilter", light.color)
            v.setInt(R.id.room_glow, "setImageAlpha", (90 + 1.3 * light.brightness).roundToInt().coerceAtMost(220))
            v.setInt(R.id.room_dot, "setColorFilter", light.color)
        } else {
            v.setInt(R.id.room_glow, "setImageAlpha", 0)
            v.setInt(R.id.room_dot, "setColorFilter", ctx.getColor(R.color.room_widget_dot_off))
        }
        // Tippen schaltet das Licht, der Pfeil öffnet den Raum in der App.
        val toggle = Intent(ctx, RoomWidgetToggleReceiver::class.java)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
        v.setOnClickPendingIntent(
            R.id.room_root,
            PendingIntent.getBroadcast(
                ctx, id, toggle,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        val open = Intent(ctx, MainActivity::class.java)
            .putExtra("route", "/home/room/${cfg.optString("room")}")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        v.setOnClickPendingIntent(
            R.id.room_open,
            PendingIntent.getActivity(
                ctx, 100000 + id, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        val mgr = AppWidgetManager.getInstance(ctx)
        if (full) mgr.updateAppWidget(id, v) else mgr.partiallyUpdateAppWidget(id, v)
    }

    /** Ohne Verbindung oder Einstellung: Hinweis statt Bild. */
    fun message(ctx: Context, id: Int, name: String, text: String) {
        val v = RemoteViews(ctx.packageName, R.layout.room_widget)
        v.setTextViewText(R.id.room_name, name)
        v.setTextViewText(R.id.room_status, text)
        v.setViewVisibility(R.id.room_temp, View.GONE)
        v.setInt(R.id.room_glow, "setImageAlpha", 0)
        AppWidgetManager.getInstance(ctx).updateAppWidget(id, v)
    }
}

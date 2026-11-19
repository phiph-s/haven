package de.phiph.haven.widget

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/**
 * Kanal `de.phiph.haven/room_widget` zwischen Dart und den Raum-Widgets:
 * Zugangsdaten ablegen, Widgets einrichten und neu zeichnen lassen.
 */
object RoomWidgetChannel {
    fun attach(engine: FlutterEngine, ctx: Context, activity: Activity?) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "de.phiph.haven/room_widget")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "setCredentials" -> {
                            val url = call.argument<String>("url")
                            val token = call.argument<String>("token")
                            if (url.isNullOrEmpty() || token.isNullOrEmpty()) {
                                RoomWidgetStore.clearCredentials(ctx)
                            } else {
                                RoomWidgetStore.setCredentials(ctx, url, token)
                            }
                            result.success(null)
                        }
                        "widgets" -> {
                            val mgr = AppWidgetManager.getInstance(ctx)
                            val live = mgr.getAppWidgetIds(ComponentName(ctx, RoomWidgetProvider::class.java)).toSet()
                            val out = JSONArray()
                            for (id in RoomWidgetStore.ids(ctx)) {
                                if (id !in live) continue
                                val cfg = RoomWidgetStore.config(ctx, id) ?: continue
                                out.put(cfg.put("id", id))
                            }
                            result.success(out.toString())
                        }
                        "saveWidget" -> {
                            val id = call.argument<Int>("id") ?: error("id fehlt")
                            val cfg = JSONObject(call.argument<String>("config") ?: error("config fehlt"))
                            RoomWidgetStore.saveConfig(ctx, id, cfg)
                            RoomWidgetWorker.enqueue(ctx, intArrayOf(id))
                            result.success(null)
                        }
                        "finishConfigure" -> {
                            val id = call.argument<Int>("id") ?: error("id fehlt")
                            activity?.setResult(
                                Activity.RESULT_OK,
                                Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
                            )
                            activity?.finish()
                            result.success(null)
                        }
                        "refresh" -> {
                            val ids = call.argument<List<Int>>("ids")?.toIntArray()
                            RoomWidgetWorker.enqueue(ctx, ids)
                            result.success(null)
                        }
                        "launchRoute" -> {
                            val route = activity?.intent?.getStringExtra("route")
                            activity?.intent?.removeExtra("route")
                            result.success(route)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("room_widget", e.message, null)
                }
            }
    }
}

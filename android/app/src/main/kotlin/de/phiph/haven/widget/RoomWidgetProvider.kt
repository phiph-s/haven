package de.phiph.haven.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context

/** Raum-Widget: der Raum mit seinem Licht (Bild aus Home Assistant). */
class RoomWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(ctx: Context, mgr: AppWidgetManager, ids: IntArray) {
        RoomWidgetWorker.enqueue(ctx, ids)
    }

    override fun onEnabled(ctx: Context) {
        RoomWidgetWorker.schedulePeriodic(ctx)
    }

    override fun onDisabled(ctx: Context) {
        RoomWidgetWorker.cancelPeriodic(ctx)
    }

    override fun onDeleted(ctx: Context, ids: IntArray) {
        for (id in ids) RoomWidgetStore.removeConfig(ctx, id)
    }
}

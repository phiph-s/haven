package de.phiph.haven.widget

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Einrichten eines Raum-Widgets: Haven öffnet sich mit der Raumauswahl
 * (Route `/widget-config/<id>`), Dart meldet die Wahl über den Kanal.
 */
class RoomWidgetConfigActivity : FlutterActivity() {
    private val widgetId: Int
        get() = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        // Abbrechen heißt: kein Widget.
        setResult(Activity.RESULT_CANCELED)
        super.onCreate(savedInstanceState)
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) finish()
    }

    override fun getInitialRoute(): String = "/widget-config/$widgetId"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RoomWidgetChannel.attach(flutterEngine, applicationContext, this)
    }
}

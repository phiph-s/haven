package de.phiph.haven.widget

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** Kleiner REST-Zugriff auf Home Assistant für die Widgets (ohne Flutter). */
class RoomWidgetHa(private val url: String, private val token: String) {

    private fun open(path: String, method: String = "GET"): HttpURLConnection =
        (URL(url + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 8000
            readTimeout = 12000
            setRequestProperty("Authorization", "Bearer $token")
        }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    /** Zustand einer Entity oder `null` (fehlt, kein Netz). */
    fun state(entityId: String): JSONObject? {
        val c = open("/api/states/${enc(entityId)}")
        return try {
            if (c.responseCode != 200) null
            else JSONObject(c.inputStream.bufferedReader().readText())
        } finally {
            c.disconnect()
        }
    }

    /** Bild einer Image-Entity, auf höchstens [maxWidth] Pixel verkleinert. */
    fun image(entityId: String, maxWidth: Int = 720): Bitmap? {
        val c = open("/api/image_proxy/${enc(entityId)}")
        return try {
            if (c.responseCode != 200) return null
            val bytes = c.inputStream.readBytes()
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= maxWidth) sample *= 2
            BitmapFactory.decodeByteArray(
                bytes, 0, bytes.size,
                BitmapFactory.Options().apply { inSampleSize = sample },
            )
        } finally {
            c.disconnect()
        }
    }

    /** Dienst aufrufen, z. B. `light.turn_on` für [entityIds]. */
    fun call(domain: String, service: String, entityIds: List<String>) {
        val c = open("/api/services/${enc(domain)}/${enc(service)}", "POST")
        try {
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            val body = JSONObject().put("entity_id", JSONArray(entityIds)).toString()
            c.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            if (c.responseCode !in 200..299) error("HTTP ${c.responseCode}")
        } finally {
            c.disconnect()
        }
    }
}

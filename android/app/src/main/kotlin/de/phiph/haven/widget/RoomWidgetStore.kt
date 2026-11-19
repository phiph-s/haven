package de.phiph.haven.widget

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Ablage der Raum-Widgets: Adresse von Home Assistant, der Token
 * (verschlüsselt mit einem Schlüssel im Android-Keystore, AES-GCM) und je
 * Widget seine Einstellung (Raum, Lampen, Bild-Entities) als JSON.
 */
object RoomWidgetStore {
    private const val PREFS = "haven_room_widget"
    private const val KEY_ALIAS = "haven_room_widget_token"

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun setCredentials(ctx: Context, url: String, token: String) {
        prefs(ctx).edit()
            .putString("url", url.trimEnd('/'))
            .putString("token", encrypt(token))
            .apply()
    }

    fun clearCredentials(ctx: Context) {
        prefs(ctx).edit().remove("url").remove("token").apply()
    }

    fun url(ctx: Context): String? = prefs(ctx).getString("url", null)

    fun token(ctx: Context): String? =
        prefs(ctx).getString("token", null)?.let { runCatching { decrypt(it) }.getOrNull() }

    fun saveConfig(ctx: Context, id: Int, config: JSONObject) {
        prefs(ctx).edit().putString("w_$id", config.toString()).apply()
    }

    fun config(ctx: Context, id: Int): JSONObject? =
        prefs(ctx).getString("w_$id", null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    fun removeConfig(ctx: Context, id: Int) {
        prefs(ctx).edit().remove("w_$id").apply()
    }

    fun ids(ctx: Context): List<Int> =
        prefs(ctx).all.keys.filter { it.startsWith("w_") }.mapNotNull { it.removePrefix("w_").toIntOrNull() }

    // ---- Keystore ------------------------------------------------------------

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return gen.generateKey()
    }

    private fun encrypt(text: String): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val out = c.iv + c.doFinal(text.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    private fun decrypt(data: String): String {
        val raw = Base64.decode(data, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw.copyOfRange(0, 12)))
        return String(c.doFinal(raw.copyOfRange(12, raw.size)), Charsets.UTF_8)
    }
}

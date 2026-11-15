package de.phiph.haven

import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.View
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Edge-to-edge ab dem ersten Frame: Status- und Navigationsleiste sind
 * durchsichtig, Flutter zeichnet dahinter (Abstände über MediaQuery.padding
 * bzw. SafeArea). Ab Android 15 (targetSdk 35) erzwingt das System das
 * ohnehin, darunter setzen wir es hier, damit beim Start nichts springt.
 * Die Helligkeit der Symbole setzt Flutter je Bildschirm per
 * AnnotatedRegion<SystemUiOverlayStyle>.
 */
class MainActivity : FlutterActivity() {
    /**
     * App-Update: Der Dart-Teil lädt das APK in den Cache, dieser Kanal fragt die
     * Erlaubnis „Unbekannte Apps installieren“ ab und übergibt die Datei dem
     * Paketinstaller (ACTION_VIEW über den FileProvider).
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.phiph.haven/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "canInstall" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                    )
                    "openInstallSettings" -> {
                        val i = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(i)
                        result.success(null)
                    }
                    "install" -> {
                        try {
                            val path = call.argument<String>("path")
                                ?: return@setMethodCallHandler result.error("args", "path fehlt", null)
                            val file = File(path).canonicalFile
                            // Nur Dateien aus dem Cache der App.
                            if (!file.path.startsWith(cacheDir.canonicalPath + File.separator) ||
                                !file.isFile
                            ) {
                                return@setMethodCallHandler result.error("path", "Ungültiger Pfad", null)
                            }
                            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                            val i = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("install", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val w = window
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            w.setDecorFitsSystemWindows(false)
        } else {
            @Suppress("DEPRECATION")
            w.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                )
        }
        if (Build.VERSION.SDK_INT < 35) {
            // Ab Android 15 wirkungslos und veraltet, dort sind die Leisten
            // immer durchsichtig.
            @Suppress("DEPRECATION")
            w.statusBarColor = Color.TRANSPARENT
            @Suppress("DEPRECATION")
            w.navigationBarColor = Color.TRANSPARENT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Kein grauer Schleier hinter der Gestenleiste.
            w.isNavigationBarContrastEnforced = false
            w.isStatusBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            w.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            w.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }
}

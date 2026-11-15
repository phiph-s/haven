package de.phiph.haven

import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

/**
 * Edge-to-edge ab dem ersten Frame: Status- und Navigationsleiste sind
 * durchsichtig, Flutter zeichnet dahinter (Abstände über MediaQuery.padding
 * bzw. SafeArea). Ab Android 15 (targetSdk 35) erzwingt das System das
 * ohnehin, darunter setzen wir es hier, damit beim Start nichts springt.
 * Die Helligkeit der Symbole setzt Flutter je Bildschirm per
 * AnnotatedRegion<SystemUiOverlayStyle>.
 */
class MainActivity : FlutterActivity() {
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

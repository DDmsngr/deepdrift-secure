package com.deepdrift.secure

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {

    companion object {
        private const val SECURE_CHANNEL = "com.deepdrift.secure/window"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── FLAG_SECURE channel (replaces flutter_windowmanager) ─────────────
        // Запрещает/разрешает скриншоты и запись экрана в чате.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "addSecureFlag" -> {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(null)
                    }
                    "clearSecureFlag" -> {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Notification channels (Android 8.0+) ─────────────────────────────
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            createNotificationChannels()
        }
    }

    private fun createNotificationChannels() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val cyan = android.graphics.Color.parseColor("#00D9FF")

        listOf(
            Triple("chat_messages",         "Chat Messages",           "Incoming chat messages"),
            Triple("background_messages",   "Background Messages",     "Messages received in background"),
            Triple("high_importance_channel","Important Notifications", "High priority notifications"),
        ).forEach { (id, name, desc) ->
            NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH).apply {
                description = desc
                enableVibration(true)
                enableLights(true)
                lightColor = cyan
                setShowBadge(true)
            }.also { nm.createNotificationChannel(it) }
        }
    }
}

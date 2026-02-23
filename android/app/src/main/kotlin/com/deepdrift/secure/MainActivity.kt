package com.deepdrift.secure

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Создаём каналы уведомлений для Android 8.0+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            createNotificationChannels()
        }
    }

    private fun createNotificationChannels() {
        val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        
        // Канал для сообщений в реальном времени (foreground)
        val chatChannel = NotificationChannel(
            "chat_messages",
            "Chat Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Notifications for incoming chat messages"
            enableVibration(true)
            enableLights(true)
            lightColor = android.graphics.Color.parseColor("#00D9FF")
            setShowBadge(true)
        }
        
        // Канал для фоновых сообщений (background)
        val backgroundChannel = NotificationChannel(
            "background_messages",
            "Background Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Notifications for messages received in background"
            enableVibration(true)
            enableLights(true)
            lightColor = android.graphics.Color.parseColor("#00D9FF")
            setShowBadge(true)
        }
        
        // Высокоприоритетный канал по умолчанию
        val highImportanceChannel = NotificationChannel(
            "high_importance_channel",
            "Important Notifications",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "High priority notifications"
            enableVibration(true)
            enableLights(true)
            lightColor = android.graphics.Color.parseColor("#00D9FF")
            setShowBadge(true)
        }
        
        // Регистрируем все каналы
        notificationManager.createNotificationChannel(chatChannel)
        notificationManager.createNotificationChannel(backgroundChannel)
        notificationManager.createNotificationChannel(highImportanceChannel)
    }
}

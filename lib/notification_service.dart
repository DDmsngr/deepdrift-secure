import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    // Запрос разрешений (дублируется из main.dart — безвредно)
    await _fcm.requestPermission(alert: true, badge: true, sound: true);

    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings =
        InitializationSettings(android: androidInit);

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        print('📲 User tapped notification: ${response.payload}');
        // TODO: навигация к чату по response.payload (from_uid)
      },
    );

    // ── Foreground: приложение активно ───────────────────────────────────
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('📲 FCM foreground: ${message.messageId}');

      // ── БАГ 5 FIX: Не показываем foreground-уведомление если текст пришёл
      // через WebSocket (он приоритетнее). Уведомление нужно ТОЛЬКО если
      // сокет не доставил сообщение (редкий кейс).
      // Простая эвристика: FCM data-only без notification → показываем.
      // FCM с notification → Android сам покажет (мы не дублируем).
      if (message.notification == null) {
        // data-only push — показываем локально
        final fromUid = message.data['from_uid'] ?? '';
        showMessageNotification(
          fromUid: fromUid,
          displayName: 'DDChat: $fromUid',
          // ── Никогда не показываем зашифрованный/сырой текст ──────────
          messageText: 'New encrypted message',
        );
      }
      // Если notification != null — Android/iOS сами отображают баннер,
      // дублировать локальным уведомлением не нужно.
    });

    // ── Background: пользователь тапнул уведомление ──────────────────────
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('📲 Opened from notification: ${message.data['from_uid']}');
      // TODO: навигация к чату
    });

    // ── Cold start: приложение было убито ────────────────────────────────
    final initialMessage = await _fcm.getInitialMessage();
    if (initialMessage != null) {
      print('📲 App launched from notification: ${initialMessage.data['from_uid']}');
      // TODO: навигация к чату после загрузки
    }
  }

  Future<void> showMessageNotification({
    required String fromUid,
    required String displayName,
    required String messageText,
  }) async {
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'chat_messages',
      'Chat Messages',
      channelDescription: 'Notifications for incoming chat messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      color: const Color(0xFF00D9FF),
      enableVibration: true,
      playSound: true,
      ticker: 'New message',
      styleInformation: BigTextStyleInformation(
        messageText,
        contentTitle: displayName,
        summaryText: 'DDChat',
      ),
    );

    await _localNotifications.show(
      fromUid.hashCode, // один ID на контакт → новое уведомление заменяет старое
      displayName,
      messageText,
      NotificationDetails(android: androidDetails),
      payload: fromUid,
    );
  }

  Future<String?> getToken() async {
    try {
      return await _fcm.getToken();
    } catch (e) {
      return null;
    }
  }
}

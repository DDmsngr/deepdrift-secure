import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    // Запрос разрешений
    await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Настройка локальных уведомлений
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await _localNotifications.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        print('📲 User tapped notification: ${response.payload}');
        // TODO: Навигация к чату при нажатии на уведомление
      },
    );

    // ИСПРАВЛЕНИЕ #1: Обработка уведомлений когда приложение АКТИВНО (foreground)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('📲 FCM message received (foreground): ${message.messageId}');
      print('   Data: ${message.data}');
      
      if (message.notification != null) {
        print('   Has notification: ${message.notification!.title}');
        showMessageNotification(
          fromUid: message.data['from_uid'] ?? '',
          displayName: message.notification!.title ?? 'DeepDrift',
          messageText: message.notification!.body ?? '',
        );
      }
    });

    // ИСПРАВЛЕНИЕ #2: Обработка уведомлений когда приложение СВЁРНУТО (background)
    // Это срабатывает когда приложение в фоне но не убито
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('📲 User opened app from notification: ${message.messageId}');
      print('   From: ${message.data['from_uid']}');
      // TODO: Навигация к чату
    });

    // ИСПРАВЛЕНИЕ #3: Проверяем, было ли приложение запущено через уведомление
    final initialMessage = await _fcm.getInitialMessage();
    if (initialMessage != null) {
      print('📲 App launched from notification: ${initialMessage.messageId}');
      print('   From: ${initialMessage.data['from_uid']}');
      // TODO: Навигация к чату после загрузки
    }
  }

  Future<void> showMessageNotification({
    required String fromUid,
    required String displayName,
    required String messageText,
  }) async {
    print('🔔 Showing local notification for $fromUid: $messageText');
    
    // ИСПРАВЛЕНИЕ: Убрали const, так как используем динамические значения
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'chat_messages',
      'Chat Messages',
      channelDescription: 'Notifications for incoming chat messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
      color: Color(0xFF00D9FF),
      enableVibration: true,
      playSound: true,
      // Теперь можем использовать динамические значения
      ticker: 'New message from $displayName',
      styleInformation: BigTextStyleInformation(
        messageText,
        contentTitle: displayName,
        summaryText: 'DeepDrift',
      ),
    );
    
    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await _localNotifications.show(
      fromUid.hashCode, // Используем хэш uid чтобы обновлять уведомления от одного человека
      displayName,
      messageText,
      platformChannelSpecifics,
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

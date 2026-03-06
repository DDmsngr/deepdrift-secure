import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';

import 'crypto_service.dart';
import 'notification_service.dart';
import 'providers/app_providers.dart';
import 'splash_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

// Background message handler — вызывается Flutter в отдельном изоляте
// когда приложение убито или в фоне. Показывает локальное уведомление.
// ВАЖНО: должна быть top-level функцией (не методом класса)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Инициализируем плагин локальных уведомлений в фоновом изоляте
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  final localNotifications = FlutterLocalNotificationsPlugin();
  await localNotifications.initialize(initSettings);

  // Создаём канал (Android 8+)
  final androidPlugin = localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await androidPlugin?.createNotificationChannel(const AndroidNotificationChannel(
    'background_messages',
    'Background Messages',
    description: 'Messages received while app is killed',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    showBadge: true,
  ));

  final fromUid = message.data['from_uid'] as String? ?? 'Unknown';
  await localNotifications.show(
    fromUid.hashCode,
    'DDChat',
    'New encrypted message',
    NotificationDetails(
      android: AndroidNotificationDetails(
        'background_messages',
        'Background Messages',
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
      ),
    ),
    payload: fromUid,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  try {
    await Firebase.initializeApp();
    // Регистрируем background handler ДО любых других FCM вызовов
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (_) {}

  await NotificationService().init();

  final cipher = SecureCipher();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CipherProvider(cipher)),
        ChangeNotifierProvider(create: (_) => SocketProvider()),
        ChangeNotifierProvider(create: (_) => StorageProvider()),
      ],
      child: MaterialApp(
        title: 'DDChat',
        debugShowCheckedModeBanner: false,
        navigatorKey: NotificationService.navigatorKey,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF0A0E27),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF00D9FF)),
        ),
        home: const SplashScreen(),
      ),
    ),
  );
}

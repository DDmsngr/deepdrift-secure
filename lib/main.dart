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
import 'theme_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  if (message.notification != null) return;

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  final localNotifications = FlutterLocalNotificationsPlugin();
  await localNotifications.initialize(initSettings);

  final androidPlugin = localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  final msgType = message.data['type'] as String? ?? '';
  final fromUid = message.data['from_uid'] as String? ?? 'Unknown';

  // ── Входящий звонок (убитое приложение) ────────────────────────────────
  if (msgType == 'incoming_call') {
    await androidPlugin?.createNotificationChannel(const AndroidNotificationChannel(
      'call_channel',
      'DDChat Calls',
      description: 'Incoming voice and video calls',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    ));

    final callType = message.data['call_type'] as String? ?? 'audio';
    final icon = callType == 'video' ? '📹' : '📞';

    await localNotifications.show(
      fromUid.hashCode + 9000, // уникальный ID для звонков
      '$icon Входящий ${callType == 'video' ? 'видео' : ''}звонок',
      'От $fromUid',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'call_channel',
          'DDChat Calls',
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
          visibility: NotificationVisibility.public,
          ongoing: true,
          autoCancel: false,
          showWhen: false,
          timeoutAfter: 30000, // 30 секунд — потом скрыть
        ),
      ),
      payload: 'call:$fromUid:$callType',
    );
    return;
  }

  // ── Обычное сообщение ──────────────────────────────────────────────────
  await androidPlugin?.createNotificationChannel(const AndroidNotificationChannel(
    'high_importance_channel',
    'DDChat Messages',
    description: 'DDChat incoming messages',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    showBadge: true,
  ));

  final displayFrom = (message.data['target_uid'] as String? ?? '').isNotEmpty
      ? message.data['target_uid'] as String
      : fromUid;
  await localNotifications.show(
    displayFrom.hashCode,
    'DDChat',
    'New encrypted message',
    NotificationDetails(
      android: AndroidNotificationDetails(
        'high_importance_channel',
        'DDChat Messages',
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
      ),
    ),
    payload: displayFrom,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  // Читаем сохранённую тему до запуска приложения
  try {
    final settingsBox = await Hive.openBox('settings');
    final savedTheme = settingsBox.get('app_theme_mode') as String? ?? 'dark';
    appThemeMode.value = savedTheme == 'light' ? ThemeMode.light : ThemeMode.dark;
  } catch (_) {}

  try {
    await Firebase.initializeApp();
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
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: appThemeMode,
        builder: (context, themeMode, _) {
          return MaterialApp(
            title: 'DDChat',
            debugShowCheckedModeBanner: false,
            navigatorKey: NotificationService.navigatorKey,
            themeMode: themeMode,
            // ── Тёмная тема (основная) ──────────────────────────────────
            darkTheme: ThemeData.dark().copyWith(
              scaffoldBackgroundColor: const Color(0xFF0A0E27),
              colorScheme: const ColorScheme.dark(primary: Color(0xFF00D9FF)),
              appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1A1F3C)),
              cardColor: const Color(0xFF1A1F3C),
              dividerColor: Colors.white12,
              dialogBackgroundColor: const Color(0xFF1A1F3C),
            ),
            // ── Светлая тема ────────────────────────────────────────────
            theme: ThemeData.light().copyWith(
              scaffoldBackgroundColor: const Color(0xFFF5F5F5),
              colorScheme: const ColorScheme.light(primary: Color(0xFF0088CC)),
              appBarTheme: const AppBarTheme(
                backgroundColor: Color(0xFF0088CC),
                foregroundColor: Colors.white,
              ),
              cardColor: Colors.white,
              dividerColor: Colors.black12,
              dialogBackgroundColor: Colors.white,
            ),
            home: const SplashScreen(),
          );
        },
      ),
    ),
  );
}

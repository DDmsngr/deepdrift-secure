import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'home_screen.dart';
import 'notification_service.dart';
import 'socket_service.dart';

// ── Фоновый обработчик FCM ───────────────────────────────────────────────────
// Должен быть top-level функцией (не методом класса) — требование Firebase.
// Вызывается когда приложение убито или в фоне и приходит data-only push.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('📲 Background FCM received: ${message.messageId}');

  // Показываем локальное уведомление только для data-only push —
  // FCM-уведомления с notification-payload Android показывает сам.
  if (message.notification == null) {
    final plugin = FlutterLocalNotificationsPlugin();

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(const InitializationSettings(android: androidInit));

    final fromUid = message.data['from_uid'] as String? ?? 'DDChat';
    await plugin.show(
      message.hashCode,
      'DDChat: $fromUid',
      'New encrypted message',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'background_messages',
          'Background Messages',
          importance:      Importance.max,
          priority:        Priority.high,
          showWhen:        true,
          color:           Color(0xFF00D9FF),
          enableVibration: true,
          playSound:       true,
        ),
      ),
      payload: fromUid,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Firebase
  await Firebase.initializeApp();

  // 2. Запрос разрешений (Android 13+ / iOS)
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // 3. Foreground-уведомления (нужно для iOS, на Android игнорируется)
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  // 4. Фоновый обработчик FCM
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // 5. Обновление FCM-токена без удаления старого.
  //    deleteToken() при каждом запуске убивал токен в Redis ДО регистрации
  //    нового — push-уведомления переставали приходить на несколько минут.
  //    onTokenRefresh срабатывает только когда Firebase действительно
  //    обновляет токен (раз в несколько недель или после переустановки).
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    debugPrint('🔄 FCM token refreshed, re-registering...');
    SocketService().registerFcmToken(newToken);
  });

  // 6. Инициализация локального хранилища и сервисов
  await Hive.initFlutter();

  // NotificationService.init() должен вызываться ДО runApp(), чтобы
  // getInitialMessage() успел обработать cold-start уведомление.
  await NotificationService().init();

  runApp(const DeepDriftApp());
}

// ─────────────────────────────────────────────────────────────────────────────

class DeepDriftApp extends StatefulWidget {
  const DeepDriftApp({super.key});

  @override
  State<DeepDriftApp> createState() => _DeepDriftAppState();
}

class _DeepDriftAppState extends State<DeepDriftApp>
    with WidgetsBindingObserver {

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('🔄 App lifecycle: $state');
    switch (state) {
      case AppLifecycleState.resumed:
        SocketService().onAppResumed();
        break;
      case AppLifecycleState.paused:
        SocketService().onAppPaused();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DDChat',
      debugShowCheckedModeBanner: false,

      // 🟡-2 FIX: передаём navigatorKey из NotificationService.
      // Это позволяет навигировать к чату по тапу на уведомление
      // без BuildContext — даже из background/killed state.
      navigatorKey: NotificationService.navigatorKey,

      theme: ThemeData(
        brightness:              Brightness.dark,
        primaryColor:            const Color(0xFF00D9FF),
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        colorScheme: const ColorScheme.dark(
          primary:   Color(0xFF00D9FF),
          secondary: Color(0xFF00D9FF),
          surface:   Color(0xFF151B2D),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0E1A),
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

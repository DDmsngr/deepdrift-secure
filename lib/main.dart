import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'home_screen.dart';
import 'notification_service.dart';
import 'socket_service.dart';

// ── Фоновый обработчик (должен быть top-level функцией) ──────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  print("📲 Background FCM received: ${message.messageId}");

  // Показываем локальное уведомление вручную только если нет нотификации от FCM
  // (на Android data-only messages не показываются автоматически)
  if (message.notification == null) {
    final notification = FlutterLocalNotificationsPlugin();
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    await notification.initialize(
        const InitializationSettings(android: androidInit));

    final fromUid = message.data['from_uid'] ?? 'DDChat';
    await notification.show(
      message.hashCode,
      'DDChat: $fromUid',
      'New encrypted message',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'background_messages',
          'Background Messages',
          importance: Importance.max,
          priority: Priority.high,
          showWhen: true,
          color: Color(0xFF00D9FF),
          enableVibration: true,
          playSound: true,
        ),
      ),
      payload: message.data['from_uid'],
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Инициализация Firebase
  await Firebase.initializeApp();

  // 2. Запрос разрешений
  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // 3. Foreground уведомления (iOS)
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  // 4. Регистрация фонового обработчика
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // ── БАГ 3 FIX: НЕ удаляем токен при запуске ─────────────────────────────
  // deleteToken() при каждом запуске убивал FCM-токен в Redis ДО того,
  // как приложение успевало зарегистрировать новый. Это и было причиной
  // "пуши не приходят" в первые секунды/минуты после запуска.
  //
  // Вместо этого подписываемся на onTokenRefresh — Firebase сам сообщит
  // когда токен обновится (раз в несколько недель или после переустановки).
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    print("🔄 FCM token refreshed, re-registering...");
    // SocketService зарегистрирует токен как только получит событие
    SocketService().registerFcmToken(newToken);
  });

  // 5. Инициализация Hive и сервисов
  await Hive.initFlutter();
  await NotificationService().init();

  runApp(const DeepDriftApp());
}

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
    print("🔄 App lifecycle: $state");
    if (state == AppLifecycleState.resumed) {
      SocketService().onAppResumed();
    } else if (state == AppLifecycleState.paused) {
      SocketService().onAppPaused();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DDChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF00D9FF),
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D9FF),
          secondary: Color(0xFF00D9FF),
          surface: Color(0xFF151B2D),
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

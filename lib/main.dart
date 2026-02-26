import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'home_screen.dart';
import 'notification_service.dart';
import 'socket_service.dart';

// ========================================
// КРИТИЧЕСКИ ВАЖНО: Фоновый обработчик
// ========================================
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Инициализируем Firebase для фонового режима
  await Firebase.initializeApp();
  
  print("📲 Background message received: ${message.messageId}");
  
  final notification = FlutterLocalNotificationsPlugin();
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  
  await notification.initialize(initializationSettings);
  
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    'background_messages',
    'Background Messages',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: true,
    color: Color(0xFF00D9FF),
  );
  
  const NotificationDetails platformChannelSpecifics =
      NotificationDetails(android: androidPlatformChannelSpecifics);
  
  await notification.show(
    message.hashCode,
    message.notification?.title ?? 'Новое сообщение',
    message.notification?.body ?? 'У вас новое сообщение',
    platformChannelSpecifics,
    payload: message.data['from_uid'],
  );
}

void main() async {
  // Гарантируем инициализацию движка Flutter
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Инициализация Firebase
  await Firebase.initializeApp();
  
  // 2. Запрос разрешений на уведомления (для Android 13+ и iOS)
  FirebaseMessaging messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // Настройка уведомлений при открытом приложении
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );
  
  // 3. Регистрация фонового обработчика
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  
  // 4. Инициализация Hive и сервисов
  await Hive.initFlutter();
  await NotificationService().init();
  
  runApp(const DeepDriftApp());
}

class DeepDriftApp extends StatefulWidget {
  const DeepDriftApp({super.key});

  @override
  State<DeepDriftApp> createState() => _DeepDriftAppState();
}

class _DeepDriftAppState extends State<DeepDriftApp> with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    print("🔄 Lifecycle observer registered");
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    print("🔄 App lifecycle changed: $state");
    
    if (state == AppLifecycleState.resumed) {
      print("✅ App RESUMED - calling socket service");
      SocketService().onAppResumed();
    } else if (state == AppLifecycleState.paused) {
      print("⏸️ App PAUSED - notifying socket service");
      SocketService().onAppPaused();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DeepDrift Secure',
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

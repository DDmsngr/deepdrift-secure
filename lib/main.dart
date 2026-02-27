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
  await Firebase.initializeApp();
  
  print("📲 Background message received: ${message.messageId}");
  
  final notification = FlutterLocalNotificationsPlugin();
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  await notification.initialize(const InitializationSettings(android: initializationSettingsAndroid));
  
  const AndroidNotificationDetails androidPlatformChannelSpecifics =
      AndroidNotificationDetails(
    'background_messages',
    'Background Messages',
    importance: Importance.max,
    priority: Priority.high,
    showWhen: true,
    color: Color(0xFF00D9FF),
    enableVibration: true,
    playSound: true,
  );
  
  await notification.show(
    message.hashCode,
    message.notification?.title ?? 'DDChat',
    message.notification?.body ?? 'New Message',
    const NotificationDetails(android: androidPlatformChannelSpecifics),
    payload: message.data['from_uid'],
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Инициализация Firebase
  await Firebase.initializeApp();
  
  FirebaseMessaging messaging = FirebaseMessaging.instance;

  // 🔥 ЛЕЧЕНИЕ ОШИБКИ "Requested entity was not found":
  // Мы удаляем старый токен, чтобы Firebase выдал новый, рабочий.
  try {
    await messaging.deleteToken(); 
    print("🗑️ Old FCM token deleted (Fixing push notifications)");
  } catch (e) {
    print("⚠️ Token delete error: $e");
  }
  
  // 2. Запрос разрешений
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
    
    // Твоя логика управления сокетами (ОСТАВЛЯЕМ КАК БЫЛО)
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

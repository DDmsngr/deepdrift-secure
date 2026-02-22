import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'home_screen.dart';
import 'notification_service.dart';
import 'socket_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ========================================
// КРИТИЧЕСКИ ВАЖНО: Фоновый обработчик
// ========================================
// Этот обработчик вызывается когда приложение ЗАКРЫТО
// и приходит push-уведомление
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Инициализируем Firebase для фонового режима
  await Firebase.initializeApp();
  
  print("📲 Background message received: ${message.messageId}");
  print("   From: ${message.data['from_uid']}");
  
  // Показываем локальное уведомление
  final notification = FlutterLocalNotificationsPlugin();
  
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  
  await notification.initialize(initializationSettings);
  
  // Показываем уведомление
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
  WidgetsFlutterBinding.ensureInitialized();
  
  // Инициализируем Firebase
  await Firebase.initializeApp();
  
  // ВАЖНО: Регистрируем фоновый обработчик ДО runApp
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  
  // Инициализируем Hive
  await Hive.initFlutter();
  
  // Инициализируем сервис уведомлений
  await NotificationService().init();
  
  runApp(const DeepDriftApp());
}

class DeepDriftApp extends StatefulWidget {
  const DeepDriftApp({super.key});

  @override
  State<DeepDriftApp> createState() => _DeepDriftAppState();
}

// ИСПРАВЛЕНИЕ: Добавлен мониторинг жизненного цикла приложения
class _DeepDriftAppState extends State<DeepDriftApp> with WidgetsBindingObserver {
  
  @override
  void initState() {
    super.initState();
    // Регистрируем наблюдателя жизненного цикла
    WidgetsBinding.instance.addObserver(this);
    print("🔄 Lifecycle observer registered");
  }

  @override
  void dispose() {
    // Удаляем наблюдателя при уничтожении виджета
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    print("🔄 App lifecycle changed: $state");
    
    switch (state) {
      case AppLifecycleState.resumed:
        // Приложение вернулось на передний план
        print("✅ App RESUMED - calling socket service");
        SocketService().onAppResumed();
        break;
        
      case AppLifecycleState.paused:
        // Приложение ушло в фон (но не закрыто)
        print("⏸️ App PAUSED - notifying socket service");
        SocketService().onAppPaused();
        break;
        
      case AppLifecycleState.inactive:
        // Приложение неактивно (например, входящий звонок)
        print("⏸️ App INACTIVE");
        break;
        
      case AppLifecycleState.detached:
        // Приложение полностью закрывается
        print("🛑 App DETACHED");
        break;
        
      case AppLifecycleState.hidden:
        // Приложение скрыто (новое в Flutter 3.13+)
        print("👻 App HIDDEN");
        break;
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

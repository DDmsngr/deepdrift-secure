import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_service.dart';
import 'socket_service.dart';
import 'splash_screen.dart';

// ── Фоновый обработчик FCM ────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();

  final plugin = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(const InitializationSettings(android: androidInit));

  final fromUid    = message.data['from_uid']    as String? ?? 'DDChat';
  final senderName = message.data['sender_name'] as String? ?? fromUid;
  final msgType    = message.data['type']        as String? ?? 'new_message';

  String bodyText = 'Новое зашифрованное сообщение';
  if (msgType == 'message_deleted') bodyText = '🚫 Сообщение удалено';
  if (msgType == 'message_edited')  bodyText = '✏️ Сообщение изменено';
  if (msgType == 'message_reaction') bodyText = '❤️ Новая реакция';

  await plugin.show(
    message.hashCode,
    senderName,
    bodyText,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();

  await FirebaseMessaging.instance.requestPermission(
    alert: true, badge: true, sound: true,
  );

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    SocketService().registerFcmToken(newToken);
  });

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
      home: const SplashScreen(),
    );
  }
}

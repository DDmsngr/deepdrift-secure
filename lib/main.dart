import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';

import 'notification_service.dart';
import 'storage_service.dart';
import 'lock_screen.dart';
import 'socket_service.dart';
import 'crypto_service.dart';
import 'providers/app_providers.dart';
import 'splash_screen.dart';

// ── Фоновый обработчик FCM (DATA-ONLY PUSH) ──────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('📲 Background FCM received (data-only): ${message.data}');

  // Так как мы убрали блок notification на сервере, 
  // ОС больше не показывает пуш сама. Мы рисуем его вручную.
  final plugin = FlutterLocalNotificationsPlugin();

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  // Если будешь собирать под iOS: const iosInit = DarwinInitializationSettings();
  await plugin.initialize(const InitializationSettings(android: androidInit));

  // Достаем данные из невидимого пуша
  final fromUid = message.data['from_uid'] as String? ?? 'DDChat';
  final senderName = message.data['sender_name'] as String? ?? fromUid;
  final msgType = message.data['type'] as String? ?? 'new_message';

  // Формируем безопасный текст
  String bodyText = "Новое зашифрованное сообщение";
  if (msgType == 'message_deleted') bodyText = "🚫 Сообщение удалено";
  if (msgType == 'message_edited') bodyText = "✏️ Сообщение изменено";
  if (msgType == 'message_reaction') bodyText = "❤️ Новая реакция";

  await plugin.show(
    message.hashCode,
    senderName, // Имя отправителя
    bodyText,   // Статичный безопасный текст
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'secure_messages_channel', // Новый ID канала, чтобы сбросить кэш настроек Android
        'Защищенные сообщения',
        importance:      Importance.max,
        priority:        Priority.high,
        showWhen:        true,
        color:           Color(0xFF00D9FF),
        enableVibration: true,
        playSound:       true,
      ),
    ),
    payload: fromUid, // Передаем UID друга, чтобы по клику открыть нужный чат
  );
}

// ─────────────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Firebase
  await Firebase.initializeApp();

  // 2. Запрос разрешений
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );

  // 3. Foreground-уведомления (чтобы пуши падали даже если приложение открыто)
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    // В открытом приложении мы не показываем системный пуш,
    // так как сообщения уже приходят по WebSocket и отрисовываются в UI.
    debugPrint('📩 Foreground FCM received: ${message.data}');
  });

  // 4. Фоновый обработчик FCM
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // 5. Обновление FCM-токена
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
    debugPrint('🔄 FCM token refreshed, re-registering...');
    SocketService().registerFcmToken(newToken);
  });

  // 6. Инициализация локального хранилища и сервисов
  await Hive.initFlutter();
  await NotificationService().init();

  // 7. Глобальный запрет скриншотов и записи экрана — постоянно включён
  if (Platform.isAndroid) {
    try {
      const channel = MethodChannel('com.deepdrift.secure/window');
      await channel.invokeMethod('addSecureFlag');
      debugPrint('🔒 FLAG_SECURE enabled globally');
    } catch (e) {
      debugPrint('FLAG_SECURE global error: $e');
    }
  }

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

  final _storage = StorageService();

  // true  → показываем LockScreen поверх всего
  bool _showLock = false;
  // Когда приложение ушло в фон — время фона. Нужно чтобы не блокировать
  // при кратких уходах (< 3 секунды), например при системном диалоге.
  DateTime? _pausedAt;
  static const _lockDelay = Duration(seconds: 3);

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
      case AppLifecycleState.paused:
        SocketService().onAppPaused();
        _pausedAt = DateTime.now();
        break;
      case AppLifecycleState.resumed:
        SocketService().onAppResumed();
        _checkLock();
        break;
      default:
        break;
    }
  }

  void _checkLock() {
    final lockEnabled = _storage.getSetting('app_lock_enabled', defaultValue: false) as bool;
    if (!lockEnabled) return;
    // Блокируем только если были в фоне дольше _lockDelay
    final pausedAt = _pausedAt;
    if (pausedAt == null) return;
    final inBackground = DateTime.now().difference(pausedAt);
    if (inBackground >= _lockDelay) {
      if (mounted) setState(() => _showLock = true);
    }
    _pausedAt = null;
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // SocketService и StorageService — синглтоны, оборачиваем как есть.
        // ChangeNotifierProvider создаёт и управляет жизненным циклом.
        ChangeNotifierProvider(create: (_) => SocketProvider()),
        ChangeNotifierProvider(create: (_) => StorageProvider()),
        // SecureCipher — один экземпляр на приложение, создаётся здесь.
        ChangeNotifierProvider(create: (_) => CipherProvider(SecureCipher())),
      ],
      child: MaterialApp(
        title: 'DDChat',
        debugShowCheckedModeBanner: false,

        // Позволяет навигировать к чату по тапу на уведомление
        navigatorKey: NotificationService.navigatorKey,
        builder: (context, child) {
          if (_showLock) {
            return LockScreen(
              storage: _storage,
              onUnlocked: () {
                if (mounted) setState(() => _showLock = false);
              },
            );
          }
          return child ?? const SizedBox.shrink();
        },

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
      ),
    );
  }
}

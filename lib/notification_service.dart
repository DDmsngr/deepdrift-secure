import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// NotificationService — управление FCM и локальными уведомлениями (Android).
//
// НАВИГАЦИЯ (🟡-2 FIX):
//
// Три сценария тапа по уведомлению:
//
//   1. Foreground tap (onDidReceiveNotificationResponse)
//      Приложение активно. Callback уже зарегистрирован HomeScreen'ом.
//      → _navigateToChat() вызывает callback немедленно.
//
//   2. Background tap (onMessageOpenedApp)
//      Приложение в фоне. Widget-дерево существует, но HomeScreen
//      может ещё не успеть перерегистрировать callback после resume.
//      → Пробуем callback, иначе — кэшируем в _pendingUid.
//
//   3. Cold start (getInitialMessage)
//      Приложение было убито. init() вызывается до runApp(), поэтому
//      NavigatorState ещё не существует.
//      → Обязательно кэшируем в _pendingUid; HomeScreen заберёт при
//        регистрации callback через setOpenChatCallback().
//
// КАК ПОДКЛЮЧИТЬ В HOMESCREEN:
//
//   @override
//   void initState() {
//     super.initState();
//     NotificationService().setOpenChatCallback((fromUid) {
//       // открыть ChatScreen с fromUid
//       _openChatWithUid(fromUid);
//     });
//   }
//
//   @override
//   void dispose() {
//     NotificationService().clearOpenChatCallback();
//     super.dispose();
//   }
//
// КАК ПОДКЛЮЧИТЬ NAVIGATORKEY В MAIN.DART:
//
//   MaterialApp(
//     navigatorKey: NotificationService.navigatorKey,
//     ...
//   )
// ─────────────────────────────────────────────────────────────────────────────

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static final navigatorKey = GlobalKey<NavigatorState>();

  final FirebaseMessaging              _fcm               = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  void Function(String fromUid)? _openChatCallback;
  void Function(String token)?   _onTokenRefreshed;
  void Function(Uri uri)?        _openChannelCallback;
  String? _pendingUid;

  // UID чата который сейчас открыт — не показываем пуш для него
  static String? activeChatUid;
  static void setActiveChat(String? uid) { activeChatUid = uid; }

  // ──────────────────────────────────────────────────────────────────────────
  // Публичный API для HomeScreen
  // ──────────────────────────────────────────────────────────────────────────

  /// Регистрирует callback навигации. Вызывать в HomeScreen.initState().
  /// Если к моменту вызова уже есть отложенный uid (cold start / background),
  /// callback выполняется немедленно.
  void setTokenRefreshCallback(void Function(String token) callback) {
    _onTokenRefreshed = callback;
  }

  void setOpenChannelCallback(void Function(Uri uri) callback) {
    _openChannelCallback = callback;
  }

  /// Обрабатывает deepdrift:// URI — вызывается из ChatScreen при тапе по ссылке.
  void handleDeepLink(Uri uri) {
    if (uri.host == 'channel' && _openChannelCallback != null) {
      _openChannelCallback!(uri);
    }
  }

  void setOpenChatCallback(void Function(String fromUid) callback) {
    _openChatCallback = callback;
    // Если был накоплен pending — выполняем сразу
    if (_pendingUid != null) {
      final uid = _pendingUid!;
      _pendingUid = null;
      // Даём фреймворку время завершить initState перед навигацией
      WidgetsBinding.instance.addPostFrameCallback((_) => callback(uid));
    }
  }

  /// Снимает callback при уходе HomeScreen из дерева.
  /// Вызывать в HomeScreen.dispose().
  void clearOpenChatCallback() {
    _openChatCallback = null;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Инициализация
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    // Запрос разрешений (Android 13+ требует явного запроса)
    await _fcm.requestPermission(alert: true, badge: true, sound: true);

    // ── Инициализация локальных уведомлений (Android only) ────────────────
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _localNotifications.initialize(
      initSettings,
      // Сценарий 1: foreground tap ─────────────────────────────────────────
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final fromUid = response.payload;
        debugPrint('📲 Notification tapped (foreground): $fromUid');
        if (fromUid != null && fromUid.isNotEmpty) {
          _navigateToChat(fromUid);
        }
      },
    );

    // ── Создаём канал уведомлений явно (Android 8+) ───────────────────────
    // Без этого на Android 8+ уведомления могут не отображаться.
    await _createNotificationChannel();

    // ── Сценарий foreground: приложение активно ───────────────────────────
    // При foreground Android НЕ показывает нативный баннер даже если есть notification-поле.
    // Показываем его сами через FlutterLocalNotifications.
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('📲 FCM foreground: ${message.messageId}');
      final targetUid = (message.data['target_uid'] as String? ?? '').isNotEmpty
          ? message.data['target_uid'] as String
          : message.data['from_uid'] as String? ?? '';
      if (targetUid.isNotEmpty) {
        showMessageNotification(
          fromUid:     targetUid,
          displayName: 'DDChat',
          messageText: 'Новое зашифрованное сообщение',
        );
      }
    });

    // ── Обновление FCM токена ─────────────────────────────────────────────
    // Firebase иногда ротирует токен — нужно обновить его на сервере.
    _fcm.onTokenRefresh.listen((newToken) {
      debugPrint('🔄 FCM token refreshed');
      _onTokenRefreshed?.call(newToken);
    });

    // ── Сценарий 2: background tap ────────────────────────────────────────
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      // target_uid = group_id для группы, from_uid для личного чата
      final targetUid = (message.data['target_uid'] as String? ?? '').isNotEmpty
          ? message.data['target_uid'] as String
          : message.data['from_uid'] as String? ?? '';
      debugPrint('📲 App opened from background notification: $targetUid');
      if (targetUid.isNotEmpty) {
        _navigateToChat(targetUid);
      }
    });

    // ── Сценарий 3: cold start ────────────────────────────────────────────
    // getInitialMessage() вызывается ДО runApp(), поэтому Navigator ещё
    // не существует. Обязательно кэшируем uid — выполним при регистрации
    // callback в HomeScreen.
    final initialMessage = await _fcm.getInitialMessage();
    if (initialMessage != null) {
      final targetUid = (initialMessage.data['target_uid'] as String? ?? '').isNotEmpty
          ? initialMessage.data['target_uid'] as String
          : initialMessage.data['from_uid'] as String? ?? '';
      debugPrint('📲 App launched from killed state by notification: $targetUid');
      if (targetUid.isNotEmpty) {
        // Всегда кэшируем при cold start — Navigator точно не готов
        _pendingUid = targetUid;
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Показ локального уведомления
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> showMessageNotification({
    required String fromUid,
    required String displayName,
    required String messageText,
  }) async {
    // Не показываем пуш если этот чат сейчас открыт на экране
    if (activeChatUid == fromUid) return;
    final androidDetails = AndroidNotificationDetails(
      'high_importance_channel',
      'DDChat Messages',
      channelDescription: 'Notifications for incoming chat messages',
      importance:       Importance.max,
      priority:         Priority.high,
      showWhen:         true,
      color:            const Color(0xFF00D9FF),
      enableVibration:  true,
      playSound:        true,
      ticker:           'New message',
      styleInformation: BigTextStyleInformation(
        messageText,
        contentTitle: displayName,
        summaryText:  'DDChat',
      ),
    );

    await _localNotifications.show(
      // Один ID на контакт — новое уведомление заменяет предыдущее
      // вместо создания стека уведомлений.
      fromUid.hashCode,
      displayName,
      messageText,
      NotificationDetails(android: androidDetails),
      payload: fromUid,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // FCM токен
  // ──────────────────────────────────────────────────────────────────────────

  Future<String?> getToken() async {
    try {
      return await _fcm.getToken();
    } catch (e) {
      debugPrint('FCM getToken error: $e');
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Приватные вспомогательные методы
  // ──────────────────────────────────────────────────────────────────────────

  /// Универсальный метод навигации к чату.
  /// Если callback зарегистрирован — вызывает его (HomeScreen обработает).
  /// Иначе кэширует uid для выполнения позже.
  void _navigateToChat(String fromUid) {
    if (_openChatCallback != null) {
      _openChatCallback!(fromUid);
    } else {
      // HomeScreen ещё не готов — сохраняем, выполним в setOpenChatCallback()
      _pendingUid = fromUid;
      debugPrint('📋 Navigation pending for uid: $fromUid (HomeScreen not ready)');
    }
  }

  /// Явно создаёт Android notification channel.
  /// На Android 8.0+ (API 26+) уведомления без канала не отображаются.
  Future<void> _createNotificationChannel() async {
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin == null) return;

    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'high_importance_channel',          // id — должен совпадать с id в show()
        'DDChat Messages',          // name — видно в настройках Android
        description: 'Notifications for incoming DDChat messages',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );

    // Отдельный канал для фоновых сообщений (из _firebaseMessagingBackgroundHandler)
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'high_importance_channel',
        'DDChat Messages',
        description: 'Silent notifications received while app is killed',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );
  }
}

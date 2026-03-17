import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:dio/dio.dart';
import 'storage_service.dart';
import 'crypto_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  static const String   PROTOCOL_VERSION      = '3.0';
  static const int      MAX_RECONNECT_ATTEMPTS = 50;
  static const Duration RECONNECT_BASE_DELAY   = Duration(seconds: 4);
  static const Duration PING_INTERVAL          = Duration(seconds: 10);
  static const Duration CONNECTION_TIMEOUT     = Duration(seconds: 20);
  // Если ACK не пришёл за 30 секунд — считаем доставку неуспешной и
  // освобождаем Completer, чтобы не было утечки памяти (🟡-6 FIX).
  static const Duration PENDING_MSG_TIMEOUT    = Duration(seconds: 30);

  static const String HTTP_UPLOAD_URL = 'https://deepdrift-backend.onrender.com/upload';

  WebSocketChannel? _channel;
  final _messageStream           = StreamController<Map<String, dynamic>>.broadcast();
  final _uploadProgressController = StreamController<double>.broadcast();

  Stream<double>                  get uploadProgress => _uploadProgressController.stream;
  Stream<Map<String, dynamic>>    get messages       => _messageStream.stream;

  // 🔴 Бонус-фикс: был `late SecureCipher _cipher` — LateInitializationError
  // если public_key_response придёт до вызова init(). Теперь nullable + guard.
  SecureCipher? _cipher;
  final _storage = StorageService();
  final Dio _dio = Dio();

  bool    _isConnected  = false;
  bool    _isConnecting = false;
  String? _url;
  String? _myUid;
  String? _authToken;

  Timer?    _reconnectTimer;
  Timer?    _pingTimer;
  Timer?    _connectionTimeoutTimer;

  int       _reconnectAttempts = 0;
  DateTime? _lastPongTime;

  // 🟡-6 FIX: Map хранит пару (Completer, Timer) — таймер отменяет
  // незавершённый Completer при обрыве до получения server_ack.
  final _pendingMessages = <String, _PendingAck>{};

  bool _isInBackground = false;

  // Очередь запросов офлайн-сообщений, накопившихся до uid_assigned.
  final _pendingOfflineRequests = <String>{};

  // Callbacks для аутентификации — устанавливаются из HomeScreen
  void Function(String reason)? onAuthFailed;   // auth_failed / uid_taken
  void Function()?              onAuthSuccess;  // uid_assigned после challenge

  // ──────────────────────────────────────────────────────────────────────────
  // Инициализация
  // ──────────────────────────────────────────────────────────────────────────

  void init(SecureCipher cipher) {
    _cipher = cipher;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // App lifecycle
  // ──────────────────────────────────────────────────────────────────────────

  void onAppResumed() {
    debugPrint('🔄 App resumed from background');
    _isInBackground = false;
    if (!_isConnected && _url != null && _myUid != null) {
      _reconnectAttempts = 0;
      _attemptConnection();
    }
  }

  void onAppPaused() {
    debugPrint('⏸️ App paused (background)');
    _isInBackground = true;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Подключение
  // ──────────────────────────────────────────────────────────────────────────

  void connect(String url, String myUid, {String? authToken}) {
    _url       = url;
    _myUid     = myUid;
    _authToken = authToken;
    _attemptConnection();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Загрузка файлов (незашифрованная — для случаев без E2E, например аватары)
  // ──────────────────────────────────────────────────────────────────────────

  Future<String?> uploadFile(File file) async {
    try {
      final fileName = file.path.split('/').last;
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path, filename: fileName),
      });
      _uploadProgressController.add(0.01);
      final response = await _dio.post(
        HTTP_UPLOAD_URL,
        data: formData,
        onSendProgress: (sent, total) {
          _uploadProgressController.add(sent / total);
        },
      );
      if (response.statusCode == 200 && response.data['status'] == 'success') {
        _uploadProgressController.add(1.0);
        Future.delayed(
          const Duration(milliseconds: 500),
          () => _uploadProgressController.add(0.0),
        );
        return response.data['file_id'] as String?;
      }
    } catch (e) {
      debugPrint('Upload Error: $e');
      _uploadProgressController.add(0.0);
    }
    return null;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Управление соединением
  // ──────────────────────────────────────────────────────────────────────────

  Duration _getReconnectDelay() {
    final base   = RECONNECT_BASE_DELAY.inSeconds;
    final exp    = min(base * pow(2, _reconnectAttempts), 60.0);
    final jitter = Random().nextDouble() * 0.3 * exp;
    return Duration(seconds: (exp + jitter).toInt());
  }

  void _attemptConnection() {
    if (_isConnected || _isConnecting) return;
    _isConnecting = true;

    _connectionTimeoutTimer?.cancel();
    _connectionTimeoutTimer = Timer(CONNECTION_TIMEOUT, () {
      if (!_isConnected && _isConnecting) {
        debugPrint('⏱️ Connection timeout');
        _isConnecting = false;
        _channel?.sink.close();
        _scheduleReconnect();
      }
    });

    try {
      _channel?.sink.close();
      debugPrint('🔌 Connecting to $_url...');
      _channel = WebSocketChannel.connect(Uri.parse(_url!));

      _sendRaw({
        'type':             'init',
        'my_uid':           _myUid,
        'protocol_version': PROTOCOL_VERSION,
        'auth_token':       _authToken,
      });

      _channel!.stream.listen(
        _handleIncomingMessage,
        onDone:  _handleDisconnect,
        onError: _handleError,
      );
    } catch (e) {
      debugPrint('❌ Connection error: $e');
      _isConnecting = false;
      _scheduleReconnect();
    }
  }

  void _handleIncomingMessage(dynamic raw) async {
    try {
      final data    = jsonDecode(raw as String) as Map<String, dynamic>;
      final msgType = data['type'] as String?;

      // ── auth_challenge: сервер проверяет личность ─────────────────────────
      // Клиент подписывает нонс приватным Ed25519-ключом и отвечает.
      if (msgType == 'auth_challenge') {
        final nonce = data['nonce'] as String?;
        if (nonce != null && _cipher != null) {
          try {
            final sig = await _cipher!.signChallenge(nonce);
            _sendRaw({
              'type':      'auth_response',
              'uid':       _myUid,
              'nonce':     nonce,
              'signature': sig,
            });
            debugPrint('🔑 Auth challenge signed and sent');
          } catch (e) {
            debugPrint('❌ Failed to sign challenge: $e');
          }
        }
        return;
      }

      // ── auth_failed / uid_taken ────────────────────────────────────────────
      if (msgType == 'auth_failed' || msgType == 'uid_taken') {
        final reason = data['reason'] as String? ?? msgType!;
        debugPrint('🚫 Auth failed: $reason');
        _isConnected  = false;
        _isConnecting = false;
        _channel?.sink.close();
        onAuthFailed?.call(reason);
        return;
      }

      // ── uid_assigned: соединение установлено ─────────────────────────────
      if (msgType == 'uid_assigned') {
        _connectionTimeoutTimer?.cancel();
        _isConnected       = true;
        _isConnecting      = false;
        _reconnectAttempts = 0;
        debugPrint('✅ Connected successfully');

        await _registerFcmToken();
        _startHeartbeat();

        _messageStream.add({'type': 'connection_status', 'connected': true});
        _messageStream.add(data);

        // Сбрасываем очередь офлайн-запросов
        if (_pendingOfflineRequests.isNotEmpty) {
          debugPrint('📬 Flushing ${_pendingOfflineRequests.length} pending offline requests');
          for (final uid in _pendingOfflineRequests) {
            _sendRaw({'type': 'request_offline_messages', 'target_uid': uid});
          }
          _pendingOfflineRequests.clear();
        }
        return;
      }

      // ── server_ack: подтверждение доставки ───────────────────────────────
      if (msgType == 'server_ack') {
        final messageId = data['id'] as String?;
        if (messageId != null) {
          final pending = _pendingMessages.remove(messageId);
          if (pending != null) {
            pending.timeoutTimer.cancel();
            if (!pending.completer.isCompleted) {
              pending.completer.complete(data['delivered_online'] as bool? ?? false);
            }
          }
        }
        return;
      }

      // ── pong: heartbeat ──────────────────────────────────────────────────
      if (msgType == 'pong') {
        _lastPongTime = DateTime.now();
        return;
      }

      // ── profile_response: кэшируем профиль контакта ──────────────────────
      if (msgType == 'profile_response') {
        final uid      = data['uid'] as String;
        final nickname = data['nickname'] as String? ?? '';

        // Не перезаписываем имя, если пользователь переименовал контакт вручную.
        // Условие: обновляем только если текущее имя == UID (не переименовывали)
        // или если с сервера пришло непустое имя, отличное от UID.
        final currentName = _storage.getContactDisplayName(uid);
        if (currentName == uid && nickname.isNotEmpty) {
          await _storage.setContactDisplayName(uid, nickname);
        } else if (currentName == uid && nickname.isEmpty) {
          // Оставляем UID как имя — не трогаем
        }
        // Если currentName != uid — пользователь переименовал, не трогаем

        if (data['avatar_id'] != null) {
          await _storage.setContactAvatar(uid, data['avatar_id'] as String);
        }
        await _storage.setContactStatus(
          uid,
          data['status'] == 'online',
          data['last_seen'] as int?,
        );
      }

      // ── user_status: обновляем online/last_seen ───────────────────────────
      if (msgType == 'user_status') {
        await _storage.setContactStatus(
          data['uid'] as String,
          data['status'] == 'online',
          data['last_seen'] as int?,
        );
      }

      // ── public_key_response: устанавливаем shared secret ─────────────────
      if (msgType == 'public_key_response') {
        final targetUid  = data['target_uid']  as String?;
        final x25519Key  = data['x25519_key']  as String?;
        final ed25519Key = data['ed25519_key'] as String?;

        // Бонус-фикс: guard на null — _cipher может быть не инициализирован
        if (_cipher != null && targetUid != null && x25519Key != null &&
            !data.containsKey('error')) {
          await _cipher!.establishSharedSecret(
            targetUid,
            x25519Key,
            theirSignKeyB64: ed25519Key,
          );
        }
      }

      _messageStream.add(data);
    } catch (e) {
      debugPrint('Socket parse error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // FCM
  // ──────────────────────────────────────────────────────────────────────────

  /// Регистрирует FCM-токен на сервере. Публичный — вызывается из main.dart
  /// при onTokenRefresh без пересоздания соединения.
  Future<void> registerFcmToken(String token) async {
    try {
      await _storage.saveSetting('fcm_token', token);
      if (_isConnected) {
        send({'type': 'register_fcm_token', 'fcm_token': token});
        debugPrint('📱 FCM token (re-)registered: ${token.substring(0, 10)}...');
      }
      // Если не подключены — токен сохранён в storage,
      // _registerFcmToken() отправит его при следующем uid_assigned.
    } catch (e) {
      debugPrint('FCM token registration error: $e');
    }
  }

  Future<void> _registerFcmToken() async {
    try {
      // Сначала пробуем сохранённый токен — не ждём Firebase
      String? token = _storage.getSetting('fcm_token');
      token ??= await FirebaseMessaging.instance.getToken();
      if (token != null) {
        send({'type': 'register_fcm_token', 'fcm_token': token});
        await _storage.saveSetting('fcm_token', token);
        debugPrint('📱 FCM token registered on connect');
      }
    } catch (e) {
      debugPrint('FCM error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Disconnect / Reconnect / Heartbeat
  // ──────────────────────────────────────────────────────────────────────────

  void _handleDisconnect() {
    debugPrint('🔌 WebSocket closed');
    _isConnected  = false;
    _isConnecting = false;
    _pingTimer?.cancel();
    _connectionTimeoutTimer?.cancel();

    // 🟡-6 FIX: при дисконнекте завершаем все висящие Completer'ы как false,
    // чтобы не держать ссылки на объекты вечно.
    _flushPendingMessages(deliveredOnline: false);

    _messageStream.add({'type': 'connection_status', 'connected': false});
    if (!_isInBackground) _scheduleReconnect();
  }

  void _handleError(Object error) {
    debugPrint('❌ WebSocket error: $error');
    _handleDisconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      _messageStream.add({'type': 'connection_failed'});
      return;
    }
    // Защита от шторма: если таймер уже запущен — не дублируем
    if (_reconnectTimer?.isActive == true) return;
    _reconnectTimer?.cancel();
    // Первая попытка через 3с — даём Render время
    final delay = _reconnectAttempts == 0
        ? const Duration(seconds: 3)
        : _getReconnectDelay();
    debugPrint('🔄 Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)...');
    _reconnectTimer = Timer(delay, () {
      _reconnectAttempts++;
      _attemptConnection();
    });
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _lastPongTime = DateTime.now();
    _pingTimer = Timer.periodic(PING_INTERVAL, (_) {
      if (!_isConnected) return;
      if (_lastPongTime != null) {
        final silence = DateTime.now().difference(_lastPongTime!);
        if (silence > PING_INTERVAL * 2) {
          debugPrint('⚠️ No pong received, reconnecting...');
          _handleDisconnect();
          return;
        }
      }
      send({'type': 'ping'});
    });
  }

  // 🟡-6 FIX: завершает все незакрытые Completer'ы и отменяет их таймеры.
  void _flushPendingMessages({required bool deliveredOnline}) {
    for (final entry in _pendingMessages.values) {
      entry.timeoutTimer.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.complete(deliveredOnline);
      }
    }
    _pendingMessages.clear();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Отправка
  // ──────────────────────────────────────────────────────────────────────────

  void _sendRaw(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('Send error: $e');
    }
  }

  void send(Map<String, dynamic> data) {
    if (!_isConnected) return;
    _sendRaw(data);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // API методы
  // ──────────────────────────────────────────────────────────────────────────

  void updateProfile(String nickname, String? avatarId) {
    send({'type': 'update_profile', 'nickname': nickname, 'avatar_id': avatarId});
  }

  void getProfile(String targetUid) {
    send({'type': 'get_profile', 'target_uid': targetUid});
  }

  void checkStatuses(List<String> uids) {
    if (uids.isEmpty) return;
    send({'type': 'check_statuses', 'uids': uids});
  }

  /// Запрашивает офлайн-очередь сообщений от [fromUid].
  /// Если соединение ещё не установлено — запрос ставится в очередь
  /// и отправляется автоматически после uid_assigned.
  void requestOfflineMessages(String fromUid) {
    if (_isConnected) {
      _sendRaw({'type': 'request_offline_messages', 'target_uid': fromUid});
      debugPrint('📬 Requested offline messages from $fromUid');
    } else {
      _pendingOfflineRequests.add(fromUid);
      debugPrint('📋 Queued offline request for $fromUid (not connected yet)');
    }
  }

  void registerPublicKeys(String xKey, String eKey) {
    send({
      'type':        'register_public_key',
      'x25519_key':  xKey,
      'ed25519_key': eKey,
    });
  }

  /// Регистрирует новый аккаунт на сервере.
  ///
  /// Вызывается один раз при первом запуске ПОСЛЕ инициализации ключей.
  /// Сервер связывает [uid] с [ed25519PubKey] и сохраняет в Redis.
  /// При следующих подключениях сервер отправит auth_challenge — клиент
  /// должен подписать нонс этим же ключом.
  /// Отправляет групповое сообщение — один раз, зашифрованное симметричным
  /// ключом группы. Сервер делает fan-out всем участникам.
  /// Отправляет групповое сообщение с ACK — аналогично sendMessage().
  /// Возвращает Future<bool>: true если хотя бы один участник был онлайн.
  Future<bool> sendGroupMessage({
    required String   groupId,
    required String   encryptedText,
    required String   signature,
    required String   msgId,
    String?  messageType,
    String?  mediaData,
    String?  fileName,
    int?     fileSize,
    String?  mimeType,
    String?  replyToId,
    int?     duration,
  }) {
    final completer    = Completer<bool>();
    final timeoutTimer = Timer(PENDING_MSG_TIMEOUT, () {
      if (_pendingMessages.containsKey(msgId)) {
        _pendingMessages.remove(msgId);
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    _pendingMessages[msgId] = _PendingAck(completer, timeoutTimer);

    final payload = <String, dynamic>{
      'type':           'message',
      'target_uid':     groupId,
      'id':             msgId,
      'encrypted_text': encryptedText,
      'signature':      signature,
      'messageType':    messageType ?? 'text',
      'group_id':       groupId,
      if (mediaData  != null) 'mediaData':  mediaData,
      if (fileName   != null) 'fileName':   fileName,
      if (fileSize   != null) 'fileSize':   fileSize,
      if (mimeType   != null) 'mimeType':   mimeType,
      if (replyToId  != null) 'replyToId':  replyToId,
      if (duration   != null) 'duration':   duration,
    };
    send(payload);
    return completer.future;
  }

  /// Запрашивает зашифрованный групповой ключ с сервера.
  void requestGroupKey(String groupId) {
    send({'type': 'get_group_key', 'group_id': groupId});
  }

  /// Отправляет зашифрованные копии группового ключа для каждого участника.
  /// Вызывается создателем группы после generate + encrypt.
  void distributeGroupKeys(String groupId, Map<String, String> encryptedKeys) {
    send({
      'type':           'distribute_group_keys',
      'group_id':       groupId,
      'encrypted_keys': encryptedKeys,  // {uid: encryptedKeyBlob}
    });
  }

  void registerNewAccount(String uid, String ed25519PubKey) {
    _sendRaw({
      'type':           'register',
      'uid':            uid,
      'ed25519_pubkey': ed25519PubKey,
      'protocol_version': PROTOCOL_VERSION,
    });
    debugPrint('📝 Registering new account: $uid');
  }

  void requestPublicKey(String targetUid) {
    send({'type': 'request_public_key', 'target_uid': targetUid});
  }

  /// Отправляет зашифрованное сообщение.
  ///
  /// Возвращает [Future<bool>] — true если получатель был онлайн и сервер
  /// подтвердил доставку через server_ack. Completer автоматически
  /// завершается с false через [PENDING_MSG_TIMEOUT], чтобы не было утечки.
  ///
  /// [forwardedFrom] — 🟡-1 FIX: отображаемое имя источника при пересылке.
  Future<bool> sendMessage(
    String targetUid,
    String encText,
    String sign,
    String msgId, {
    String? replyToId,
    String  messageType    = 'text',
    String? mediaData,
    String? fileName,
    int?    fileSize,
    String? mimeType,
    String? forwardedFrom,
    int?    duration,
    int?    messageTtl,
  }) {
    final completer = Completer<bool>();
    final timeoutTimer = Timer(PENDING_MSG_TIMEOUT, () {
      if (_pendingMessages.containsKey(msgId)) {
        _pendingMessages.remove(msgId);
        if (!completer.isCompleted) completer.complete(false);
        debugPrint('⏱️ ACK timeout for message $msgId');
      }
    });
    _pendingMessages[msgId] = _PendingAck(completer, timeoutTimer);

    send({
      'type':           'message',
      'id':             msgId,
      'target_uid':     targetUid,
      'encrypted_text': encText,
      'signature':      sign,
      'replyToId':      replyToId,
      'messageType':    messageType,
      'mediaData':      mediaData,
      'fileName':       fileName,
      'fileSize':       fileSize,
      'mimeType':       mimeType,
      if (forwardedFrom != null) 'forwarded_from': forwardedFrom,
      if (duration != null) 'duration': duration,
      if (messageTtl != null && messageTtl > 0) 'message_ttl': messageTtl,
    });

    return completer.future;
  }

  void sendTypingIndicator(String targetUid, bool isTyping) {
    send({'type': 'typing_indicator', 'target_uid': targetUid, 'typing': isTyping});
  }

  void sendDeleteMessage(String targetUid, String msgId) {
    send({'type': 'delete_message', 'target_uid': targetUid, 'message_id': msgId});
  }

  void sendEditMessage(
    String targetUid,
    String msgId,
    String newEncryptedText,
    String newSignature,
  ) {
    send({
      'type':               'edit_message',
      'target_uid':         targetUid,
      'message_id':         msgId,
      'new_encrypted_text': newEncryptedText,
      'new_signature':      newSignature,
    });
  }

  void sendReaction(String targetUid, String msgId, String emoji, String action) {
    send({
      'type':       'message_reaction',
      'target_uid': targetUid,
      'message_id': msgId,
      'emoji':      emoji,
      'action':     action,
    });
  }

  void sendReadReceipt(String targetUid, String msgId) {
    send({'type': 'read_receipt', 'target_uid': targetUid, 'message_id': msgId});
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Channels API
  // ──────────────────────────────────────────────────────────────────────────

  /// Создаёт новый канал. Сервер уведомляет подписчиков событием channel_created.
  void createChannel(String channelId, String channelName) {
    send({
      'type':         'create_channel',
      'channel_id':   channelId,
      'channel_name': channelName,
    });
    debugPrint('📢 Creating channel: $channelId ($channelName)');
  }

  /// Подписывается на существующий канал.
  void joinChannel(String channelId) {
    send({'type': 'join_channel', 'channel_id': channelId});
    debugPrint('📢 Joining channel: $channelId');
  }

  /// Отписывается от канала.
  void leaveChannel(String channelId) {
    send({'type': 'leave_channel', 'channel_id': channelId});
    debugPrint('📢 Leaving channel: $channelId');
  }

  /// Обновляет настройки группы (напр. ограничение "только admins могут писать").
  void updateGroupSettings(String groupId, {bool? onlyAdminsCanPost}) {
    send({
      'type':                 'update_group_settings',
      'group_id':             groupId,
      if (onlyAdminsCanPost != null)
        'only_admins_can_post': onlyAdminsCanPost,
    });
  }

  /// Поиск каналов по запросу. Ответ приходит как channel_search_results.
  void searchChannels(String query) {
    send({'type': 'search_channels', 'query': query});
  }

  /// Отправляет сообщение в канал. Только владелец может публиковать.
  void sendChannelMessage(String channelId, String text, String msgId) {
    send({
      'type':       'channel_message',
      'channel_id': channelId,
      'text':       text,
      'id':         msgId,
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Публичные геттеры
  // ──────────────────────────────────────────────────────────────────────────

  bool get isConnected       => _isConnected;
  int  get reconnectAttempts => _reconnectAttempts;

  void forceReconnect() {
    // Защита: если уже устанавливаем соединение — не запускаем второе
    if (_isConnecting) return;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _connectionTimeoutTimer?.cancel();
    _isConnected  = false;
    _isConnecting = false;
    // 300мс задержка: даём onDone обработаться раньше чем запустим новое соединение
    _channel?.sink.close();
    Future.delayed(const Duration(milliseconds: 300), _attemptConnection);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Блокировка
  // ──────────────────────────────────────────────────────────────────────────

  void blockUser(String targetUid)   => send({'type': 'block_user',   'target_uid': targetUid});
  void unblockUser(String targetUid) => send({'type': 'unblock_user', 'target_uid': targetUid});
  void getBlockedList()              => send({'type': 'get_blocked_list'});

  // ──────────────────────────────────────────────────────────────────────────
  // Stories / Статусы
  // ──────────────────────────────────────────────────────────────────────────

  void postStory({
    required String storyType,
    String text = '',
    String mediaId = '',
    String bgColor = '#1A1F3C',
  }) => send({
    'type':       'post_story',
    'story_type': storyType,
    'text':       text,
    'media_id':   mediaId,
    'bg_color':   bgColor,
  });

  void getStories(List<String> contactUids) => send({
    'type':     'get_stories',
    'contacts': contactUids,
  });

  void viewStory(String storyId) => send({
    'type':     'view_story',
    'story_id': storyId,
  });

  void deleteStory(String storyId) => send({
    'type':     'delete_story',
    'story_id': storyId,
  });

  void reactStory(String storyId, String emoji) => send({
    'type':     'react_story',
    'story_id': storyId,
    'emoji':    emoji,
  });

  // ──────────────────────────────────────────────────────────────────────────
  // Dispose (вызывать при завершении работы приложения)
  // ──────────────────────────────────────────────────────────────────────────

  void dispose() {
    _flushPendingMessages(deliveredOnline: false);
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _connectionTimeoutTimer?.cancel();
    _channel?.sink.close();
    _messageStream.close();
    _uploadProgressController.close();
  }
}

// ─── Вспомогательный класс для pending ACK ───────────────────────────────────

/// Хранит Completer и таймаут для одного неподтверждённого сообщения.
/// При получении server_ack или дисконнекте — таймаут отменяется,
/// Completer завершается.
class _PendingAck {
  final Completer<bool> completer;
  final Timer           timeoutTimer;
  const _PendingAck(this.completer, this.timeoutTimer);
}

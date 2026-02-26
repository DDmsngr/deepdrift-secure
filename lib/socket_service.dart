import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:dio/dio.dart'; // Используется для загрузки файлов
import 'storage_service.dart';
import 'crypto_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  static const String PROTOCOL_VERSION = "3.0";
  static const int MAX_RECONNECT_ATTEMPTS = 50; // Увеличили надежность
  static const Duration RECONNECT_BASE_DELAY = Duration(seconds: 2);
  static const Duration PING_INTERVAL = Duration(seconds: 10); // Быстрый пинг
  static const Duration CONNECTION_TIMEOUT = Duration(seconds: 5);
  static const String HTTP_UPLOAD_URL = 'https://deepdrift-backend.onrender.com/upload';

  WebSocketChannel? _channel;
  final _messageStream = StreamController<Map<String, dynamic>>.broadcast();
  
  // Стрим прогресса загрузки (0.0 -> 1.0)
  final _uploadProgressController = StreamController<double>.broadcast();
  Stream<double> get uploadProgress => _uploadProgressController.stream;

  Stream<Map<String, dynamic>> get messages => _messageStream.stream;

  late SecureCipher _cipher;
  final _storage = StorageService();
  final Dio _dio = Dio();
  
  bool _isConnected = false;
  bool _isConnecting = false;
  String? _url;
  String? _myUid;
  String? _authToken;
  
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _connectionTimeoutTimer;
  
  int _reconnectAttempts = 0;
  DateTime? _lastPongTime;
  
  final _pendingMessages = <String, Completer<bool>>{};
  bool _isInBackground = false;

  void init(SecureCipher cipher) {
    _cipher = cipher;
  }

  void onAppResumed() {
    print("🔄 App resumed from background");
    _isInBackground = false;
    if (!_isConnected && _url != null && _myUid != null) {
      _reconnectAttempts = 0;
      _attemptConnection();
    }
  }

  void onAppPaused() {
    print("⏸️ App paused (background)");
    _isInBackground = true;
    // Можно закрыть сокет для экономии батареи, сервер пошлет пуш
    // _channel?.sink.close(); 
    // Но для "быстрого возврата" лучше оставить, пусть отвалится по пингу
  }

  void connect(String url, String myUid, {String? authToken}) {
    _url = url;
    _myUid = myUid;
    _authToken = authToken;
    _attemptConnection();
  }

  // ─── ЗАГРУЗКА ФАЙЛОВ (DIO) ────────────────────────────────────────────────
  Future<String?> uploadFile(File file) async {
    try {
      String fileName = file.path.split('/').last;
      FormData formData = FormData.fromMap({
        "file": await MultipartFile.fromFile(file.path, filename: fileName),
      });

      // Сообщаем UI о начале
      _uploadProgressController.add(0.01);

      var response = await _dio.post(
        HTTP_UPLOAD_URL,
        data: formData,
        onSendProgress: (sent, total) {
          double progress = sent / total;
          _uploadProgressController.add(progress);
        },
      );

      if (response.statusCode == 200 && response.data['status'] == 'success') {
        _uploadProgressController.add(1.0); // Завершено
        // Сброс через полсекунды
        Future.delayed(const Duration(milliseconds: 500), () {
            _uploadProgressController.add(0.0);
        });
        return response.data['file_id'];
      }
    } catch (e) {
      print("Upload Error: $e");
      _uploadProgressController.add(0.0);
    }
    return null;
  }

  // ─── УПРАВЛЕНИЕ СОЕДИНЕНИЕМ ───────────────────────────────────────────────

  Duration _getReconnectDelay() {
    final baseSeconds = RECONNECT_BASE_DELAY.inSeconds;
    final exponential = min(baseSeconds * pow(2, _reconnectAttempts), 60.0);
    final jitter = Random().nextDouble() * 0.3 * exponential;
    return Duration(seconds: (exponential + jitter).toInt());
  }

  void _attemptConnection() {
    if (_isConnected || _isConnecting) return;
    _isConnecting = true;
    
    _connectionTimeoutTimer?.cancel();
    _connectionTimeoutTimer = Timer(CONNECTION_TIMEOUT, () {
      if (!_isConnected && _isConnecting) {
        print("⏱️ Connection timeout");
        _isConnecting = false;
        _channel?.sink.close();
        _scheduleReconnect();
      }
    });
    
    try {
      _channel?.sink.close();
      print("🔌 Connecting to $_url...");
      _channel = WebSocketChannel.connect(Uri.parse(_url!));
      
      _sendRaw({
        "type": "init",
        "my_uid": _myUid,
        "protocol_version": PROTOCOL_VERSION,
        "auth_token": _authToken,
      });

      _channel!.stream.listen(
        _handleIncomingMessage,
        onDone: _handleDisconnect,
        onError: _handleError,
      );
    } catch (e) {
      print("❌ Connection error: $e");
      _isConnecting = false;
      _scheduleReconnect();
    }
  }

  void _handleIncomingMessage(dynamic raw) async {
    try {
      final data = jsonDecode(raw);
      final msgType = data['type'];
      
      // Инициализация успешна
      if (msgType == 'uid_assigned') {
        _connectionTimeoutTimer?.cancel();
        _isConnected = true;
        _isConnecting = false;
        _reconnectAttempts = 0;
        print("✅ Connected successfully");
        
        await _registerFcmToken();
        _startHeartbeat();
        
        _messageStream.add({"type": "connection_status", "connected": true});
        _messageStream.add(data);
        return;
      }
      
      // Подтверждение от сервера
      if (msgType == 'server_ack') {
        final messageId = data['id'];
        _pendingMessages[messageId]?.complete(data['delivered_online'] ?? false);
        _pendingMessages.remove(messageId);
        return;
      }
      
      // Понг
      if (msgType == 'pong') {
        _lastPongTime = DateTime.now();
        return;
      }

      // Ответ с профилем
      if (msgType == 'profile_response') {
        await _storage.setContactDisplayName(data['uid'], data['nickname']);
        if (data['avatar_id'] != null) {
          await _storage.setContactAvatar(data['uid'], data['avatar_id']);
        }
        await _storage.setContactStatus(data['uid'], data['status'] == 'online', data['last_seen']);
      }

      // Обновление статуса
      if (msgType == 'user_status') {
        await _storage.setContactStatus(data['uid'], data['status'] == 'online', data['last_seen']);
      }
      
      // Обмен ключами
      if (msgType == 'public_key_response') {
        final targetUid = data['target_uid'];
        final x25519Key = data['x25519_key'];
        final ed25519Key = data['ed25519_key'];
        
        if (targetUid != null && x25519Key != null && !data.containsKey('error')) {
          await _cipher.establishSharedSecret(
            targetUid, 
            x25519Key, 
            theirSignKeyB64: ed25519Key
          );
        }
      }
      
      // Пробрасываем сообщение дальше в UI
      _messageStream.add(data);
      
    } catch (e) {
      print("Socket parse error: $e");
    }
  }

  Future<void> _registerFcmToken() async {
    try {
      final fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        send({
          "type": "register_fcm_token",
          "fcm_token": fcmToken
        });
        await _storage.saveSetting('fcm_token', fcmToken);
      }
    } catch (e) {
      print("FCM error: $e");
    }
  }

  void _handleDisconnect() {
    print("🔌 WebSocket closed");
    _isConnected = false;
    _isConnecting = false;
    _pingTimer?.cancel();
    _connectionTimeoutTimer?.cancel();
    _messageStream.add({"type": "connection_status", "connected": false});
    
    if (!_isInBackground) {
      _scheduleReconnect();
    }
  }

  void _handleError(error) {
    print("❌ WebSocket error: $error");
    _handleDisconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      _messageStream.add({"type": "connection_failed"});
      return;
    }

    _reconnectTimer?.cancel();
    final delay = _getReconnectDelay();
    print("🔄 Reconnecting in ${delay.inSeconds}s...");
    
    _reconnectTimer = Timer(delay, () {
      _reconnectAttempts++;
      _attemptConnection();
    });
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _lastPongTime = DateTime.now();
    
    _pingTimer = Timer.periodic(PING_INTERVAL, (_) {
      if (_isConnected) {
        // Проверяем, не умер ли сервер
        if (_lastPongTime != null) {
          final timeSinceLastPong = DateTime.now().difference(_lastPongTime!);
          if (timeSinceLastPong > PING_INTERVAL * 2) {
            print("⚠️ No pong, reconnecting...");
            _handleDisconnect();
            return;
          }
        }
        send({"type": "ping"});
      }
    });
  }

  void _sendRaw(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      print("Send error: $e");
    }
  }

  void send(Map<String, dynamic> data) {
    if (!_isConnected) return;
    _sendRaw(data);
  }

  // ─── API МЕТОДЫ ──────────────────────────────────────────────────────────

  // Профили
  void updateProfile(String nickname, String? avatarId) {
    send({
      "type": "update_profile",
      "nickname": nickname,
      "avatar_id": avatarId
    });
  }

  void getProfile(String targetUid) {
    send({
      "type": "get_profile",
      "target_uid": targetUid
    });
  }

  void checkStatuses(List<String> uids) {
    if (uids.isEmpty) return;
    send({
      "type": "check_statuses",
      "uids": uids
    });
  }

  // Оффлайн сообщения
  void requestOfflineMessages(String fromUid) {
    if (!_isConnected) return;
    send({
      'type': 'request_offline_messages',
      'from_uid': fromUid,
    });
    print('📬 Requested offline messages from $fromUid');
  }

  // Ключи
  void registerPublicKeys(String xKey, String eKey) {
    send({
      "type": "register_public_key", 
      "x25519_key": xKey, 
      "ed25519_key": eKey
    });
  }

  void requestPublicKey(String targetUid) {
    send({
      "type": "request_public_key", 
      "target_uid": targetUid
    });
  }

  // Сообщения
  void sendMessage(String targetUid, String encText, String sign, String msgId, 
      {String? replyToId, String messageType='text', String? mediaData, 
       String? fileName, int? fileSize, String? mimeType}) {
    send({
      "type": "message",
      "id": msgId,
      "target_uid": targetUid,
      "encrypted_text": encText,
      "signature": sign,
      "replyToId": replyToId,
      "messageType": messageType,
      "mediaData": mediaData,
      "fileName": fileName,
      "fileSize": fileSize,
      "mimeType": mimeType
    });
  }

  void sendTypingIndicator(String targetUid, bool isTyping) {
    send({
      "type": "typing_indicator",
      "target_uid": targetUid,
      "typing": isTyping
    });
  }

  void sendDeleteMessage(String targetUid, String msgId) {
    send({
      "type": "delete_message",
      "target_uid": targetUid,
      "message_id": msgId
    });
  }

  void sendEditMessage(String targetUid, String msgId, String newText, String newSign) {
    send({
      "type": "edit_message",
      "target_uid": targetUid,
      "message_id": msgId,
      "new_encrypted_text": newText,
      "new_signature": newSign
    });
  }

  void sendReaction(String targetUid, String msgId, String emoji, String action) {
    send({
      "type": "message_reaction",
      "target_uid": targetUid,
      "message_id": msgId,
      "emoji": emoji,
      "action": action
    });
  }

  void sendReadReceipt(String targetUid, String msgId) {
    send({
      "type": "read_receipt",
      "target_uid": targetUid,
      "message_id": msgId
    });
  }

  bool get isConnected => _isConnected;
  int get reconnectAttempts => _reconnectAttempts;

  void forceReconnect() {
    _reconnectAttempts = 0;
    _channel?.sink.close();
    _attemptConnection();
  }
}

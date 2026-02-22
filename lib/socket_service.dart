import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'storage_service.dart';
import 'crypto_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Сервис для управления WebSocket подключением
/// РАСШИРЕНО: Добавлены методы для удаления, редактирования, реакций, пересылки
class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  static const String PROTOCOL_VERSION = "3.0"; // Обновили версию протокола
  static const int MAX_RECONNECT_ATTEMPTS = 10;
  static const Duration RECONNECT_BASE_DELAY = Duration(seconds: 2);
  static const Duration PING_INTERVAL = Duration(seconds: 30);
  static const Duration CONNECTION_TIMEOUT = Duration(seconds: 10);

  WebSocketChannel? _channel;
  final _messageStream = StreamController<Map<String, dynamic>>.broadcast();
  
  // Публичный геттер для stream (вместо прямого доступа к _uiStream)
  Stream<Map<String, dynamic>> get messages => _messageStream.stream;

  late SecureCipher _cipher;
  final _storage = StorageService();
  
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
      print("🔌 Reconnecting after app resume...");
      _reconnectAttempts = 0;
      _attemptConnection();
    }
  }

  void onAppPaused() {
    print("⏸️ App paused (going to background)");
    _isInBackground = true;
  }

  void connect(String url, String myUid, {String? authToken}) {
    _url = url;
    _myUid = myUid;
    _authToken = authToken;
    _attemptConnection();
  }

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
      
      print("🔌 Connecting to $_url (attempt ${_reconnectAttempts + 1}/$MAX_RECONNECT_ATTEMPTS)");
      
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
      
      print("📥 Received: $msgType");
      
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
      
      if (msgType == 'auth_token') {
        _authToken = data['token'];
        await _storage.saveSetting('auth_token', _authToken);
        print("🔑 New auth token received");
        return;
      }
      
      if (msgType == 'fcm_token_registered') {
        print("📲 FCM token registered on server");
        return;
      }
      
      if (msgType == 'pong') {
        _lastPongTime = DateTime.now();
        return;
      }
      
      if (msgType == 'server_ack') {
        final messageId = data['id'];
        print("✅ Server ACK for message: $messageId");
        _pendingMessages[messageId]?.complete(data['delivered_online'] ?? false);
        _pendingMessages.remove(messageId);
        return;
      }
      
      if (msgType == 'error') {
        print("⚠️ Server error: ${data['message']}");
        _messageStream.add({
          "type": "server_error",
          "message": data['message']
        });
        return;
      }
      
      if (msgType == 'public_key_registered') {
        print("✅ Public keys registered on server");
        _messageStream.add(data);
        return;
      }
      
      if (msgType == 'public_key_response') {
        final targetUid = data['target_uid'];
        final x25519Key = data['x25519_key'];
        final ed25519Key = data['ed25519_key'];
        
        print("📥 Received public key for $targetUid");
        
        if (targetUid != null && x25519Key != null && !data.containsKey('error')) {
          try {
            await _cipher.establishSharedSecret(
              targetUid,
              x25519Key,
              theirSignKeyB64: ed25519Key,
            );
            print("✅ Auto-established shared secret with $targetUid");
          } catch (e) {
            print("⚠️ Failed to auto-establish shared secret with $targetUid: $e");
          }
        }
        
        _messageStream.add(data);
        return;
      }
      
      // Пробрасываем все остальные события в stream
      _messageStream.add(data);
      
    } catch (e) {
      print("❌ Failed to process message: $e");
    }
  }

  Future<void> _registerFcmToken() async {
    try {
      final fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        print("📲 Got FCM token: ${fcmToken.substring(0, 20)}...");
        
        send({
          "type": "register_fcm_token",
          "fcm_token": fcmToken
        });
        
        await _storage.saveSetting('fcm_token', fcmToken);
      } else {
        print("⚠️ Failed to get FCM token");
      }
    } catch (e) {
      print("❌ Error getting FCM token: $e");
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
    } else {
      print("📵 App in background, skipping auto-reconnect");
    }
  }

  void _handleError(error) {
    print("❌ WebSocket error: $error");
    _isConnected = false;
    _isConnecting = false;
    _pingTimer?.cancel();
    
    _messageStream.add({"type": "connection_status", "connected": false});
    
    if (!_isInBackground) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      print("❌ Max reconnection attempts reached");
      _messageStream.add({
        "type": "connection_failed",
        "message": "Could not connect to server after $MAX_RECONNECT_ATTEMPTS attempts"
      });
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
        if (_lastPongTime != null) {
          final timeSinceLastPong = DateTime.now().difference(_lastPongTime!);
          if (timeSinceLastPong > PING_INTERVAL * 2) {
            print("⚠️ No pong received, connection might be dead");
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
      final json = jsonEncode(data);
      print("📤 Sending: ${data['type']}");
      _channel?.sink.add(json);
    } catch (e) {
      print("❌ Failed to send raw message: $e");
    }
  }

  void send(Map<String, dynamic> data) {
    if (!_isConnected) {
      print("⚠️ Cannot send message - not connected");
      return;
    }
    _sendRaw(data);
  }

  // ==================== БАЗОВЫЕ МЕТОДЫ ====================

  void registerPublicKeys(String x25519Key, String ed25519Key) {
    print("🔑 [CLIENT] Registering public keys on server...");
    
    send({
      "type": "register_public_key",
      "x25519_key": x25519Key,
      "ed25519_key": ed25519Key,
    });
    
    print("✅ [CLIENT] Public key registration message sent");
  }

  void requestPublicKey(String targetUid) {
    send({
      "type": "request_public_key",
      "target_uid": targetUid,
    });
  }

  void sendMessage(
    String targetUid,
    String encryptedText,
    String signature,
    String messageId, {
    String? replyToId,
    String messageType = 'text',
    String? mediaData,
    String? fileName,
    int?    fileSize,
    String? mimeType,
  }) {
    send({
      "type":           "message",
      "id":             messageId,
      "target_uid":     targetUid,
      "encrypted_text": encryptedText,
      "signature":      signature,
      "replyToId":      replyToId,
      "messageType":    messageType,
      "mediaData":      mediaData,
      "fileName":       fileName,
      "fileSize":       fileSize,
      "mimeType":       mimeType,
    });
  }

  void sendTypingIndicator(String targetUid, bool isTyping) {
    send({
      "type": "typing_indicator",
      "target_uid": targetUid,
      "typing": isTyping
    });
  }

  // ==================== НОВЫЕ МЕТОДЫ ====================

  /// 1. Удаление сообщения
  void sendDeleteMessage(String targetUid, String messageId) {
    print("🗑️ Deleting message: $messageId");
    send({
      "type": "delete_message",
      "target_uid": targetUid,
      "message_id": messageId,
    });
  }

  /// 2. Редактирование сообщения
  void sendEditMessage(
    String targetUid,
    String messageId,
    String newEncryptedText,
    String newSignature,
  ) {
    print("✏️ Editing message: $messageId");
    send({
      "type": "edit_message",
      "target_uid": targetUid,
      "message_id": messageId,
      "new_encrypted_text": newEncryptedText,
      "new_signature": newSignature,
    });
  }

  /// 3. Реакция на сообщение
  void sendReaction(
    String targetUid,
    String messageId,
    String emoji,
    String action, // 'add' or 'remove'
  ) {
    print("$emoji Reaction: $emoji on $messageId ($action)");
    send({
      "type": "message_reaction",
      "target_uid": targetUid,
      "message_id": messageId,
      "emoji": emoji,
      "action": action,
    });
  }

  /// 4. Пересылка сообщения
  void sendForwardMessage(
    String targetUid,
    String originalMessageId,
    String forwardedFromUid,
    String encryptedText,
    String signature,
    String newMessageId,
  ) {
    print("↪️ Forwarding message: $originalMessageId to $targetUid");
    send({
      "type": "forward_message",
      "id": newMessageId,
      "target_uid": targetUid,
      "original_message_id": originalMessageId,
      "forwarded_from": forwardedFromUid,
      "encrypted_text": encryptedText,
      "signature": signature,
    });
  }

  /// 5. Read Receipt (подтверждение прочтения)
  void sendReadReceipt(String targetUid, String messageId) {
    print("✓✓ Sending read receipt for: $messageId");
    send({
      "type": "read_receipt",
      "target_uid": targetUid,
      "message_id": messageId,
    });
  }

  /// 6. Delivery Receipt (подтверждение доставки)
  void sendDeliveryReceipt(String targetUid, String messageId) {
    print("✓ Sending delivery receipt for: $messageId");
    send({
      "type": "delivery_receipt",
      "target_uid": targetUid,
      "message_id": messageId,
    });
  }

  // ==================== ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ ====================

  Future<bool> sendMessageWithAck(
    String targetUid,
    String messageId,
    String encryptedPayload,
    String signature,
  ) async {
    if (!_isConnected) {
      print("⚠️ Cannot send - not connected");
      return false;
    }

    final completer = Completer<bool>();
    _pendingMessages[messageId] = completer;

    send({
      "type": "message",
      "id": messageId,
      "target_uid": targetUid,
      "encrypted_payload": encryptedPayload,
      "signature": signature
    });

    print("⏳ Waiting for ACK for message: $messageId");

    Timer(const Duration(seconds: 3), () {
      if (!completer.isCompleted) {
        print("⚠️ ACK timeout for message: $messageId");
        _pendingMessages.remove(messageId);
        completer.complete(true);
      }
    });

    return completer.future;
  }

  void markAsRead(String fromUid, String messageId) {
    sendReadReceipt(fromUid, messageId);
  }

  bool get isConnected => _isConnected;
  int get reconnectAttempts => _reconnectAttempts;

  void forceReconnect() {
    _reconnectAttempts = 0;
    _channel?.sink.close();
    _attemptConnection();
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _connectionTimeoutTimer?.cancel();
    _channel?.sink.close();
    _messageStream.close();
    _pendingMessages.clear();
  }
}

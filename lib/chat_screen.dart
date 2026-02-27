import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';

import 'crypto_service.dart';
import 'socket_service.dart';
import 'storage_service.dart';

// ─── Типы сообщений ──────────────────────────────────────────────────────────
enum MsgType { text, image, voice, file, video_note }

extension MsgTypeStr on String {
  MsgType toMsgType() {
    switch (this) {
      case 'image':      return MsgType.image;
      case 'voice':      return MsgType.voice;
      case 'file':       return MsgType.file;
      case 'video_note': return MsgType.video_note;
      default:           return MsgType.text;
    }
  }
}

// ─── Статус верификации подписи ───────────────────────────────────────────────
// Три состояния: ключ контакта ещё не загружен (unknown), подпись верна (valid),
// подпись отсутствует или не совпадает (invalid).
enum SignatureStatus { unknown, valid, invalid }

// ─── Виджет ──────────────────────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  final String myUid;
  final String targetUid;
  final SecureCipher cipher;

  const ChatScreen({
    super.key,
    required this.myUid,
    required this.targetUid,
    required this.cipher,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const String SERVER_HTTP_URL = 'https://deepdrift-backend.onrender.com';

  final List<Map<String, dynamic>> _messages = [];
  final Set<String> _messageIds = {};
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final _socket  = SocketService();
  final _storage = StorageService();
  final _uuid    = const Uuid();
  final _imagePicker   = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer   = AudioPlayer();
  final _dio = Dio();

  StreamSubscription? _socketSub;

  bool   _isTyping = false;
  Timer? _typingTimer;
  bool   _targetIsTyping = false;

  bool _isLoadingMore    = false;
  bool _hasMoreMessages  = true;

  String? _replyToText;
  String? _replyToId;

  bool   _keysExchanged = false;
  Timer? _keyExchangeTimeout;

  bool _isSearching = false;

  bool    _isRecording     = false;
  String? _voiceTempPath;
  Timer?  _recordingTimer;
  int     _recordingDuration = 0;

  bool              _isMicMode       = true;
  bool              _isVideoRecording = false;
  CameraController? _cameraController;

  String?                    _editingMessageId;
  Map<String, Set<String>>   _reactions = {};
  String?                    _playingMessageId;

  bool   _isSendingFile  = false;
  double _uploadProgress = 0.0;

  static const int      MESSAGES_PER_PAGE    = 50;
  static const Duration KEY_EXCHANGE_TIMEOUT = Duration(seconds: 5);

  // ──────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _messageController.addListener(_onTextChanged);
    _scrollController.addListener(_onScroll);
    _initializeSecureChat();
    _loadRecentHistory().then((_) {
      _markAllAsRead();
      _scrollToBottom(animated: false);
      widget.cipher.tryLoadCachedKeys(widget.targetUid, _storage).then((loaded) {
        if (loaded && mounted) setState(() => _keysExchanged = true);
      });
    });
    _listenToMessages();
    _reactions = _storage.loadReactions(widget.targetUid);
    Future.delayed(const Duration(milliseconds: 500), () {
      try {
        _socket.getProfile(widget.targetUid);
        _socket.requestOfflineMessages(widget.targetUid);
      } catch (e) {
        debugPrint('Note: requestOfflineMessages error: $e');
      }
    });
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    _typingTimer?.cancel();
    _keyExchangeTimeout?.cancel();
    _recordingTimer?.cancel();
    _messageController.removeListener(_onTextChanged);
    _scrollController.removeListener(_onScroll);
    _messageController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _cameraController?.dispose();
    if (_isTyping) _socket.sendTypingIndicator(widget.targetUid, false);
    _cleanTempVoiceFile();
    super.dispose();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Key exchange & History
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _initializeSecureChat() async {
    try {
      if (widget.cipher.hasSharedSecret(widget.targetUid)) {
        if (mounted) setState(() => _keysExchanged = true);
        return;
      }
      _socket.requestPublicKey(widget.targetUid);
      _keyExchangeTimeout = Timer(KEY_EXCHANGE_TIMEOUT, () {
        if (!_keysExchanged && mounted) setState(() => _keysExchanged = true);
      });
    } catch (e) {
      debugPrint('Init error: $e');
    }
  }

  Future<void> _loadRecentHistory() async {
    try {
      final history = _storage.getRecentMessages(widget.targetUid, limit: MESSAGES_PER_PAGE);
      if (mounted) {
        setState(() {
          for (var msg in history) {
            final m = Map<String, dynamic>.from(msg);
            if (!_messageIds.contains(m['id'])) {
              _messages.add(m);
              _messageIds.add(m['id'].toString());
            }
          }
          _hasMoreMessages = history.length == MESSAGES_PER_PAGE;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animated: false));
      }
    } catch (e) {
      debugPrint('Load history error: $e');
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMoreMessages) return;
    setState(() => _isLoadingMore = true);
    try {
      final older = _storage.getOlderMessages(widget.targetUid, _messages.length, limit: MESSAGES_PER_PAGE);
      if (mounted) {
        setState(() {
          for (var msg in older) {
            final m = Map<String, dynamic>.from(msg);
            if (!_messageIds.contains(m['id'])) {
              _messages.insert(0, m);
              _messageIds.add(m['id'].toString());
            }
          }
          _hasMoreMessages = older.length == MESSAGES_PER_PAGE;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // HTTP MEDIA HELPERS
  // ──────────────────────────────────────────────────────────────────────────

  Future<String?> _uploadFileEncrypted(File file) async {
    try {
      final bytes         = await file.readAsBytes();
      final encryptedBytes = await widget.cipher.encryptFileBytes(bytes, targetUid: widget.targetUid);
      final tempDir  = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${file.path.split('/').last}.enc');
      await tempFile.writeAsBytes(encryptedBytes);
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(tempFile.path, filename: tempFile.path.split('/').last),
      });
      if (mounted) setState(() => _uploadProgress = 0.0);
      final response = await _dio.post(
        '$SERVER_HTTP_URL/upload',
        data: formData,
        onSendProgress: (sent, total) {
          if (mounted) setState(() => _uploadProgress = sent / total);
        },
      );
      if (await tempFile.exists()) await tempFile.delete();
      if (response.statusCode == 200 && response.data['status'] == 'success') {
        return response.data['file_id'] as String?;
      }
    } catch (e) {
      debugPrint('Encrypted Upload error: $e');
    }
    return null;
  }

  Future<String?> _downloadFileEncrypted(String fileId, String? fileName) async {
    try {
      final appDir  = await getApplicationDocumentsDirectory();
      final response = await http.get(Uri.parse('$SERVER_HTTP_URL/download/$fileId'));
      if (response.statusCode != 200) return null;
      final decryptedBytes = await widget.cipher.decryptFileBytes(
        response.bodyBytes,
        fromUid: widget.targetUid,
      );
      final name = fileName ?? 'file_${DateTime.now().millisecondsSinceEpoch}';
      final file = File('${appDir.path}/deepdrift_media/$name');
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsBytes(decryptedBytes);
      return file.path;
    } catch (e) {
      debugPrint('Encrypted Download error: $e');
    }
    return null;
  }

  Future<String?> _copyFileToMediaDir(File originalFile, MsgType msgType, String? fileName) async {
    try {
      final appDir   = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/deepdrift_media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final ext  = _extensionForType(msgType, fileName);
      final name = fileName ?? 'media_${DateTime.now().millisecondsSinceEpoch}$ext';
      final newFile = await originalFile.copy('${mediaDir.path}/$name');
      return newFile.path;
    } catch (e) {
      return originalFile.path;
    }
  }

  Future<String?> _saveMediaToDiskBase64({
    required String base64Data,
    required MsgType msgType,
    String? fileName,
  }) async {
    try {
      final appDir   = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/deepdrift_media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final ext  = _extensionForType(msgType, fileName);
      final name = fileName ?? 'media_${DateTime.now().millisecondsSinceEpoch}$ext';
      final file = File('${mediaDir.path}/$name');
      await file.writeAsBytes(base64Decode(base64Data));
      return file.path;
    } catch (e) {
      return null;
    }
  }

  String _extensionForType(MsgType type, String? fileName) {
    if (fileName != null && fileName.contains('.')) return '.${fileName.split('.').last}';
    switch (type) {
      case MsgType.image:      return '.jpg';
      case MsgType.voice:      return '.m4a';
      case MsgType.video_note: return '.mp4';
      default:                 return '';
    }
  }

  String _formatFileSize(dynamic sizeRaw) {
    final size = sizeRaw is int ? sizeRaw : int.tryParse(sizeRaw.toString()) ?? 0;
    if (size < 1024)           return '$size B';
    if (size < 1024 * 1024)   return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _cleanTempVoiceFile() {
    if (_voiceTempPath != null) {
      try { File(_voiceTempPath!).deleteSync(); } catch (_) {}
      _voiceTempPath = null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Socket listener
  // ──────────────────────────────────────────────────────────────────────────

  void _listenToMessages() {
    _socketSub = _socket.messages.listen((data) {
      if (!mounted) return;
      final type = data['type'];
      switch (type) {
        case 'message':             _handleIncomingMessage(data);  break;
        case 'typing_indicator':    _handleTypingIndicator(data);  break;
        case 'public_key_response': _handlePublicKeyResponse(data); break;
        case 'message_read':        _handleMessageRead(data);      break;
        case 'read_receipt':        _handleReadReceipt(data);      break;
        case 'message_deleted':     _handleMessageDeleted(data);   break;
        case 'message_edited':      _handleMessageEdited(data);    break;
        case 'message_reaction':    _handleMessageReaction(data);  break;
        case 'user_status':
        case 'profile_response':
          if (data['uid'] == widget.targetUid) setState(() {});
          break;
      }
    });
  }

  void _handleIncomingMessage(Map<String, dynamic> data) {
    final senderUid = data['from_uid'];
    if (senderUid != widget.targetUid) return;
    final msgId = data['id']?.toString();
    if (msgId == null || _messageIds.contains(msgId)) return;

    final encrypted = data['encrypted_text'];
    final signature = data['signature'];
    final msgTyp    = (data['messageType'] as String? ?? 'text').toMsgType();
    final rawTime   = data['time'];

    widget.cipher.decryptText(encrypted, fromUid: widget.targetUid).then((decrypted) async {
      // ── Обнаружение несоответствия ключей ─────────────────────────────────
      if (decrypted.contains('Authentication failed') || decrypted.contains('Wrong key')) {
        widget.cipher.clearSharedSecret(widget.targetUid);
        await _storage.clearCachedKeys(widget.targetUid);
        _socket.requestPublicKey(widget.targetUid);
        final errorMsg = {
          'id': msgId,
          'text': '⚠️ Key mismatch detected. Please ask sender to resend the message.',
          'isMe': false,
          'time': rawTime ?? DateTime.now().millisecondsSinceEpoch,
          'status': 'error',
          'type': 'text',
          'signatureStatus': SignatureStatus.invalid.index,
        };
        if (mounted) {
          setState(() {
            _messages.add(errorMsg);
            _messageIds.add(msgId);
          });
          _scrollToBottom();
        }
        return;
      }

      // ── 🔴-2 FIX: Верификация Ed25519-подписи ─────────────────────────────
      // Результат проверки сохраняется в модель сообщения и отображается
      // пользователю в виде иконки 🔒 (valid) или ⚠️ (invalid/missing).
      //
      // Логика:
      //  • signature == null  → ключ подписи ещё не установлен (unknown)
      //  • verifySignature() == true  → подпись верна (valid)
      //  • verifySignature() == false → подпись не совпадает или повреждена (invalid)
      SignatureStatus sigStatus = SignatureStatus.unknown;
      if (signature != null) {
        final isValid = await widget.cipher.verifySignature(
          decrypted,
          signature,
          widget.targetUid,
        );
        sigStatus = isValid ? SignatureStatus.valid : SignatureStatus.invalid;

        if (!isValid) {
          // Логируем — в debug-сборке видно в консоли
          debugPrint('⚠️ [Security] Invalid signature on message $msgId from $senderUid');
        }
      }
      // ─────────────────────────────────────────────────────────────────────

      String? localPath;
      if (msgTyp != MsgType.text && data['mediaData'] != null) {
        final String mediaStr = data['mediaData'] as String;
        if (mediaStr.startsWith('FILE_ID:')) {
          localPath = await _downloadFileEncrypted(mediaStr.substring(8), data['fileName'] as String?);
        } else {
          localPath = await _saveMediaToDiskBase64(
            base64Data: mediaStr,
            msgType: msgTyp,
            fileName: data['fileName'] as String?,
          );
        }
      }

      final msg = {
        'id':              msgId,
        'text':            decrypted,
        'isMe':            false,
        'time':            rawTime ?? DateTime.now().millisecondsSinceEpoch,
        'from':            senderUid,
        'to':              widget.myUid,
        'status':          'delivered',
        'replyTo':         data['replyTo'],
        'replyToId':       data['replyToId'],
        'type':            data['messageType'] ?? 'text',
        'filePath':        localPath,
        'fileName':        data['fileName'],
        'fileSize':        data['fileSize'],
        'mimeType':        data['mimeType'],
        'edited':          data['edited'] ?? false,
        'editedAt':        data['editedAt'],
        'forwardedFrom':   data['forwarded_from'],
        // Сохраняем статус подписи как int для совместимости с Hive
        'signatureStatus': sigStatus.index,
      };

      if (mounted) {
        setState(() {
          _messages.add(msg);
          _messageIds.add(msgId);
        });
        _scrollToBottom();
        _storage.saveMessage(widget.targetUid, msg);
        _sendReadReceipt(msgId);
      }
    }).catchError((Object e) {
      debugPrint('Decrypt error: $e');
    });
  }

  void _handleTypingIndicator(Map<String, dynamic> data) {
    if (data['from_uid'] == widget.targetUid && mounted) {
      setState(() => _targetIsTyping = data['typing'] == true);
      if (_targetIsTyping) _scrollToBottom();
    }
  }

  void _handlePublicKeyResponse(Map<String, dynamic> data) {
    if (data['target_uid'] != widget.targetUid) return;
    final x25519Key  = data['x25519_key'];
    final ed25519Key = data['ed25519_key'];
    if (x25519Key != null && ed25519Key != null) {
      widget.cipher
          .establishSharedSecret(widget.targetUid, x25519Key as String, theirSignKeyB64: ed25519Key as String)
          .then((_) { if (mounted) setState(() => _keysExchanged = true); });
    }
  }

  void _handleMessageRead(Map<String, dynamic> data) {
    final msgId = data['message_id']?.toString();
    if (msgId == null || !mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m['id'] == msgId);
      if (idx != -1) _messages[idx]['status'] = 'read';
    });
  }

  void _handleReadReceipt(Map<String, dynamic> data) {
    final msgId = data['message_id']?.toString();
    if (msgId == null || !mounted) return;
    setState(() {
      final idx = _messages.indexWhere((m) => m['id'] == msgId);
      if (idx != -1 && _messages[idx]['from'] == widget.myUid) {
        _messages[idx]['status'] = 'read';
      }
    });
    _storage.updateMessageStatus(widget.targetUid, msgId, 'read');
  }

  void _handleMessageDeleted(Map<String, dynamic> data) {
    final msgId = data['message_id']?.toString();
    if (msgId == null || !mounted) return;
    setState(() {
      _messages.removeWhere((m) => m['id'] == msgId);
      _messageIds.remove(msgId);
    });
    _storage.deleteMessage(widget.targetUid, msgId);
  }

  void _handleMessageEdited(Map<String, dynamic> data) {
    final msgId        = data['message_id']?.toString();
    final newEncrypted = data['new_encrypted_text'];
    final newSignature = data['new_signature'];
    if (msgId == null || newEncrypted == null) return;

    widget.cipher.decryptText(newEncrypted as String, fromUid: widget.targetUid).then((newText) async {
      // Верифицируем подпись отредактированного сообщения
      SignatureStatus sigStatus = SignatureStatus.unknown;
      if (newSignature != null) {
        final isValid = await widget.cipher.verifySignature(
          newText,
          newSignature as String,
          widget.targetUid,
        );
        sigStatus = isValid ? SignatureStatus.valid : SignatureStatus.invalid;
        if (!isValid) debugPrint('⚠️ [Security] Invalid signature on edited message $msgId');
      }

      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) {
            _messages[idx]['text']            = newText;
            _messages[idx]['edited']          = true;
            _messages[idx]['editedAt']        = DateTime.now().millisecondsSinceEpoch;
            _messages[idx]['signatureStatus'] = sigStatus.index;
          }
        });
      }
    });
  }

  void _handleMessageReaction(Map<String, dynamic> data) {
    final msgId  = data['message_id']?.toString();
    final emoji  = data['emoji'] as String?;
    final action = data['action'] as String?;
    if (msgId == null || emoji == null || !mounted) return;
    setState(() {
      _reactions.putIfAbsent(msgId, () => {});
      if (action == 'add') {
        _reactions[msgId]!.add(emoji);
      } else if (action == 'remove') {
        _reactions[msgId]!.remove(emoji);
      }
    });
    _storage.saveReactions(widget.targetUid, _reactions);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Read receipt & typing
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _markAllAsRead() async {
    final unreadIds = _messages
        .where((m) => m['from'] == widget.targetUid && m['status'] != 'read')
        .map((m) => m['id'].toString())
        .toList();
    for (final id in unreadIds) { _sendReadReceipt(id); }
    if (unreadIds.isNotEmpty) await _storage.markAllAsRead(widget.targetUid);
  }

  void _sendReadReceipt(String messageId) => _socket.sendReadReceipt(widget.targetUid, messageId);

  void _onTextChanged() {
    final hasText = _messageController.text.trim().isNotEmpty;
    if (hasText && !_isTyping) {
      _isTyping = true;
      _socket.sendTypingIndicator(widget.targetUid, true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      if (_isTyping) {
        _isTyping = false;
        _socket.sendTypingIndicator(widget.targetUid, false);
      }
    });
  }

  void _onScroll() {
    if (_scrollController.hasClients && _scrollController.position.pixels <= 100) {
      _loadMoreMessages();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Send Handlers
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _sendMessage({
    String? text,
    String  messageType    = 'text',
    String? mediaData,
    String? filePath,
    String? fileName,
    int?    fileSize,
    String? mimeType,
    // 🟡-1 Forward: опциональный источник пересылки
    String? forwardedFrom,
  }) async {
    if (_editingMessageId != null) { await _saveEditedMessage(); return; }

    final messageText = text ?? _messageController.text.trim();
    if (messageText.isEmpty && mediaData == null) return;

    if (!widget.cipher.hasSharedSecret(widget.targetUid)) {
      final loaded = await widget.cipher.tryLoadCachedKeys(widget.targetUid, _storage);
      if (!loaded) {
        _socket.requestPublicKey(widget.targetUid);
        await Future.delayed(const Duration(milliseconds: 800));
        if (!widget.cipher.hasSharedSecret(widget.targetUid)) {
          _showError('Cannot encrypt: recipient offline');
          return;
        }
      }
    }

    final msgId     = _uuid.v4();
    final now       = DateTime.now().millisecondsSinceEpoch;
    final replyId   = _replyToId;
    final replyText = _replyToText;

    try {
      final encrypted = await widget.cipher.encryptText(messageText, targetUid: widget.targetUid);
      final signature = await widget.cipher.signMessage(messageText);

      final myMsg = {
        'id':              msgId,
        'text':            messageText,
        'isMe':            true,
        'time':            now,
        'from':            widget.myUid,
        'to':              widget.targetUid,
        'status':          'pending',
        'replyTo':         replyText,
        'replyToId':       replyId,
        'type':            messageType,
        'filePath':        filePath,
        'fileName':        fileName,
        'fileSize':        fileSize,
        'mimeType':        mimeType,
        'edited':          false,
        'forwardedFrom':   forwardedFrom,
        // Собственные сообщения не нуждаются в верификации подписи
        'signatureStatus': SignatureStatus.valid.index,
      };

      if (mounted) {
        setState(() {
          _messages.add(myMsg);
          _messageIds.add(msgId);
          _messageController.clear();
          _replyToText = null;
          _replyToId   = null;
        });
        _scrollToBottom();
      }

      _socket.sendMessage(
        widget.targetUid, encrypted, signature, msgId,
        replyToId:     replyId,
        messageType:   messageType,
        mediaData:     mediaData,
        fileName:      fileName,
        fileSize:      fileSize,
        mimeType:      mimeType,
        forwardedFrom: forwardedFrom,
      );

      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'sent';
        });
      }
      await _storage.saveMessage(widget.targetUid, myMsg);
    } catch (e) {
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'failed';
        });
      }
      _showError('Failed to send: $e');
    }
  }

  Future<void> _sendPhoto({ImageSource source = ImageSource.gallery}) async {
    try {
      List<XFile> images = [];
      if (source == ImageSource.gallery) {
        images = await _imagePicker.pickMultiImage(imageQuality: 85);
      } else {
        final image = await _imagePicker.pickImage(source: source, imageQuality: 85);
        if (image != null) images.add(image);
      }
      if (images.isEmpty) return;

      if (mounted) setState(() { _isSendingFile = true; _uploadProgress = 0.0; });

      for (final image in images) {
        final file     = File(image.path);
        final fileSize = await file.length();
        final fileName = image.name;
        final fileId   = await _uploadFileEncrypted(file);
        if (fileId == null) { _showError('Upload failed for $fileName'); continue; }
        final localPath = await _copyFileToMediaDir(file, MsgType.image, fileName);
        await _sendMessage(
          text: '📷 Photo', messageType: 'image',
          mediaData: 'FILE_ID:$fileId', filePath: localPath,
          fileName: fileName, fileSize: fileSize, mimeType: 'image/jpeg',
        );
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      _showError('Failed to send photos: $e');
    } finally {
      if (mounted) setState(() { _isSendingFile = false; _uploadProgress = 0.0; });
    }
  }

  Future<void> _sendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any, withData: false, withReadStream: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked   = result.files.first;
      final filePath = picked.path;
      if (filePath == null) return;

      final file     = File(filePath);
      final fileSize = await file.length();
      final fileName = picked.name;

      if (mounted) setState(() { _isSendingFile = true; _uploadProgress = 0.0; });

      final fileId = await _uploadFileEncrypted(file);
      if (fileId == null) {
        _showError('File upload failed');
        if (mounted) setState(() => _isSendingFile = false);
        return;
      }

      final mimeType  = _mimeTypeFromExtension(fileName);
      final localPath = await _copyFileToMediaDir(file, MsgType.file, fileName);
      await _sendMessage(
        text: '📎 $fileName', messageType: 'file',
        mediaData: 'FILE_ID:$fileId', filePath: localPath,
        fileName: fileName, fileSize: fileSize, mimeType: mimeType,
      );
    } catch (e) {
      _showError('Failed to send file: $e');
    } finally {
      if (mounted) setState(() { _isSendingFile = false; _uploadProgress = 0.0; });
    }
  }

  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      setState(() { _isRecording = true; _voiceTempPath = path; _recordingDuration = 0; });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingDuration++);
      });
    } else {
      _showError('Microphone permission denied');
    }
  }

  Future<void> _cancelRecording() async {
    try {
      await _audioRecorder.stop();
      _recordingTimer?.cancel();
      _cleanTempVoiceFile();
      if (mounted) setState(() { _isRecording = false; _recordingDuration = 0; });
    } catch (e) {
      debugPrint('Error cancelling recording: $e');
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      final path = await _audioRecorder.stop();
      _recordingTimer?.cancel();
      if (mounted) setState(() => _isRecording = false);

      if (path != null) {
        _voiceTempPath = path;
        final file = File(path);
        if (_recordingDuration < 1) { _cleanTempVoiceFile(); return; }

        if (mounted) setState(() { _isSendingFile = true; _uploadProgress = 0.0; });
        final fileId = await _uploadFileEncrypted(file);
        if (fileId == null) {
          _showError('Voice upload failed');
          _cleanTempVoiceFile();
          if (mounted) setState(() => _isSendingFile = false);
          return;
        }

        final fileName  = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        final fileSize  = await file.length();
        final localPath = await _copyFileToMediaDir(file, MsgType.voice, fileName);
        await _sendMessage(
          text: '🎤 Voice message', messageType: 'voice',
          mediaData: 'FILE_ID:$fileId', filePath: localPath,
          fileName: fileName, fileSize: fileSize, mimeType: 'audio/m4a',
        );
        _cleanTempVoiceFile();
        if (mounted) setState(() => _isSendingFile = false);
      }
    } catch (e) {
      _showError('Error sending voice: $e');
      _cancelRecording();
      if (mounted) setState(() => _isSendingFile = false);
    }
  }

  Future<void> _startVideoRecording() async {
    try {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _cameraController = CameraController(front, ResolutionPreset.medium, enableAudio: true);
      await _cameraController!.initialize();
      await _cameraController!.startVideoRecording();
      setState(() { _isVideoRecording = true; _recordingDuration = 0; });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingDuration++);
      });
    } catch (e) {
      _showError('Camera error: $e');
    }
  }

  Future<void> _stopVideoRecordingAndSend() async {
    if (_cameraController == null || !_cameraController!.value.isRecordingVideo) return;
    try {
      final xfile = await _cameraController!.stopVideoRecording();
      await _cameraController!.dispose();
      _cameraController = null;
      _recordingTimer?.cancel();
      setState(() => _isVideoRecording = false);

      if (_recordingDuration < 1) return;

      setState(() { _isSendingFile = true; _uploadProgress = 0.0; });
      final file   = File(xfile.path);
      final fileId = await _uploadFileEncrypted(file);
      if (fileId != null) {
        final fileName  = 'video_note_${DateTime.now().millisecondsSinceEpoch}.mp4';
        final localPath = await _copyFileToMediaDir(file, MsgType.video_note, fileName);
        await _sendMessage(
          text: '🎥 Video Note', messageType: 'video_note',
          mediaData: 'FILE_ID:$fileId', filePath: localPath,
          fileName: fileName, fileSize: await file.length(), mimeType: 'video/mp4',
        );
      }
    } catch (e) {
      _showError('Video send error: $e');
    } finally {
      if (mounted) setState(() => _isSendingFile = false);
    }
  }

  Future<void> _playVoiceMessage(Map<String, dynamic> msg) async {
    final msgId = msg['id']?.toString();
    try {
      if (_playingMessageId == msgId) {
        await _audioPlayer.stop();
        setState(() => _playingMessageId = null);
        return;
      }
      final localPath = msg['filePath'] as String?;
      if (localPath != null && File(localPath).existsSync()) {
        await _audioPlayer.play(DeviceFileSource(localPath));
      } else {
        _showError('Voice file not available locally');
        return;
      }
      setState(() => _playingMessageId = msgId);
      _audioPlayer.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingMessageId = null);
      });
    } catch (e) {
      _showError('Failed to play: $e');
    }
  }

  void _startEditingMessage(Map<String, dynamic> message) {
    setState(() {
      _editingMessageId       = message['id']?.toString();
      _messageController.text = message['text'] as String? ?? '';
    });
  }

  Future<void> _saveEditedMessage() async {
    if (_editingMessageId == null) return;
    final newText = _messageController.text.trim();
    if (newText.isEmpty) return;
    try {
      final encrypted = await widget.cipher.encryptText(newText, targetUid: widget.targetUid);
      final signature = await widget.cipher.signMessage(newText);
      _socket.sendEditMessage(widget.targetUid, _editingMessageId!, encrypted, signature);
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == _editingMessageId);
        if (idx != -1) {
          _messages[idx]['text']            = newText;
          _messages[idx]['edited']          = true;
          _messages[idx]['editedAt']        = DateTime.now().millisecondsSinceEpoch;
          _messages[idx]['signatureStatus'] = SignatureStatus.valid.index;
        }
        _editingMessageId = null;
        _messageController.clear();
      });
    } catch (e) {
      _showError('Failed to edit: $e');
    }
  }

  Future<void> _deleteMessage(String messageId, {required bool deleteForEveryone}) async {
    if (deleteForEveryone) _socket.sendDeleteMessage(widget.targetUid, messageId);
    setState(() {
      _messages.removeWhere((m) => m['id'] == messageId);
      _messageIds.remove(messageId);
    });
    await _storage.deleteMessage(widget.targetUid, messageId);
  }

  void _addReaction(String messageId, String emoji) {
    _socket.sendReaction(widget.targetUid, messageId, emoji, 'add');
    setState(() {
      _reactions.putIfAbsent(messageId, () => {});
      _reactions[messageId]!.add(emoji);
    });
    _storage.saveReactions(widget.targetUid, _reactions);
  }

  void _removeReaction(String messageId, String emoji) {
    _socket.sendReaction(widget.targetUid, messageId, emoji, 'remove');
    setState(() => _reactions[messageId]?.remove(emoji));
    _storage.saveReactions(widget.targetUid, _reactions);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 🟡-1 FORWARD (пересылка сообщений)
  // ──────────────────────────────────────────────────────────────────────────

  /// Показывает диалог выбора контакта для пересылки и отправляет сообщение.
  ///
  /// Пересылаемое сообщение шифруется заново для получателя — оригинальный
  /// зашифртекст никогда не передаётся третьим лицам.
  void _forwardMessage(Map<String, dynamic> message) {
    final contacts = _storage.getContacts();
    if (contacts.isEmpty) {
      _showError('No contacts to forward to');
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Forward to...',
              style: GoogleFonts.orbitron(color: Colors.white, fontSize: 14),
            ),
          ),
          const Divider(color: Colors.white12),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: contacts.length,
              itemBuilder: (_, i) {
                final uid  = contacts[i];
                final name = _storage.getContactDisplayName(uid);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF0A0E27),
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.cyan),
                    ),
                  ),
                  title: Text(name, style: const TextStyle(color: Colors.white)),
                  subtitle: Text(uid, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _sendForwardedMessage(message, toUid: uid);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Пересылает [message] пользователю [toUid].
  ///
  /// Если целевой пользователь — текущий собеседник, пересылаем в тот же чат.
  /// Если другой — нужен SharedSecret с ним; при его отсутствии показываем ошибку.
  Future<void> _sendForwardedMessage(
    Map<String, dynamic> message, {
    required String toUid,
  }) async {
    // Определяем оригинальный источник пересылки
    final originalFrom = message['forwardedFrom'] as String? ??
        (message['isMe'] == true ? widget.myUid : widget.targetUid);

    final displayName = _storage.getContactDisplayName(originalFrom);
    final forwardLabel = displayName.isNotEmpty ? displayName : originalFrom;

    if (toUid == widget.targetUid) {
      // Пересылка в тот же чат — SharedSecret уже есть
      await _sendMessage(
        text:          message['text'] as String? ?? '',
        messageType:   message['type'] as String? ?? 'text',
        mediaData:     null, // медиа-файлы при пересылке не дублируем на сервере
        filePath:      message['filePath'] as String?,
        fileName:      message['fileName'] as String?,
        fileSize:      message['fileSize'] as int?,
        mimeType:      message['mimeType'] as String?,
        forwardedFrom: forwardLabel,
      );
    } else {
      // Пересылка в другой чат — нужна отдельная навигация или сервис
      // TODO: открыть ChatScreen с toUid и передать сообщение через аргументы
      // Пока показываем ошибку с подсказкой
      _showError('Open a chat with $forwardLabel first, then forward from there.');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // UI helpers
  // ──────────────────────────────────────────────────────────────────────────

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollController.hasClients) return;
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position.maxScrollExtent;
      if (animated) {
        _scrollController.animateTo(
          position,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(position);
      }
    });
  }

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return '';
    final dt = timestamp is int
        ? DateTime.fromMillisecondsSinceEpoch(timestamp)
        : DateTime.tryParse(timestamp.toString()) ?? DateTime.now();
    return DateFormat.Hm().format(dt);
  }

  String _formatLastSeen(int timestamp) {
    if (timestamp == 0) return 'offline';
    final dt   = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now  = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1)    return 'just now';
    if (diff.inMinutes < 60)   return '${diff.inMinutes} min ago';
    if (dt.day == now.day)     return 'today at ${DateFormat.Hm().format(dt)}';
    if (dt.day == now.day - 1) return 'yesterday at ${DateFormat.Hm().format(dt)}';
    return DateFormat('dd MMM, HH:mm').format(dt);
  }

  String _formatRecordingTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _setReplyTo(Map<String, dynamic> message) {
    setState(() {
      _replyToText = message['text'] as String?;
      _replyToId   = message['id']?.toString();
    });
  }

  void _cancelReply() => setState(() { _replyToText = null; _replyToId = null; });

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) _searchController.clear();
    });
  }

  void _copyMessageText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  List<Map<String, dynamic>> get _filteredMessages {
    if (!_isSearching || _searchController.text.isEmpty) return _messages;
    final q = _searchController.text.toLowerCase();
    return _messages.where((m) => (m['text'] ?? '').toLowerCase().contains(q)).toList();
  }

  String _mimeTypeFromExtension(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    const mimes = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain',  'zip': 'application/zip',
      'rar': 'application/x-rar-compressed', 'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',   'mov': 'video/quicktime',
      'png': 'image/png',   'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'gif': 'image/gif',
    };
    return mimes[ext] ?? 'application/octet-stream';
  }

  IconData _iconForMime(String? mimeType) {
    if (mimeType == null) return Icons.attach_file;
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.contains('pdf'))      return Icons.picture_as_pdf;
    if (mimeType.contains('word') || mimeType.contains('msword')) return Icons.description;
    if (mimeType.contains('excel') || mimeType.contains('spreadsheet')) return Icons.table_chart;
    if (mimeType.contains('zip') || mimeType.contains('rar')) return Icons.folder_zip;
    return Icons.attach_file;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Просмотр и сохранение файлов
  // ──────────────────────────────────────────────────────────────────────────

  void _showFullImageFromFile(String filePath) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(child: Image.file(File(filePath))),
            Positioned(
              right: 20, bottom: 20,
              child: FloatingActionButton(
                backgroundColor: Colors.white24,
                child: const Icon(Icons.folder_shared, color: Colors.white),
                onPressed: () async {
                  try {
                    bool hasAccess = await Gal.hasAccess();
                    if (!hasAccess) await Gal.requestAccess();
                    Directory? downloadsDir;
                    if (Platform.isAndroid) {
                      downloadsDir = Directory('/storage/emulated/0/Download/DDchat');
                    } else {
                      downloadsDir = await getApplicationDocumentsDirectory();
                    }
                    if (!await downloadsDir.exists()) await downloadsDir.create(recursive: true);
                    final originalFile = File(filePath);
                    final fileName = originalFile.path.split('/').last;
                    final newPath  = '${downloadsDir.path}/$fileName';
                    await originalFile.copy(newPath);
                    await Gal.putImage(newPath);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('✅ Saved to: $newPath')),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                      );
                    }
                  }
                },
              ),
            ),
            Positioned(
              top: 40, right: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFile(String? filePath, String fileName) async {
    if (filePath == null || !File(filePath).existsSync()) {
      _showError('File not available on this device');
      return;
    }
    try {
      if (Platform.isAndroid) {
        final downloadsDir = Directory('/storage/emulated/0/Download/DDchat');
        if (!await downloadsDir.exists()) await downloadsDir.create(recursive: true);
        final newPath = '${downloadsDir.path}/$fileName';
        await File(filePath).copy(newPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('File saved to Downloads/DDchat'),
            action: SnackBarAction(label: 'OK', onPressed: () {}),
          ));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved at: $filePath')),
          );
        }
      }
    } catch (e) {
      debugPrint('Save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved internally at: $filePath')),
        );
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Message actions
  // ──────────────────────────────────────────────────────────────────────────

  void _showMessageActions(Map<String, dynamic> message) {
    final isMe = message['from'] == widget.myUid;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag-handle
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (message['type'] == 'text')
                _actionTile(Icons.copy, 'Copy', () {
                  Navigator.pop(context);
                  _copyMessageText(message['text'] as String? ?? '');
                }),
              _actionTile(Icons.reply, 'Reply', () {
                Navigator.pop(context);
                _setReplyTo(message);
              }),
              // 🟡-1 FIX: Кнопка Forward добавлена в меню
              _actionTile(Icons.forward, 'Forward', () {
                Navigator.pop(context);
                _forwardMessage(message);
              }),
              _actionTile(Icons.emoji_emotions, 'React', () {
                Navigator.pop(context);
                _showReactionPicker(message['id'].toString());
              }),
              if (isMe && message['type'] == 'text')
                _actionTile(Icons.edit, 'Edit', () {
                  Navigator.pop(context);
                  _startEditingMessage(message);
                }),
              if (isMe)
                _actionTile(Icons.delete, 'Delete for everyone', () {
                  Navigator.pop(context);
                  _confirmDelete(message['id'].toString(), deleteForEveryone: true);
                }, color: Colors.red),
              _actionTile(Icons.delete_outline, 'Delete for me', () {
                Navigator.pop(context);
                _confirmDelete(message['id'].toString(), deleteForEveryone: false);
              }, color: Colors.orange),
            ],
          ),
        ),
      ),
    );
  }

  ListTile _actionTile(IconData icon, String label, VoidCallback onTap, {Color color = Colors.cyan}) =>
      ListTile(
        leading: Icon(icon, color: color),
        title: Text(label, style: TextStyle(color: color == Colors.cyan ? Colors.white : color)),
        onTap: onTap,
      );

  void _confirmDelete(String messageId, {required bool deleteForEveryone}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Delete message?', style: TextStyle(color: Colors.white)),
        content: Text(
          deleteForEveryone
              ? 'This message will be deleted for everyone'
              : 'This message will only be deleted for you',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteMessage(messageId, deleteForEveryone: deleteForEveryone);
            },
            child: const Text('DELETE', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showReactionPicker(String messageId) {
    const reactions = ['❤️', '👍', '😂', '😮', '😢', '🙏', '🔥', '👎'];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('React', style: TextStyle(color: Colors.white)),
        content: Wrap(
          spacing: 10,
          children: reactions.map((emoji) => GestureDetector(
            onTap: () { Navigator.pop(context); _addReaction(messageId, emoji); },
            child: Text(emoji, style: const TextStyle(fontSize: 32)),
          )).toList(),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Message bubble
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildMessage(Map<String, dynamic> msg, int index) {
    final isMe      = msg['from'] == widget.myUid;
    final msgType   = (msg['type'] as String? ?? 'text').toMsgType();
    final reactions = _reactions[msg['id']?.toString()] ?? {};

    return GestureDetector(
      onLongPress: () => _showMessageActions(msg),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  gradient: isMe
                      ? const LinearGradient(colors: [Color(0xFF00D4FF), Color(0xFF0099CC)])
                      : null,
                  color: isMe ? null : const Color(0xFF1A1F3C),
                  borderRadius: BorderRadius.only(
                    topLeft:     const Radius.circular(12),
                    topRight:    const Radius.circular(12),
                    bottomLeft:  Radius.circular(isMe ? 12 : 2),
                    bottomRight: Radius.circular(isMe ? 2 : 12),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // 🟢-5 FIX: Метка "Forwarded from" если сообщение переслано
                    if (msg['forwardedFrom'] != null) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forward,
                              size: 13,
                              color: isMe ? Colors.white70 : Colors.cyanAccent.withValues(alpha: 0.8)),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Forwarded from ${msg['forwardedFrom']}',
                              style: TextStyle(
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                                color: isMe
                                    ? Colors.white70
                                    : Colors.cyanAccent.withValues(alpha: 0.8),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],

                    // Reply preview
                    if (msg['replyTo'] != null) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin:  const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: const Border(left: BorderSide(color: Colors.cyanAccent, width: 3)),
                        ),
                        child: Text(
                          msg['replyTo'] as String,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],

                    // Содержимое сообщения
                    _buildMessageContent(msg, msgType, isMe),
                    const SizedBox(height: 4),

                    // Нижняя строка: edited + время + статус + иконка подписи
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg['edited'] == true)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Text(
                              'edited',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        Text(
                          _formatTime(msg['time']),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          _buildStatusIcon(msg['status'] as String?),
                        ],
                        // 🔴-2 + 🟢-1 FIX: иконка верификации подписи
                        // Показывается только для входящих сообщений
                        if (!isMe) ...[
                          const SizedBox(width: 4),
                          _buildSignatureIcon(msg),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // Реакции
              if (reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: reactions.map((emoji) => GestureDetector(
                      onTap: () => _removeReaction(msg['id'].toString(), emoji),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1F3C),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.cyan.withValues(alpha: 0.4)),
                        ),
                        child: Text(emoji, style: const TextStyle(fontSize: 14)),
                      ),
                    )).toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 🔴-2 + 🟢-1 FIX: Иконка статуса Ed25519-подписи
  //
  // 🔒 зелёный  — подпись верна, сообщение не изменено после отправки
  // ⚠️ оранжевый — подпись невалидна или отсутствует (возможна подмена)
  // ··· белый   — ключ контакта ещё не загружен (нейтральное состояние)
  //
  // Нажатие показывает объяснение для пользователя.
  Widget _buildSignatureIcon(Map<String, dynamic> msg) {
    final statusIndex = msg['signatureStatus'] as int?;
    final status = statusIndex != null
        ? SignatureStatus.values[statusIndex]
        : SignatureStatus.unknown;

    final (icon, color, tooltip) = switch (status) {
      SignatureStatus.valid   => (Icons.lock, Colors.greenAccent,    'Signature verified'),
      SignatureStatus.invalid => (Icons.warning_amber, Colors.orange, 'Signature invalid — message may have been tampered'),
      SignatureStatus.unknown => (Icons.lock_clock, Colors.white24,   'Signature not yet verified'),
    };

    return GestureDetector(
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tooltip),
          backgroundColor: status == SignatureStatus.invalid ? Colors.orange : Colors.blueGrey,
          duration: const Duration(seconds: 3),
        ),
      ),
      child: Icon(icon, size: 12, color: color),
    );
  }

  Widget _buildMessageContent(Map<String, dynamic> msg, MsgType msgType, bool isMe) {
    switch (msgType) {
      case MsgType.image:
        return _buildImageContent(msg);
      case MsgType.voice:
        return _buildVoiceContent(msg, isMe);
      case MsgType.file:
        return _buildFileContent(msg, isMe);
      case MsgType.video_note:
        return (msg['filePath'] != null)
            ? VideoNotePlayer(filePath: msg['filePath'] as String)
            : const Text('[Video Note Error]', style: TextStyle(color: Colors.white54));
      default:
        return Text(msg['text'] as String? ?? '', style: const TextStyle(color: Colors.white, fontSize: 15));
    }
  }

  Widget _buildImageContent(Map<String, dynamic> msg) {
    final localPath = msg['filePath'] as String?;
    if (localPath != null && File(localPath).existsSync()) {
      return GestureDetector(
        onTap: () => _showFullImageFromFile(localPath),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(localPath),
            width: 200,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _imagePlaceholder(msg['fileName'] as String?),
          ),
        ),
      );
    }
    return _imagePlaceholder(msg['fileName'] as String?);
  }

  Widget _imagePlaceholder(String? name) => Container(
    width: 200, height: 120,
    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.broken_image, color: Colors.white38, size: 40),
        if (name != null) Text(name, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    ),
  );

  Widget _buildVoiceContent(Map<String, dynamic> msg, bool isMe) {
    final msgId     = msg['id']?.toString();
    final isPlaying = _playingMessageId == msgId;
    return GestureDetector(
      onTap: () => _playVoiceMessage(msg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPlaying ? Icons.pause_circle : Icons.play_circle,
            color: isMe ? Colors.white : Colors.cyanAccent,
            size: 36,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Voice message', style: TextStyle(color: Colors.white, fontSize: 14)),
              if (msg['fileSize'] != null)
                Text(
                  _formatFileSize(msg['fileSize']),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFileContent(Map<String, dynamic> msg, bool isMe) {
    final fileName = msg['fileName'] as String? ?? 'file';
    final mimeType = msg['mimeType'] as String?;
    final fileSize = msg['fileSize'];
    final filePath = msg['filePath'] as String?;
    return GestureDetector(
      onTap: () => _openFile(filePath, fileName),
      child: Container(
        constraints: const BoxConstraints(minWidth: 180),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (isMe ? Colors.white : Colors.cyan).withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: Colors.cyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_iconForMime(mimeType), color: Colors.cyanAccent, size: 26),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (fileSize != null)
                    Text(_formatFileSize(fileSize), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  Text(
                    filePath != null && File(filePath).existsSync() ? 'Tap to open' : 'File unavailable',
                    style: TextStyle(
                      color: filePath != null && File(filePath).existsSync()
                          ? Colors.cyanAccent
                          : Colors.white30,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(String? status) {
    switch (status) {
      case 'read':      return const Icon(Icons.done_all,    size: 14, color: Colors.cyanAccent);
      case 'delivered': return const Icon(Icons.done_all,    size: 14, color: Colors.white54);
      case 'sent':      return const Icon(Icons.check,       size: 14, color: Colors.white54);
      case 'pending':   return const Icon(Icons.access_time, size: 14, color: Colors.white38);
      case 'failed':    return const Icon(Icons.error_outline, size: 14, color: Colors.redAccent);
      default:          return const SizedBox.shrink();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final displayName     = _storage.getContactDisplayName(widget.targetUid);
    final displayMessages = _filteredMessages;

    return PopScope(
      canPop: !_isSendingFile,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSendingFile) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please wait for upload to finish...')),
          );
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E27),
        appBar: _buildAppBar(displayName),
        body: Stack(
          children: [
            Column(
              children: [
                if (_replyToText != null) _buildReplyBanner(),
                Expanded(
                  child: ListView.builder(
                    controller:  _scrollController,
                    itemCount:   displayMessages.length + (_isLoadingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (_isLoadingMore && index == 0) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(color: Colors.cyan),
                          ),
                        );
                      }
                      final mIdx = _isLoadingMore ? index - 1 : index;
                      return _buildMessage(displayMessages[mIdx], mIdx);
                    },
                  ),
                ),
                if (_editingMessageId != null) _buildEditBanner(),
                _buildInputArea(),
              ],
            ),

            // Оверлей предпросмотра камеры для видео-кружочков
            if (_isVideoRecording &&
                _cameraController != null &&
                _cameraController!.value.isInitialized)
              Positioned(
                bottom: 90,
                right:  20,
                child: Container(
                  width: 160, height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.cyan, width: 3),
                    boxShadow: [BoxShadow(color: Colors.cyan.withValues(alpha: 0.5), blurRadius: 10)],
                  ),
                  child: ClipOval(
                    child: AspectRatio(aspectRatio: 1, child: CameraPreview(_cameraController!)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  AppBar _buildAppBar(String displayName) {
    final isOnline = _storage.isContactOnline(widget.targetUid);
    final lastSeen = _storage.getContactLastSeen(widget.targetUid);
    final avatar   = _storage.getContactAvatar(widget.targetUid);

    return AppBar(
      backgroundColor: const Color(0xFF1A1F3C),
      titleSpacing: 0,
      title: _isSearching
          ? TextField(
              controller: _searchController,
              autofocus:  true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'Search messages...',
                hintStyle: TextStyle(color: Colors.white54),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 8),
              ),
              onChanged: (_) => setState(() {}),
            )
          : Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFF0A0E27),
                  backgroundImage: (avatar != null && avatar.isNotEmpty)
                      ? NetworkImage('$SERVER_HTTP_URL/download/$avatar')
                      : null,
                  child: (avatar == null || avatar.isEmpty)
                      ? Text(
                          displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                          style: const TextStyle(color: Colors.cyan, fontSize: 14),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName, style: GoogleFonts.orbitron(fontSize: 14)),
                      if (_targetIsTyping)
                        const Text('typing...', style: TextStyle(fontSize: 10, color: Colors.cyan))
                      else if (isOnline)
                        const Text('online', style: TextStyle(fontSize: 10, color: Colors.green))
                      else if (lastSeen > 0)
                        Text(
                          'last seen ${_formatLastSeen(lastSeen)}',
                          style: const TextStyle(fontSize: 10, color: Colors.white54),
                        ),
                    ],
                  ),
                ),
              ],
            ),
      actions: [
        IconButton(
          icon: Icon(_isSearching ? Icons.close : Icons.search),
          onPressed: _toggleSearch,
        ),
      ],
    );
  }

  Widget _buildReplyBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    color: const Color(0xFF1A1F3C),
    child: Row(
      children: [
        const Icon(Icons.reply, color: Colors.cyan, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _replyToText!,
            style: const TextStyle(color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white54, size: 20),
          onPressed: _cancelReply,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    ),
  );

  Widget _buildEditBanner() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    color: const Color(0xFF1A1F3C),
    child: Row(
      children: [
        const Icon(Icons.edit, color: Colors.cyan, size: 16),
        const SizedBox(width: 8),
        const Expanded(
          child: Text('Editing message', style: TextStyle(color: Colors.cyan, fontSize: 13)),
        ),
        TextButton(
          onPressed: () => setState(() {
            _editingMessageId = null;
            _messageController.clear();
          }),
          child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
        ),
      ],
    ),
  );

  Widget _buildInputArea() {
    if (_isRecording || _isVideoRecording) {
      final isVideo = _isVideoRecording;
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F3C),
          border: Border(top: BorderSide(color: isVideo ? Colors.cyan : Colors.red, width: 0.5)),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: (isVideo ? Colors.cyan : Colors.red).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(
                      color: (isVideo ? Colors.cyan : Colors.red).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10, height: 10,
                        decoration: BoxDecoration(
                          color: isVideo ? Colors.cyan : Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _formatRecordingTime(_recordingDuration),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        isVideo ? 'Recording video...' : 'Recording...',
                        style: TextStyle(
                          color: isVideo ? Colors.cyanAccent : Colors.redAccent,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: Colors.white10,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.red),
                  onPressed: isVideo
                      ? () async {
                          await _cameraController?.stopVideoRecording();
                          await _cameraController?.dispose();
                          _cameraController = null;
                          _recordingTimer?.cancel();
                          setState(() { _isVideoRecording = false; _recordingDuration = 0; });
                        }
                      : _cancelRecording,
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: const Color(0xFF00D9FF),
                child: IconButton(
                  icon: const Icon(Icons.arrow_upward, color: Colors.black),
                  onPressed: isVideo ? _stopVideoRecordingAndSend : _stopRecordingAndSend,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1F3C),
        border: Border(top: BorderSide(color: Colors.cyan, width: 0.5)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            PopupMenuButton<String>(
              color: const Color(0xFF1A1F3C),
              icon: const Icon(Icons.add_circle_outline, color: Colors.cyan),
              onSelected: (value) {
                switch (value) {
                  case 'photo_gallery': _sendPhoto(source: ImageSource.gallery); break;
                  case 'photo_camera':  _sendPhoto(source: ImageSource.camera);  break;
                  case 'file':          _sendFile();                              break;
                }
              },
              itemBuilder: (_) => [
                _popupItem('photo_gallery', Icons.photo_library, 'Photo from gallery'),
                _popupItem('photo_camera',  Icons.camera_alt,    'Take photo'),
                _popupItem('file',          Icons.attach_file,   'Send file'),
              ],
            ),

            if (_isSendingFile)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(
                        value: _uploadProgress,
                        strokeWidth: 3,
                        color: Colors.cyan,
                      ),
                    ),
                    Text(
                      '${(_uploadProgress * 100).toInt()}%',
                      style: const TextStyle(fontSize: 8, color: Colors.white),
                    ),
                  ],
                ),
              ),

            Expanded(
              child: TextField(
                controller: _messageController,
                style: const TextStyle(color: Colors.white),
                maxLines: null,
                decoration: InputDecoration(
                  hintText: _editingMessageId != null ? 'Edit message...' : 'Type a message...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
                onTap: () => Future.delayed(const Duration(milliseconds: 300), _scrollToBottom),
              ),
            ),

            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _messageController,
              builder: (context, value, child) {
                if (value.text.trim().isNotEmpty) {
                  return IconButton(
                    icon: const Icon(Icons.send, color: Colors.cyan),
                    onPressed: _sendMessage,
                  );
                } else {
                  return GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      setState(() => _isMicMode = !_isMicMode);
                    },
                    onLongPressStart: (_) {
                      HapticFeedback.heavyImpact();
                      _isMicMode ? _startRecording() : _startVideoRecording();
                    },
                    onLongPressEnd: (_) {
                      _isMicMode ? _stopRecordingAndSend() : _stopVideoRecordingAndSend();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(left: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.cyan.withValues(alpha: 0.1),
                      ),
                      child: Icon(
                        _isMicMode ? Icons.mic : Icons.videocam,
                        color: Colors.cyan,
                        size: 24,
                      ),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _popupItem(String value, IconData icon, String label) =>
      PopupMenuItem(
        value: value,
        child: Row(
          children: [
            Icon(icon, color: Colors.cyan, size: 20),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(color: Colors.white)),
          ],
        ),
      );
}

// ─── ВИДЖЕТ ПЛЕЕРА ДЛЯ КРУЖОЧКОВ ────────────────────────────────────────────
class VideoNotePlayer extends StatefulWidget {
  final String filePath;
  const VideoNotePlayer({super.key, required this.filePath});

  @override
  State<VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<VideoNotePlayer> {
  late VideoPlayerController _controller;
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        _controller.setLooping(true);
        _controller.setVolume(0); // Без звука по умолчанию (как в Telegram)
        if (mounted) setState(() => _isInit = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) {
      return Container(
        width: 200, height: 200,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black26),
        child: const Center(child: CircularProgressIndicator(color: Colors.cyan)),
      );
    }
    return GestureDetector(
      onTap: () {
        // Тап включает/выключает звук
        setState(() {
          _controller.setVolume(_controller.value.volume == 0 ? 1 : 0);
        });
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 220, height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.cyan.withValues(alpha: 0.3), width: 3),
            ),
            child: ClipOval(
              child: AspectRatio(aspectRatio: 1, child: VideoPlayer(_controller)),
            ),
          ),
          if (_controller.value.volume > 0)
            const Positioned(
              bottom: 20,
              child: Icon(Icons.volume_up, color: Colors.white, size: 20),
            ),
        ],
      ),
    );
  }
}

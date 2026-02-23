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

import 'crypto_service.dart';
import 'socket_service.dart';
import 'storage_service.dart';

// ─── Типы сообщений ──────────────────────────────────────────────────────────
enum MsgType { text, image, voice, file }

extension MsgTypeStr on String {
  MsgType toMsgType() {
    switch (this) {
      case 'image': return MsgType.image;
      case 'voice': return MsgType.voice;
      case 'file':  return MsgType.file;
      default:      return MsgType.text;
    }
  }
}

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
  // АДРЕС HTTP СЕРВЕРА ДЛЯ ЗАГРУЗОК
  static const String SERVER_HTTP_URL = 'https://deepdrift-backend.onrender.com';

  final List<Map<String, dynamic>> _messages = [];
  final Set<String>               _messageIds = {};
  final TextEditingController     _messageController = TextEditingController();
  final TextEditingController     _searchController  = TextEditingController();
  final ScrollController          _scrollController  = ScrollController();
  final _socket       = SocketService();
  final _storage      = StorageService();
  final _uuid         = const Uuid();
  final _imagePicker  = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer   = AudioPlayer();

  StreamSubscription? _socketSub;

  // Typing
  bool   _isTyping       = false;
  Timer? _typingTimer;
  bool   _targetIsTyping = false;

  // Pagination
  bool _isLoadingMore    = false;
  bool _hasMoreMessages  = true;

  // Reply
  String? _replyToText;
  String? _replyToId;

  // Key exchange
  bool   _keysExchanged    = false;
  Timer? _keyExchangeTimeout;

  // Search
  bool _isSearching = false;

  // Voice recording
  bool    _isRecording   = false;
  String? _voiceTempPath;
  Timer?  _recordingTimer;
  int     _recordingDuration = 0;

  // Edit
  String? _editingMessageId;

  // Reactions
  Map<String, Set<String>> _reactions = {};

  // Playing voice
  String? _playingMessageId;

  // File upload progress
  bool _isSendingFile = false;

  static const int      MESSAGES_PER_PAGE   = 50;
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
    
    // Загрузка истории и кэшированных ключей
    _loadRecentHistory().then((_) {
      _markAllAsRead();
      _scrollToBottom(animated: false);
      
      // ✅ ПРОВЕРКА КЕША ПРИ ОТКРЫТИИ
      widget.cipher.tryLoadCachedKeys(widget.targetUid, _storage).then((loaded) {
        if (loaded && mounted) {
          setState(() => _keysExchanged = true);
        }
      });
    });
    
    _listenToMessages();
    _reactions = _storage.loadReactions(widget.targetUid);

    Future.delayed(const Duration(milliseconds: 500), () {
      try {
        _socket.requestOfflineMessages(widget.targetUid);
      } catch (e) {
        debugPrint("Note: requestOfflineMessages error: $e");
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

    if (_isTyping) {
      _socket.sendTypingIndicator(widget.targetUid, false);
    }
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
        if (!_keysExchanged && mounted) {
          setState(() => _keysExchanged = true);
        }
      });
    } catch (e) {
      debugPrint("Init error: $e");
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
      }
    } catch (e) {
      debugPrint("Load history error: $e");
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
          _isLoadingMore   = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // HTTP MEDIA HELPERS
  // ──────────────────────────────────────────────────────────────────────────

  Future<String?> _uploadFileHttp(File file) async {
    try {
      var request = http.MultipartRequest('POST', Uri.parse('$SERVER_HTTP_URL/upload'));
      request.files.add(await http.MultipartFile.fromPath('file', file.path));
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode == 200) {
        var json = jsonDecode(response.body);
        if (json['status'] == 'success') return json['file_id'];
      }
    } catch (e) {
      debugPrint("HTTP Upload error: $e");
    }
    return null;
  }

  Future<String?> _downloadFileHttp(String fileId, MsgType msgType, String? fileName) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/deepdrift_media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

      final ext = _extensionForType(msgType, fileName);
      final name = fileName ?? 'media_${DateTime.now().millisecondsSinceEpoch}$ext';
      final file = File('${mediaDir.path}/$name');

      final request = http.Request('GET', Uri.parse('$SERVER_HTTP_URL/download/$fileId'));
      final response = await http.Client().send(request);
      
      if (response.statusCode == 200) {
        final sink = file.openWrite();
        await response.stream.pipe(sink);
        await sink.close();
        return file.path;
      }
    } catch (e) {
      debugPrint("HTTP Download error: $e");
    }
    return null;
  }

  Future<String?> _copyFileToMediaDir(File originalFile, MsgType msgType, String? fileName) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/deepdrift_media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final ext = _extensionForType(msgType, fileName);
      final name = fileName ?? 'media_${DateTime.now().millisecondsSinceEpoch}$ext';
      final newFile = await originalFile.copy('${mediaDir.path}/$name');
      return newFile.path;
    } catch (e) {
      return originalFile.path;
    }
  }

  // Fallback для старых Base64 сообщений
  Future<String?> _saveMediaToDiskBase64({required String base64Data, required MsgType msgType, String? fileName}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/deepdrift_media');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      final ext = _extensionForType(msgType, fileName);
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
      case MsgType.image: return '.jpg';
      case MsgType.voice: return '.m4a';
      default: return '';
    }
  }

  String _formatFileSize(dynamic sizeRaw) {
    final size = sizeRaw is int ? sizeRaw : int.tryParse(sizeRaw.toString()) ?? 0;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
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
      final type = data['type'];
      switch (type) {
        case 'message':          _handleIncomingMessage(data); break;
        case 'typing_indicator': _handleTypingIndicator(data); break;
        case 'public_key_response': _handlePublicKeyResponse(data); break;
        case 'message_read':     _handleMessageRead(data); break;
        case 'read_receipt':     _handleReadReceipt(data); break;
        case 'message_deleted':  _handleMessageDeleted(data); break;
        case 'message_edited':   _handleMessageEdited(data); break;
        case 'message_reaction': _handleMessageReaction(data); break;
      }
    });
  }

  void _handleIncomingMessage(Map<String, dynamic> data) {
    final senderUid = data['from_uid'];
    if (senderUid != widget.targetUid) return;
    final msgId = data['id']?.toString();
    if (msgId == null || _messageIds.contains(msgId)) return;

    final encrypted  = data['encrypted_text'];
    final signature  = data['signature'];
    final msgTyp     = (data['messageType'] as String? ?? 'text').toMsgType();
    final rawTime    = data['time'];

    widget.cipher.decryptText(encrypted, fromUid: widget.targetUid).then((decrypted) async {
      if (signature != null) {
        final valid = await widget.cipher.verifySignature(decrypted, signature, widget.targetUid);
        if (!valid) debugPrint("⚠️ Signature verification failed for $msgId");
      }

      String? localPath;
      if (msgTyp != MsgType.text && data['mediaData'] != null) {
        String mediaStr = data['mediaData'];
        if (mediaStr.startsWith('FILE_ID:')) {
          localPath = await _downloadFileHttp(mediaStr.substring(8), msgTyp, data['fileName']);
        } else {
          localPath = await _saveMediaToDiskBase64(base64Data: mediaStr, msgType: msgTyp, fileName: data['fileName']);
        }
      }

      final msg = {
        'id': msgId,
        'text': decrypted,
        'isMe': false,
        'time': rawTime ?? DateTime.now().millisecondsSinceEpoch,
        'from': senderUid,
        'to': widget.myUid,
        'status': 'delivered',
        'replyTo': data['replyTo'],
        'replyToId': data['replyToId'],
        'type': data['messageType'] ?? 'text',
        'filePath': localPath,
        'fileName': data['fileName'],
        'fileSize': data['fileSize'],
        'mimeType': data['mimeType'],
        'edited': data['edited'] ?? false,
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
    final x25519Key = data['x25519_key'];
    final ed25519Key = data['ed25519_key'];
    if (x25519Key != null && ed25519Key != null) {
      widget.cipher.establishSharedSecret(widget.targetUid, x25519Key, theirSignKeyB64: ed25519Key).then((_) {
        if (mounted) setState(() => _keysExchanged = true);
      });
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
    final msgId = data['message_id']?.toString();
    final newEnc = data['new_encrypted_text'];
    if (msgId == null || newEnc == null) return;
    widget.cipher.decryptText(newEnc, fromUid: widget.targetUid).then((newText) {
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) {
            _messages[idx]['text'] = newText;
            _messages[idx]['edited'] = true;
          }
        });
      }
    });
  }

  void _handleMessageReaction(Map<String, dynamic> data) {
    final msgId = data['message_id']?.toString();
    final emoji = data['emoji'] as String?;
    final action = data['action'] as String?;
    if (msgId == null || emoji == null || !mounted) return;
    setState(() {
      _reactions.putIfAbsent(msgId, () => {});
      if (action == 'add') _reactions[msgId]!.add(emoji);
      else if (action == 'remove') _reactions[msgId]!.remove(emoji);
    });
    _storage.saveReactions(widget.targetUid, _reactions);
  }

  Future<void> _markAllAsRead() async {
    final unreadIds = _messages.where((m) => m['from'] == widget.targetUid && m['status'] != 'read').map((m) => m['id'].toString()).toList();
    for (final id in unreadIds) _sendReadReceipt(id);
    if (unreadIds.isNotEmpty) await _storage.markAllAsRead(widget.targetUid);
  }

  void _sendReadReceipt(String messageId) {
    _socket.sendReadReceipt(widget.targetUid, messageId);
  }

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
    String?  text,
    String   messageType = 'text',
    String?  mediaData,
    String?  filePath,
    String?  fileName,
    int?     fileSize,
    String?  mimeType,
  }) async {
    if (_editingMessageId != null) {
      await _saveEditedMessage();
      return;
    }

    final messageText = text ?? _messageController.text.trim();
    if (messageText.isEmpty && mediaData == null) return;

    // ✅ ПРОВЕРКА КЕША ПЕРЕД ШИФРОВАНИЕМ
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

    final msgId = _uuid.v4();
    final now   = DateTime.now().millisecondsSinceEpoch;
    final replyId   = _replyToId;
    final replyText = _replyToText;

    try {
      final encrypted = await widget.cipher.encryptText(messageText, targetUid: widget.targetUid);
      final signature = await widget.cipher.signMessage(messageText);

      final myMsg = {
        'id': msgId, 'text': messageText, 'isMe': true, 'time': now,
        'from': widget.myUid, 'to': widget.targetUid, 'status': 'pending',
        'replyTo': replyText, 'replyToId': replyId, 'type': messageType,
        'filePath': filePath, 'fileName': fileName, 'fileSize': fileSize,
        'mimeType': mimeType, 'edited': false,
      };

      if (mounted) {
        setState(() {
          _messages.add(myMsg);
          _messageIds.add(msgId);
          _messageController.clear();
          _replyToText = null;
          _replyToId = null;
        });
        _scrollToBottom();
      }

      _socket.sendMessage(
        widget.targetUid, encrypted, signature, msgId,
        replyToId: replyId, messageType: messageType, mediaData: mediaData,
        fileName: fileName, fileSize: fileSize, mimeType: mimeType,
      );

      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'sent';
        });
      }
      await _storage.saveMessage(widget.targetUid, myMsg);
    } catch (e) {
      _showError("Failed to send: $e");
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

      setState(() => _isSendingFile = true);
      for (final image in images) {
        File file = File(image.path);
        String? fileId = await _uploadFileHttp(file);
        if (fileId == null) continue;

        final localPath = await _copyFileToMediaDir(file, MsgType.image, image.name);
        await _sendMessage(
          text: '📷 Photo',
          messageType: 'image',
          mediaData: 'FILE_ID:$fileId',
          filePath: localPath,
          fileName: image.name,
          fileSize: await file.length(),
          mimeType: 'image/jpeg',
        );
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      _showError('Failed to send photos: $e');
    } finally {
      if (mounted) setState(() => _isSendingFile = false);
    }
  }

  Future<void> _sendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return;
      final file = File(result.files.first.path!);
      
      setState(() => _isSendingFile = true);
      String? fileId = await _uploadFileHttp(file);
      if (fileId != null) {
        final localPath = await _copyFileToMediaDir(file, MsgType.file, result.files.first.name);
        await _sendMessage(
          text: '📎 ${result.files.first.name}',
          messageType: 'file',
          mediaData: 'FILE_ID:$fileId',
          filePath: localPath,
          fileName: result.files.first.name,
          fileSize: await file.length(),
          mimeType: _mimeTypeFromExtension(result.files.first.name),
        );
      }
    } catch (e) {
      _showError('Failed to send file: $e');
    } finally {
      if (mounted) setState(() => _isSendingFile = false);
    }
  }

  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      setState(() { _isRecording = true; _voiceTempPath = path; _recordingDuration = 0; });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (t) { if (mounted) setState(() => _recordingDuration++); });
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      final path = await _audioRecorder.stop();
      _recordingTimer?.cancel();
      setState(() => _isRecording = false);
      if (path != null && _recordingDuration >= 1) {
        setState(() => _isSendingFile = true);
        File file = File(path);
        String? fileId = await _uploadFileHttp(file);
        if (fileId != null) {
          final localPath = await _copyFileToMediaDir(file, MsgType.voice, "voice.m4a");
          await _sendMessage(
            text: '🎤 Voice message',
            messageType: 'voice',
            mediaData: 'FILE_ID:$fileId',
            filePath: localPath,
            fileName: 'voice.m4a',
            fileSize: await file.length(),
            mimeType: 'audio/m4a',
          );
        }
        _cleanTempVoiceFile();
      }
    } finally {
      if (mounted) setState(() => _isSendingFile = false);
    }
  }

  Future<void> _cancelRecording() async {
    await _audioRecorder.stop();
    _recordingTimer?.cancel();
    _cleanTempVoiceFile();
    setState(() { _isRecording = false; _recordingDuration = 0; });
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
        setState(() => _playingMessageId = msgId);
        _audioPlayer.onPlayerComplete.first.then((_) { if (mounted) setState(() => _playingMessageId = null); });
      }
    } catch (e) { _showError('Failed to play: $e'); }
  }

  void _startEditingMessage(Map<String, dynamic> message) {
    setState(() { _editingMessageId = message['id']; _messageController.text = message['text'] ?? ''; });
  }

  Future<void> _saveEditedMessage() async {
    if (_editingMessageId == null) return;
    final newText = _messageController.text.trim();
    if (newText.isNotEmpty) {
      final enc = await widget.cipher.encryptText(newText, targetUid: widget.targetUid);
      final sig = await widget.cipher.signMessage(newText);
      _socket.sendEditMessage(widget.targetUid, _editingMessageId!, enc, sig);
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == _editingMessageId);
        if (idx != -1) { _messages[idx]['text'] = newText; _messages[idx]['edited'] = true; }
        _editingMessageId = null; _messageController.clear();
      });
    }
  }

  void _addReaction(String messageId, String emoji) {
    _socket.sendReaction(widget.targetUid, messageId, emoji, 'add');
    setState(() { _reactions.putIfAbsent(messageId, () => {}).add(emoji); });
    _storage.saveReactions(widget.targetUid, _reactions);
  }

  void _removeReaction(String messageId, String emoji) {
    _socket.sendReaction(widget.targetUid, messageId, emoji, 'remove');
    setState(() { _reactions[messageId]?.remove(emoji); });
    _storage.saveReactions(widget.targetUid, _reactions);
  }

  void _showError(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  void _scrollToBottom({bool animated = true}) {
    if (!_scrollController.hasClients) return;
    Future.delayed(const Duration(milliseconds: 50), () {
      final pos = _scrollController.position.maxScrollExtent;
      if (animated) _scrollController.animateTo(pos, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      else _scrollController.jumpTo(pos);
    });
  }

  String _formatTime(dynamic t) {
    final dt = (t is int) ? DateTime.fromMillisecondsSinceEpoch(t) : DateTime.tryParse(t.toString()) ?? DateTime.now();
    return DateFormat.Hm().format(dt);
  }

  String _formatRecordingTime(int s) => "${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}";

  void _setReplyTo(Map<String, dynamic> m) => setState(() { _replyToText = m['text']; _replyToId = m['id']; });
  void _cancelReply() => setState(() { _replyToText = null; _replyToId = null; });
  void _toggleSearch() => setState(() { _isSearching = !_isSearching; if (!_isSearching) _searchController.clear(); });
  void _copyMessageText(String t) { Clipboard.setData(ClipboardData(text: t)); _showError('Copied!'); }

  List<Map<String, dynamic>> get _filteredMessages {
    if (!_isSearching || _searchController.text.isEmpty) return _messages;
    final q = _searchController.text.toLowerCase();
    return _messages.where((m) => (m['text'] ?? '').toLowerCase().contains(q)).toList();
  }

  String _mimeTypeFromExtension(String n) {
    final e = n.split('.').last.toLowerCase();
    return {'pdf': 'application/pdf', 'zip': 'application/zip', 'mp3': 'audio/mpeg', 'mp4': 'video/mp4'}[e] ?? 'application/octet-stream';
  }

  IconData _iconForMime(String? m) => (m?.startsWith('image/') ?? false) ? Icons.image : Icons.attach_file;

  void _showFullImageFromFile(String p) => showDialog(context: context, builder: (c) => Dialog(backgroundColor: Colors.black, child: InteractiveViewer(child: Image.file(File(p)))));
  
  Future<void> _openFile(String? p, String n) async {
    if (p != null && File(p).existsSync()) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved at: $p')));
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final displayName = _storage.getContactDisplayName(widget.targetUid);
    final displayMessages = _filteredMessages;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: _buildAppBar(displayName),
      body: Column(
        children: [
          if (_replyToText != null) _buildReplyBanner(),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: displayMessages.length + (_isLoadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (_isLoadingMore && index == 0) return const Center(child: CircularProgressIndicator());
                final mIdx = _isLoadingMore ? index - 1 : index;
                return _buildMessage(displayMessages[mIdx], mIdx);
              },
            ),
          ),
          if (_editingMessageId != null) _buildEditBanner(),
          _buildInputArea(),
        ],
      ),
    );
  }

  AppBar _buildAppBar(String name) => AppBar(
    backgroundColor: const Color(0xFF1A1F3C),
    title: _isSearching
      ? TextField(controller: _searchController, autofocus: true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Search...', border: InputBorder.none), onChanged: (v) => setState(() {}))
      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: GoogleFonts.orbitron(fontSize: 14)),
          if (_targetIsTyping) Text('typing...', style: const TextStyle(fontSize: 10, color: Colors.cyan))
          else if (_keysExchanged) const Row(children: [Icon(Icons.lock, size: 10, color: Colors.green), SizedBox(width: 4), Text('Encrypted', style: TextStyle(fontSize: 10, color: Colors.green))]),
        ]),
    actions: [IconButton(icon: Icon(_isSearching ? Icons.close : Icons.search), onPressed: _toggleSearch)],
  );

  Widget _buildReplyBanner() => Container(padding: const EdgeInsets.all(8), color: const Color(0xFF1A1F3C), child: Row(children: [const Icon(Icons.reply, size: 16), const SizedBox(width: 8), Expanded(child: Text(_replyToText!, maxLines: 1)), IconButton(icon: const Icon(Icons.close, size: 16), onPressed: _cancelReply)]));

  Widget _buildEditBanner() => Container(padding: const EdgeInsets.all(8), color: const Color(0xFF1A1F3C), child: Row(children: [const Icon(Icons.edit, size: 16), const SizedBox(width: 8), const Expanded(child: Text('Editing...')), TextButton(onPressed: () => setState(() { _editingMessageId = null; _messageController.clear(); }), child: const Text('Cancel'))]));

  Widget _buildInputArea() {
    if (_isRecording) {
      return Container(padding: const EdgeInsets.all(8), child: SafeArea(child: Row(children: [Expanded(child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(20)), child: Text(_formatRecordingTime(_recordingDuration)))), IconButton(icon: const Icon(Icons.close, color: Colors.red), onPressed: _cancelRecording), IconButton(icon: const Icon(Icons.send, color: Colors.cyan), onPressed: _stopRecordingAndSend)])));
    }
    return Container(padding: const EdgeInsets.all(8), decoration: const BoxDecoration(color: Color(0xFF1A1F3C), border: Border(top: BorderSide(color: Colors.cyan, width: 0.5))), child: SafeArea(child: Row(children: [
      PopupMenuButton<String>(icon: const Icon(Icons.add_circle_outline), onSelected: (v) { if (v == 'file') _sendFile(); else _sendPhoto(source: v == 'camera' ? ImageSource.camera : ImageSource.gallery); }, itemBuilder: (c) => [_popupItem('gallery', Icons.photo, 'Gallery'), _popupItem('camera', Icons.camera_alt, 'Camera'), _popupItem('file', Icons.attach_file, 'File')]),
      if (!_isSendingFile) IconButton(icon: const Icon(Icons.mic), onPressed: _startRecording),
      if (_isSendingFile) const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
      Expanded(child: TextField(controller: _messageController, maxLines: null, decoration: const InputDecoration(hintText: 'Message...', border: InputBorder.none))),
      IconButton(icon: const Icon(Icons.send), onPressed: _sendMessage),
    ])));
  }

  PopupMenuItem<String> _popupItem(String v, IconData i, String l) => PopupMenuItem(value: v, child: Row(children: [Icon(i, color: Colors.cyan, size: 20), const SizedBox(width: 12), Text(l)]));
}

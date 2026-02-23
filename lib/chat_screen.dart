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

  // Reactions: messageId → {emoji}
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
    
    // Загрузка истории и скролл вниз
    _loadRecentHistory().then((_) {
      _markAllAsRead();
      _scrollToBottom(animated: false);
    });
    
    _listenToMessages();
    _reactions = _storage.loadReactions(widget.targetUid);

    // ✅ ИСПРАВЛЕНИЕ 1: Запрос оффлайн сообщений
    // Ждем немного, чтобы сокет успел инициализироваться, если экран только открыт
    Future.delayed(const Duration(milliseconds: 500), () {
      try {
        // Убедитесь, что метод requestOfflineMessages существует в SocketService
        _socket.requestOfflineMessages(widget.targetUid);
      } catch (e) {
        debugPrint("Note: requestOfflineMessages might not be implemented in SocketService yet.");
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
  // Key exchange
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _initializeSecureChat() async {
    try {
      if (widget.cipher.hasSharedSecret(widget.targetUid)) {
        if (mounted) setState(() => _keysExchanged = true);
        debugPrint("✅ Already have shared secret with ${widget.targetUid}");
        return;
      }

      _socket.requestPublicKey(widget.targetUid);
      debugPrint("🔑 Requesting key exchange with ${widget.targetUid}");

      _keyExchangeTimeout = Timer(KEY_EXCHANGE_TIMEOUT, () {
        if (!_keysExchanged && mounted) {
          debugPrint("⏱️ Key exchange timeout");
          setState(() => _keysExchanged = true);
        }
      });
    } catch (e) {
      debugPrint("Init error: $e");
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // History loading
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _loadRecentHistory() async {
    try {
      final history = _storage.getRecentMessages(
        widget.targetUid,
        limit: MESSAGES_PER_PAGE,
      );
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
      debugPrint("Load history error: $e");
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_isLoadingMore || !_hasMoreMessages) return;
    setState(() => _isLoadingMore = true);

    try {
      final older = _storage.getOlderMessages(
        widget.targetUid,
        _messages.length,
        limit: MESSAGES_PER_PAGE,
      );
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
      debugPrint("Load more error: $e");
      if (mounted) setState(() => _isLoadingMore = false);
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

  // ──────────────────────────────────────────────────────────────────────────
  // Incoming message handlers
  // ──────────────────────────────────────────────────────────────────────────

  void _handleIncomingMessage(Map<String, dynamic> data) {
    final senderUid = data['from_uid'];
    if (senderUid != widget.targetUid) return;

    final msgId = data['id']?.toString();
    if (msgId == null || _messageIds.contains(msgId)) return;

    final encrypted  = data['encrypted_text'];
    final signature  = data['signature'];
    final msgTyp     = (data['messageType'] as String? ?? 'text').toMsgType();
    final rawTime    = data['time'];

    widget.cipher
        .decryptText(encrypted, fromUid: widget.targetUid)
        .then((decrypted) async {
      if (signature != null) {
        final valid = await widget.cipher.verifySignature(
          decrypted,
          signature,
          widget.targetUid,
        );
        if (!valid) debugPrint("⚠️ Signature verification failed for $msgId");
      }

      String? localPath;
      if (msgTyp != MsgType.text && data['mediaData'] != null) {
        localPath = await _saveMediaToDisk(
          base64Data: data['mediaData'],
          msgType:    msgTyp,
          fileName:   data['fileName'],
        );
      }

      final msg = {
        'id':         msgId,
        'text':       decrypted,
        'isMe':       false,
        'time':       rawTime ?? DateTime.now().millisecondsSinceEpoch,
        'from':       senderUid,
        'to':         widget.myUid,
        'status':     'delivered',
        'replyTo':    data['replyTo'],
        'replyToId':  data['replyToId'],
        'type':       data['messageType'] ?? 'text',
        'filePath':   localPath,
        'fileName':   data['fileName'],
        'fileSize':   data['fileSize'],
        'mimeType':   data['mimeType'],
        'edited':     data['edited']   ?? false,
        'editedAt':   data['editedAt'],
        'forwardedFrom': data['forwarded_from'],
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
    }).catchError((e) {
      debugPrint("Decrypt error: $e");
    });
  }

  void _handleTypingIndicator(Map<String, dynamic> data) {
    if (data['from_uid'] == widget.targetUid && mounted) {
      setState(() => _targetIsTyping = data['typing'] == true);
      if (_targetIsTyping) {
        _scrollToBottom();
      }
    }
  }

  void _handlePublicKeyResponse(Map<String, dynamic> data) {
    if (data['target_uid'] != widget.targetUid) return;
    final x25519Key  = data['x25519_key'];
    final ed25519Key = data['ed25519_key'];

    if (x25519Key != null && ed25519Key != null) {
      widget.cipher
          .establishSharedSecret(widget.targetUid, x25519Key,
              theirSignKeyB64: ed25519Key)
          .then((_) {
        if (mounted) setState(() => _keysExchanged = true);
        debugPrint("✅ Keys exchanged with ${widget.targetUid}");
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
    final msgId          = data['message_id']?.toString();
    final newEncrypted   = data['new_encrypted_text'];
    if (msgId == null || newEncrypted == null) return;

    widget.cipher.decryptText(newEncrypted, fromUid: widget.targetUid)
        .then((newText) {
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) {
            _messages[idx]['text']     = newText;
            _messages[idx]['edited']   = true;
            _messages[idx]['editedAt'] =
                DateTime.now().millisecondsSinceEpoch;
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

    for (final id in unreadIds) {
      _sendReadReceipt(id);
    }
    if (unreadIds.isNotEmpty) {
      await _storage.markAllAsRead(widget.targetUid);
    }
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
  // Media helpers
  // ──────────────────────────────────────────────────────────────────────────

  Future<String?> _saveMediaToDisk({
    required String base64Data,
    required MsgType msgType,
    String? fileName,
  }) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = Directory('${appDir.path}/deepdrift_media');
      if (!await mediaDir.exists()) {
        await mediaDir.create(recursive: true);
      }

      final ext = _extensionForType(msgType, fileName);
      final name = fileName ?? 'media_${DateTime.now().millisecondsSinceEpoch}$ext';
      final file = File('${mediaDir.path}/$name');
      await file.writeAsBytes(base64Decode(base64Data));
      return file.path;
    } catch (e) {
      debugPrint("Save media error: $e");
      return null;
    }
  }

  String _extensionForType(MsgType type, String? fileName) {
    if (fileName != null) {
      final dot = fileName.lastIndexOf('.');
      if (dot != -1) return fileName.substring(dot);
    }
    switch (type) {
      case MsgType.image: return '.jpg';
      case MsgType.voice: return '.m4a';
      case MsgType.file:  return '';
      default:            return '';
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
      try {
        File(_voiceTempPath!).deleteSync();
      } catch (_) {}
      _voiceTempPath = null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Send
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

    final msgId = _uuid.v4();
    final now   = DateTime.now().millisecondsSinceEpoch;

    final replyId   = _replyToId;
    final replyText = _replyToText;

    try {
      final encrypted = await widget.cipher.encryptText(
        messageText,
        targetUid: widget.targetUid,
      );
      final signature = await widget.cipher.signMessage(messageText);

      final myMsg = {
        'id':         msgId,
        'text':       messageText,
        'isMe':       true,
        'time':       now,
        'from':       widget.myUid,
        'to':         widget.targetUid,
        'status':     'pending',
        'replyTo':    replyText,
        'replyToId':  replyId,
        'type':       messageType,
        'filePath':   filePath,
        'fileName':   fileName,
        'fileSize':   fileSize,
        'mimeType':   mimeType,
        'edited':     false,
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
        widget.targetUid,
        encrypted,
        signature,
        msgId,
        replyToId:   replyId,
        messageType: messageType,
        mediaData:   mediaData,
        fileName:    fileName,
        fileSize:    fileSize,
        mimeType:    mimeType,
      );

      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'sent';
        });
      }

      await _storage.saveMessage(widget.targetUid, myMsg);
    } catch (e) {
      debugPrint("Send error: $e");
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'failed';
        });
      }
      _showError("Failed to send: $e");
    }
  }

  // ─── Отправка фото ────────────────────────────────────────────────────────
  Future<void> _sendPhoto({ImageSource source = ImageSource.gallery}) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source:       source,
        maxWidth:     1920,
        maxHeight:    1920,
        imageQuality: 85,
      );
      if (image == null) return;

      final bytes      = await image.readAsBytes();
      final base64Img  = base64Encode(bytes);
      final fileName   = image.name;
      final fileSize   = bytes.length;

      final localPath = await _saveMediaToDisk(
        base64Data: base64Img,
        msgType:    MsgType.image,
        fileName:   fileName,
      );

      await _sendMessage(
        text:        '📷 Photo',
        messageType: 'image',
        mediaData:   base64Img,
        filePath:    localPath,
        fileName:    fileName,
        fileSize:    fileSize,
        mimeType:    'image/jpeg',
      );
    } catch (e) {
      _showError('Failed to send photo: $e');
    }
  }

  // ─── Отправка файла ───────────────────────────────────────────────────────
  Future<void> _sendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type:         FileType.any,
        withData:     false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty) return;

      final picked   = result.files.first;
      final filePath = picked.path;
      if (filePath == null) return;

      final file     = File(filePath);
      final fileSize = await file.length();

      if (fileSize > 20 * 1024 * 1024) {
        _showError('File too large. Maximum size is 20 MB.');
        return;
      }

      setState(() => _isSendingFile = true);

      final bytes     = await file.readAsBytes();
      final base64Data = base64Encode(bytes);
      final fileName  = picked.name;
      final mimeType  = _mimeTypeFromExtension(fileName);

      final localPath = await _saveMediaToDisk(
        base64Data: base64Data,
        msgType:    MsgType.file,
        fileName:   fileName,
      );

      await _sendMessage(
        text:        '📎 $fileName',
        messageType: 'file',
        mediaData:   base64Data,
        filePath:    localPath,
        fileName:    fileName,
        fileSize:    fileSize,
        mimeType:    mimeType,
      );
    } catch (e) {
      _showError('Failed to send file: $e');
    } finally {
      if (mounted) setState(() => _isSendingFile = false);
    }
  }

  // ─── Голосовые сообщения ──────────────────────────────────────────────────
  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final tempDir  = await getTemporaryDirectory();
      final path =
          '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _audioRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      
      setState(() {
        _isRecording   = true;
        _voiceTempPath = path;
        _recordingDuration = 0;
      });
      
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() => _recordingDuration++);
        }
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
      
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recordingDuration = 0;
        });
      }
    } catch (e) {
      print('Error cancelling recording: $e');
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      final path = await _audioRecorder.stop();
      _recordingTimer?.cancel();
      setState(() => _isRecording = false);

      if (path != null) {
        _voiceTempPath = path;
        final file     = File(path);
        
        if (_recordingDuration < 1) {
           _cleanTempVoiceFile();
           return;
        }
        
        final bytes    = await file.readAsBytes();
        final base64Audio = base64Encode(bytes);
        final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

        final localPath = await _saveMediaToDisk(
          base64Data: base64Audio,
          msgType:    MsgType.voice,
          fileName:   fileName,
        );

        await _sendMessage(
          text:        '🎤 Voice message',
          messageType: 'voice',
          mediaData:   base64Audio,
          filePath:    localPath,
          fileName:    fileName,
          fileSize:    bytes.length,
          mimeType:    'audio/m4a',
        );

        _cleanTempVoiceFile();
      }
    } catch (e) {
      _showError('Error sending voice: $e');
      _cancelRecording();
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
        _showError('Voice file not available');
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

  // ─── Edit ─────────────────────────────────────────────────────────────────
  void _startEditingMessage(Map<String, dynamic> message) {
    setState(() {
      _editingMessageId = message['id']?.toString();
      _messageController.text = message['text'] ?? '';
    });
  }

  Future<void> _saveEditedMessage() async {
    if (_editingMessageId == null) return;
    final newText = _messageController.text.trim();
    if (newText.isEmpty) return;

    try {
      final encrypted = await widget.cipher.encryptText(
        newText,
        targetUid: widget.targetUid,
      );
      final signature = await widget.cipher.signMessage(newText);

      _socket.sendEditMessage(
        widget.targetUid,
        _editingMessageId!,
        encrypted,
        signature,
      );

      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == _editingMessageId);
        if (idx != -1) {
          _messages[idx]['text']     = newText;
          _messages[idx]['edited']   = true;
          _messages[idx]['editedAt'] =
              DateTime.now().millisecondsSinceEpoch;
        }
        _editingMessageId = null;
        _messageController.clear();
      });
    } catch (e) {
      _showError('Failed to edit: $e');
    }
  }

  // ─── Delete ───────────────────────────────────────────────────────────────
  Future<void> _deleteMessage(String messageId,
      {required bool deleteForEveryone}) async {
    if (deleteForEveryone) {
      _socket.sendDeleteMessage(widget.targetUid, messageId);
    }
    setState(() {
      _messages.removeWhere((m) => m['id'] == messageId);
      _messageIds.remove(messageId);
    });
    await _storage.deleteMessage(widget.targetUid, messageId);
  }

  // ─── Reactions ────────────────────────────────────────────────────────────
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
    setState(() {
      _reactions[messageId]?.remove(emoji);
    });
    _storage.saveReactions(widget.targetUid, _reactions);
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
          curve:    Curves.easeOut,
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
  
  String _formatRecordingTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _setReplyTo(Map<String, dynamic> message) {
    setState(() {
      _replyToText = message['text'];
      _replyToId   = message['id']?.toString();
    });
  }

  void _cancelReply() => setState(() {
        _replyToText = null;
        _replyToId   = null;
      });

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
    return _messages
        .where((m) => (m['text'] ?? '').toLowerCase().contains(q))
        .toList();
  }

  String _mimeTypeFromExtension(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    const mimes = {
      'pdf':  'application/pdf',
      'doc':  'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls':  'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt':  'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt':  'text/plain',
      'zip':  'application/zip',
      'rar':  'application/x-rar-compressed',
      'mp3':  'audio/mpeg',
      'mp4':  'video/mp4',
      'mov':  'video/quicktime',
      'png':  'image/png',
      'jpg':  'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif':  'image/gif',
    };
    return mimes[ext] ?? 'application/octet-stream';
  }

  IconData _iconForMime(String? mimeType) {
    if (mimeType == null) return Icons.attach_file;
    if (mimeType.startsWith('image/')) return Icons.image;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.contains('pdf'))      return Icons.picture_as_pdf;
    if (mimeType.contains('word') || mimeType.contains('msword'))
      return Icons.description;
    if (mimeType.contains('excel') || mimeType.contains('spreadsheet'))
      return Icons.table_chart;
    if (mimeType.contains('zip') || mimeType.contains('rar'))
      return Icons.folder_zip;
    return Icons.attach_file;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Message actions sheet
  // ──────────────────────────────────────────────────────────────────────────

  void _showMessageActions(Map<String, dynamic> message) {
    final isMe = message['from'] == widget.myUid;

    showModalBottomSheet(
      context:         context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message['type'] == 'text')
                _actionTile(Icons.copy, 'Copy', () {
                  Navigator.pop(context);
                  _copyMessageText(message['text'] ?? '');
                }),
              _actionTile(Icons.reply, 'Reply', () {
                Navigator.pop(context);
                _setReplyTo(message);
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
                  _confirmDelete(message['id'].toString(),
                      deleteForEveryone: true);
                }, color: Colors.red),
              _actionTile(Icons.delete_outline, 'Delete for me', () {
                Navigator.pop(context);
                _confirmDelete(message['id'].toString(),
                    deleteForEveryone: false);
              }, color: Colors.orange),
            ],
          ),
        ),
      ),
    );
  }

  ListTile _actionTile(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color color = Colors.cyan,
  }) =>
      ListTile(
        leading: Icon(icon, color: color),
        title: Text(label, style: TextStyle(color: color == Colors.cyan ? Colors.white : color)),
        onTap: onTap,
      );

  void _confirmDelete(String messageId,
      {required bool deleteForEveryone}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Delete message?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          deleteForEveryone
              ? 'This message will be deleted for everyone'
              : 'This message will only be deleted for you',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteMessage(messageId,
                  deleteForEveryone: deleteForEveryone);
            },
            child: const Text('DELETE',
                style: TextStyle(color: Colors.red)),
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
          children: reactions
              .map((emoji) => GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _addReaction(messageId, emoji);
                    },
                    child:
                        Text(emoji, style: const TextStyle(fontSize: 32)),
                  ))
              .toList(),
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
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  gradient: isMe
                      ? const LinearGradient(
                          colors: [Color(0xFF00D4FF), Color(0xFF0099CC)],
                        )
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
                      color:      Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset:     const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Reply preview
                    if (msg['replyTo'] != null) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin:  const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color:  Colors.black.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: const Border(
                            left: BorderSide(color: Colors.cyanAccent, width: 3),
                          ),
                        ),
                        child: Text(
                          msg['replyTo'],
                          style: TextStyle(
                            color:     Colors.white.withValues(alpha: 0.65),
                            fontSize:  12,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines:  2,
                          overflow:  TextOverflow.ellipsis,
                        ),
                      ),
                    ],

                    // Content
                    _buildMessageContent(msg, msgType, isMe),

                    const SizedBox(height: 4),

                    // Meta row
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg['edited'] == true)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Text(
                              'edited',
                              style: TextStyle(
                                color:     Colors.white54,
                                fontSize:  10,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        Text(
                          _formatTime(msg['time']),
                          style: TextStyle(
                            color:    Colors.white.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          _buildStatusIcon(msg['status']),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // Reactions row
              if (reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: reactions
                        .map((emoji) => GestureDetector(
                              onTap: () => _removeReaction(
                                  msg['id'].toString(), emoji),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1A1F3C),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: Colors.cyan.withValues(alpha: 0.4)),
                                ),
                                child: Text(emoji,
                                    style: const TextStyle(fontSize: 14)),
                              ),
                            ))
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageContent(
      Map<String, dynamic> msg, MsgType msgType, bool isMe) {
    switch (msgType) {
      case MsgType.image:
        return _buildImageContent(msg);
      case MsgType.voice:
        return _buildVoiceContent(msg, isMe);
      case MsgType.file:
        return _buildFileContent(msg, isMe);
      default:
        return Text(
          msg['text'] ?? '',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        );
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
            width:   200,
            fit:     BoxFit.cover,
            errorBuilder: (_, __, ___) =>
                _imagePlaceholder(msg['fileName']),
          ),
        ),
      );
    }
    return _imagePlaceholder(msg['fileName']);
  }

  Widget _imagePlaceholder(String? name) => Container(
        width:  200,
        height: 120,
        decoration: BoxDecoration(
          color:        Colors.black26,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.broken_image, color: Colors.white38, size: 40),
            if (name != null)
              Text(name,
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ],
        ),
      );

  Widget _buildVoiceContent(Map<String, dynamic> msg, bool isMe) {
    final msgId      = msg['id']?.toString();
    final isPlaying  = _playingMessageId == msgId;

    return GestureDetector(
      onTap: () => _playVoiceMessage(msg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPlaying ? Icons.pause_circle : Icons.play_circle,
            color: isMe ? Colors.white : Colors.cyanAccent,
            size:  36,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Voice message',
                style: TextStyle(
                  color:    isMe ? Colors.white : Colors.white,
                  fontSize: 14,
                ),
              ),
              if (msg['fileSize'] != null)
                Text(
                  _formatFileSize(msg['fileSize']),
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11),
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
          color:        Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(
              color: (isMe ? Colors.white : Colors.cyan).withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width:  44,
              height: 44,
              decoration: BoxDecoration(
                color:        Colors.cyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _iconForMime(mimeType),
                color: Colors.cyanAccent,
                size:  26,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: const TextStyle(
                        color:    Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                    maxLines:  2,
                    overflow:  TextOverflow.ellipsis,
                  ),
                  if (fileSize != null)
                    Text(
                      _formatFileSize(fileSize),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11),
                    ),
                  Text(
                    filePath != null && File(filePath).existsSync()
                        ? 'Tap to open'
                        : 'File unavailable',
                    style: TextStyle(
                      color:    filePath != null && File(filePath).existsSync()
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
      case 'read':
        return const Icon(Icons.done_all, size: 14, color: Colors.cyanAccent);
      case 'delivered':
        return const Icon(Icons.done_all, size: 14, color: Colors.white54);
      case 'sent':
        return const Icon(Icons.check, size: 14, color: Colors.white54);
      case 'pending':
        return const Icon(Icons.access_time, size: 14, color: Colors.white38);
      case 'failed':
        return const Icon(Icons.error_outline, size: 14, color: Colors.redAccent);
      default:
        return const SizedBox.shrink();
    }
  }

  void _showFullImageFromFile(String filePath) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        child: InteractiveViewer(
          child: Image.file(File(filePath)),
        ),
      ),
    );
  }

  Future<void> _openFile(String? filePath, String fileName) async {
    if (filePath == null || !File(filePath).existsSync()) {
      _showError('File not available on this device');
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved at: $filePath'),
        action: SnackBarAction(
          label: 'OK',
          onPressed: () {},
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final displayName    = _storage.getContactDisplayName(widget.targetUid);
    final displayMessages = _filteredMessages;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: _buildAppBar(displayName),
      body: Column(
        children: [
          // Reply banner
          if (_replyToText != null)
            _buildReplyBanner(),

          // Messages list
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount:  displayMessages.length + (_isLoadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (_isLoadingMore && index == 0) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child:   CircularProgressIndicator(
                          color: Colors.cyan),
                    ),
                  );
                }
                final msgIndex = _isLoadingMore ? index - 1 : index;
                return _buildMessage(displayMessages[msgIndex], msgIndex);
              },
            ),
          ),

          // Edit banner
          if (_editingMessageId != null)
            _buildEditBanner(),

          // Input area (Standard OR Recording)
          _buildInputArea(),
        ],
      ),
    );
  }

  AppBar _buildAppBar(String displayName) => AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        titleSpacing: 0,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus:  true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText:      'Search messages...',
                  hintStyle:     TextStyle(color: Colors.white54),
                  border:        InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8),
                ),
                onChanged: (_) => setState(() {}),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(displayName,
                      style: GoogleFonts.orbitron(fontSize: 14)),
                  if (_targetIsTyping)
                    Text('typing...',
                        style: GoogleFonts.robotoMono(
                          fontSize:  10,
                          color:     Colors.cyan,
                          fontStyle: FontStyle.italic,
                        ))
                  else if (_keysExchanged)
                    Row(children: [
                      const Icon(Icons.lock, size: 11, color: Colors.green),
                      const SizedBox(width: 3),
                      Text('End-to-end encrypted',
                          style: GoogleFonts.robotoMono(
                              fontSize: 10, color: Colors.green)),
                    ]),
                ],
              ),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: _toggleSearch,
          ),
        ],
      );

  Widget _buildReplyBanner() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color:   const Color(0xFF1A1F3C),
        child: Row(
          children: [
            const Icon(Icons.reply, color: Colors.cyan, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _replyToText!,
                style:    const TextStyle(color: Colors.white70),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon:      const Icon(Icons.close, color: Colors.white54, size: 20),
              onPressed: _cancelReply,
              padding:   EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      );

  Widget _buildEditBanner() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color:   const Color(0xFF1A1F3C),
        child: Row(
          children: [
            const Icon(Icons.edit, color: Colors.cyan, size: 16),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Editing message',
                  style: TextStyle(color: Colors.cyan, fontSize: 13)),
            ),
            TextButton(
              onPressed: () => setState(() {
                _editingMessageId = null;
                _messageController.clear();
              }),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      );

  // ✅ ИСПРАВЛЕНИЕ 2: Обернули контент в SafeArea
  Widget _buildInputArea() {
    // Вариант 1: Идет запись голоса
    if (_isRecording) {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: const BoxDecoration(
          color: Color(0xFF1A1F3C),
          border: Border(top: BorderSide(color: Colors.red, width: 0.5)),
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Colors.red,
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
                      const Text(
                        'Recording...',
                        style: TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Cancel button
              CircleAvatar(
                backgroundColor: Colors.white10,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.red),
                  onPressed: _cancelRecording,
                ),
              ),
              const SizedBox(width: 8),
              // Send button
              CircleAvatar(
                backgroundColor: const Color(0xFF00D9FF),
                child: IconButton(
                  icon: const Icon(Icons.arrow_upward, color: Colors.black),
                  onPressed: _stopRecordingAndSend,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Вариант 2: Обычный ввод текста
    return Container(
        padding:   const EdgeInsets.all(8),
        decoration: const BoxDecoration(
          color:  Color(0xFF1A1F3C),
          border: Border(top: BorderSide(color: Colors.cyan, width: 0.5)),
        ),
        child: SafeArea(
          child: Row(
            children: [
              // Attach menu
              PopupMenuButton<String>(
                color:      const Color(0xFF1A1F3C),
                icon:       const Icon(Icons.add_circle_outline,
                    color: Colors.cyan),
                onSelected: (value) {
                  switch (value) {
                    case 'photo_gallery':
                      _sendPhoto(source: ImageSource.gallery);
                      break;
                    case 'photo_camera':
                      _sendPhoto(source: ImageSource.camera);
                      break;
                    case 'file':
                      _sendFile();
                      break;
                  }
                },
                itemBuilder: (_) => [
                  _popupItem('photo_gallery', Icons.photo_library,
                      'Photo from gallery'),
                  _popupItem('photo_camera', Icons.camera_alt, 'Take photo'),
                  _popupItem('file', Icons.attach_file, 'Send file'),
                ],
              ),

              // Voice record button (Start)
              if (!_isSendingFile)
                IconButton(
                  icon: const Icon(Icons.mic, color: Colors.cyan),
                  onPressed: _startRecording,
                ),

              // File upload indicator
              if (_isSendingFile)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child:   SizedBox(
                    width:  20,
                    height: 20,
                    child:  CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.cyan),
                  ),
                ),

              // Text field
              Expanded(
                child: TextField(
                  controller: _messageController,
                  style:      const TextStyle(color: Colors.white),
                  maxLines:   null,
                  decoration: InputDecoration(
                    hintText: _editingMessageId != null
                        ? 'Edit message...'
                        : 'Type a message...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    border:    InputBorder.none,
                  ),
                  onTap: () {
                     // Скролл при фокусе
                     Future.delayed(const Duration(milliseconds: 300), _scrollToBottom);
                  },
                ),
              ),

              // Send button
              IconButton(
                icon:      const Icon(Icons.send, color: Colors.cyan),
                onPressed: () => _sendMessage(),
              ),
            ],
          ),
        ),
      );
  }

  PopupMenuItem<String> _popupItem(
          String value, IconData icon, String label) =>
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

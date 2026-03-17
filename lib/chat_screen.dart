import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import 'package:camera/camera.dart';

import 'crypto_service.dart';
import 'socket_service.dart';
import 'storage_service.dart';
import 'notification_service.dart';
import 'models/chat_models.dart';
import 'widgets/message_bubble.dart';
import 'screens/call_screen.dart';
import 'screens/media_gallery_screen.dart';
import 'screens/group_settings_screen.dart';
import 'widgets/sticker_picker.dart';
import 'config/app_config.dart';
import 'package:cached_network_image/cached_network_image.dart';

// Типы MsgType, SignatureStatus и утилиты (formatMessageTime и др.)
// перенесены в lib/models/chat_models.dart

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
  /// true  → FLAG_SECURE выключен (можно скриншотить для отладки).
  /// false → FLAG_SECURE включён в боевой версии.
  static const bool _debugMode = true;

  final List<Map<String, dynamic>> _messages = [];
  final Set<String> _messageIds = {};
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // Синглтоны — напрямую (совпадают с тем что в провайдерах)
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
  // Для личных чатов: одно значение. Для групп: Map<uid, bool>
  bool   _targetIsTyping   = false;
  final Map<String, bool> _groupTypingMap = {};

  bool _isLoadingMore    = false;
  bool _hasMoreMessages  = true;

  String? _replyToText;
  String? _replyToId;
  String? _replyToSender;

  // ── @Mentions ─────────────────────────────────────────────────────────────
  bool _showMentionList = false;
  String _mentionQuery  = '';

  // 🔴-5 FIX: Токен upload/download, получаем из uid_assigned события
  // Не зависим от socket_service.downloadHeaders — храним локально.
  String? _uploadToken;

  bool   _keysExchanged = false;
  Timer? _keyExchangeTimeout;

  // Сообщения, пришедшие до завершения key exchange.
  // Хранят raw socket-payload и будут дешифрованы как только ключ будет готов.
  final List<Map<String, dynamic>> _pendingMessages = [];

  // FILE_ID'ы для которых сервер вернул 404 — не ретраим бесконечно.
  // Показываем плейсхолдер "файл удалён / недоступен".
  final Set<String> _failedDownloads = {};

  bool _isSearching = false;

  // ── Group admin settings ──────────────────────────────────────────────────
  bool _onlyAdminsCanPost = false;

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

  // ── Voice playback progress ───────────────────────────────────────────────
  Duration _voicePosition = Duration.zero;
  Duration _voiceDuration = Duration.zero;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _completeSub;

  bool   _isSendingFile  = false;
  double _uploadProgress = 0.0;

  // ── Download progress ─────────────────────────────────────────────────────
  double _downloadProgress = 0.0;
  String? _downloadingMsgId;

  // ── Voice amplitude recording ─────────────────────────────────────────────
  final List<double> _amplitudes = [];
  Timer? _amplitudeTimer;

  // ── Scheduled messages ────────────────────────────────────────────────────
  final List<Timer> _scheduledTimers = [];

  // ── Disappearing messages ─────────────────────────────────────────────────
  Timer? _disappearTimer;

  static const int      MESSAGES_PER_PAGE    = 50;
  static const Duration KEY_EXCHANGE_TIMEOUT = Duration(seconds: 5);

  // ──────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _enableSecureScreen();
    _messageController.addListener(_onTextChanged);
    _scrollController.addListener(_onScroll);

    // Берём актуальный токен из глобального синглтона
    _uploadToken = StorageService.uploadToken;

    // Регистрируем чат как активный — пуши для него подавляются
    NotificationService.setActiveChat(widget.targetUid);

    // Сбрасываем счётчик непрочитанных при открытии чата
    _storage.resetUnreadCount(widget.targetUid);

    _reactions = _storage.loadReactions(widget.targetUid);

    // Загружаем настройку "только админы" для групп
    if (_storage.isGroup(widget.targetUid)) {
      _onlyAdminsCanPost = _storage.getSetting(
        'group_only_admin_${widget.targetUid}',
        defaultValue: false,
      ) as bool;
    }

    // Порядок важен:
    // 1. Запустить listener ДО всего — чтобы не пропустить key_response
    _listenToMessages();

    // 2. Загрузить ключи из кэша — async, но быстро (Hive + crypto)
    //    После этого запросить офлайн-сообщения: ключ гарантированно готов
    _initializeSecureChat().then((_) {
      // 3. Загрузить историю из локального Hive (синхронно через Future)
      _loadRecentHistory().then((_) {
        _markAllAsRead();
        _scrollToBottom(animated: false);
        _startDisappearTimers();
      });
      // 4. Запросить офлайн-очередь только после того как ключ загружен из кэша
      //    (или запрос уже отправлен в _initializeSecureChat)
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        try {
          _socket.getProfile(widget.targetUid);
          _socket.requestOfflineMessages(widget.targetUid);
        } catch (e) {
          debugPrint('Note: requestOfflineMessages error: $e');
        }
      });
    });
  }

  @override
  void dispose() {
    NotificationService.setActiveChat(null);
    _socketSub?.cancel();
    _typingTimer?.cancel();
    _keyExchangeTimeout?.cancel();
    _recordingTimer?.cancel();
    _disappearTimer?.cancel();
    _amplitudeTimer?.cancel();
    for (final t in _scheduledTimers) { t.cancel(); }
    _scheduledTimers.clear();
    _messageController.removeListener(_onTextChanged);
    _scrollController.removeListener(_onScroll);
    _messageController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _completeSub?.cancel();
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
      // Сначала пробуем загрузить ключи из локального Hive-кэша.
      // Это быстро (~10-20ms) и не требует сети.
      // Для групп: загружаем симметричный ключ группы
      if (_storage.isGroup(widget.targetUid)) {
        await _loadGroupKey();
        // ── FIX: всегда проверяем и ставим флаг после загрузки ──────────
        if (widget.cipher.hasSharedSecret(widget.targetUid)) {
          if (mounted) setState(() => _keysExchanged = true);
        }
        return;
      }

      final loaded = await widget.cipher.tryLoadCachedKeys(widget.targetUid, _storage);
      if (loaded) {
        debugPrint('✅ [Keys] Loaded from cache for ${widget.targetUid}');
        if (mounted) setState(() => _keysExchanged = true);
        return;
      }
      // Кэша нет — запрашиваем публичный ключ через WebSocket.
      // Пока ответ не придёт, входящие сообщения буферизуются в _pendingMessages.
      debugPrint('🔑 [Keys] Requesting public key for ${widget.targetUid}');
      _socket.requestPublicKey(widget.targetUid);
      _keyExchangeTimeout = Timer(KEY_EXCHANGE_TIMEOUT, () {
        if (!_keysExchanged && mounted) {
          debugPrint('⏰ [Keys] Exchange timeout for ${widget.targetUid}');
          setState(() => _keysExchanged = true);
          // Всё равно сбрасываем буфер — сообщения покажут ошибку дешифровки
          _flushPendingMessages();
        }
      });
    } catch (e) {
      debugPrint('Init error: $e');
    }
  }

  Future<void> _loadRecentHistory() async {
    try {
      // Загружаем список file_id с постоянными ошибками из Hive,
      // чтобы не делать повторные запросы после перезапуска приложения.
      final failedRaw = _storage.getSetting('failed_downloads_${widget.targetUid}');
      if (failedRaw is List) {
        _failedDownloads.addAll(failedRaw.cast<String>());
      }

      final history = _storage.getRecentMessages(widget.targetUid, limit: MESSAGES_PER_PAGE);
      if (mounted) {
        setState(() {
          for (var msg in history) {
            final m = Map<String, dynamic>.from(msg);
            if (!_messageIds.contains(m['id'])) {
              // ── FIX: пустые пузыри — если текст пустой но есть encrypted_text,
              //    помечаем как pending_decrypt чтобы переразшифровался при готовности ключей
              if ((m['text'] == null || (m['text'] as String).isEmpty) &&
                  m['encrypted_text'] != null &&
                  m['status'] != 'pending_decrypt') {
                m['status'] = 'pending_decrypt';
              }
              // ── FIX: фото исчезают — если filePath не существует на диске,
              //    сбрасываем его чтобы UI показал кнопку "загрузить"
              final fp = m['filePath'] as String?;
              if (fp != null && fp.isNotEmpty && !File(fp).existsSync()) {
                m['filePath'] = null;
              }
              _messages.add(m);
              _messageIds.add(m['id'].toString());
            }
          }
          _hasMoreMessages = history.length == MESSAGES_PER_PAGE;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animated: false));
        // ── Auto-redownload: файлы с FILE_ID у которых нет локального пути ──
        _autoRedownloadMissing();
      }
    } catch (e) {
      debugPrint('Load history error: $e');
    }
  }

  /// Фоновая перезагрузка медиафайлов с сервера для сообщений у которых
  /// filePath == null но mediaData содержит FILE_ID.
  Future<void> _autoRedownloadMissing() async {
    if (!_keysExchanged) return;
    final toDownload = _messages.where((m) {
      final type = m['type'] as String? ?? 'text';
      if (type == 'text') return false;
      if (m['filePath'] != null) return false;
      final media = m['mediaData'] as String?;
      return media != null && media.startsWith('FILE_ID:');
    }).toList();

    if (toDownload.isEmpty) return;
    debugPrint('📥 Auto-redownload: ${toDownload.length} files');

    for (final msg in toDownload) {
      if (!mounted) return;
      final fileId   = (msg['mediaData'] as String).substring(8);
      final fileName = msg['fileName'] as String?;
      final newPath  = await _downloadFileEncrypted(fileId, fileName);
      if (newPath != null && mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msg['id']);
          if (idx != -1) _messages[idx]['filePath'] = newPath;
        });
        _storage.updateMessageField(widget.targetUid, msg['id'].toString(), 'filePath', newPath);
      }
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
              // ── FIX: пустые пузыри и исчезающие фото (аналогично _loadRecentHistory)
              if ((m['text'] == null || (m['text'] as String).isEmpty) &&
                  m['encrypted_text'] != null &&
                  m['status'] != 'pending_decrypt') {
                m['status'] = 'pending_decrypt';
              }
              final fp = m['filePath'] as String?;
              if (fp != null && fp.isNotEmpty && !File(fp).existsSync()) {
                m['filePath'] = null;
              }
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
    if (!_keysExchanged) { _showError("Encryption keys not ready"); return null; }
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
      // Используем самый свежий токен из синглтона
      final options = Options(
        headers: {if (StorageService.uploadToken != null) 'X-Upload-Token': StorageService.uploadToken!},
      );
      final response = await _dio.post(
        '$SERVER_HTTP_URL/upload',
        data: formData,
        options: options,
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

  Future<String?> _downloadFileEncrypted(String fileId, String? fileName, {String? msgId}) async {
    if (_failedDownloads.contains(fileId)) return null;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final token  = StorageService.uploadToken ?? _uploadToken;

      if (msgId != null && mounted) {
        setState(() { _downloadingMsgId = msgId; _downloadProgress = 0.0; });
      }

      final response = await _dio.get<List<int>>(
        '$SERVER_HTTP_URL/download/$fileId',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {if (token != null) 'X-Upload-Token': token},
        ),
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _downloadProgress = received / total);
          }
        },
      );

      if (mounted) setState(() { _downloadingMsgId = null; _downloadProgress = 0.0; });

      if (response.statusCode == 404) {
        _failedDownloads.add(fileId);
        final key = 'failed_downloads_${widget.targetUid}';
        await _storage.saveSetting(key, _failedDownloads.toList());
        return null;
      }
      if (response.statusCode != 200 || response.data == null) return null;

      final decryptedBytes = await widget.cipher.decryptFileBytes(
        response.data!,
        fromUid: widget.targetUid,
      );
      final name = fileName ?? 'file_${DateTime.now().millisecondsSinceEpoch}';
      final file = File('${appDir.path}/deepdrift_media/$name');
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsBytes(decryptedBytes);
      return file.path;
    } catch (e) {
      debugPrint('Encrypted Download error: $e');
      if (mounted) setState(() { _downloadingMsgId = null; _downloadProgress = 0.0; });
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

  String _extensionForType(MsgType type, String? fileName) =>
      extensionForType(type, fileName);


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
        case 'uid_assigned':
          // Обновляем глобальный токен
          if (data['upload_token'] != null) {
            _uploadToken = data['upload_token'] as String;
            StorageService.setUploadToken(_uploadToken!);
          }
          break;
        case 'message':             _handleIncomingMessage(data);  break;
        case 'typing_indicator':    _handleTypingIndicator(data);  break;
        case 'public_key_response':  _handlePublicKeyResponse(data); break;
        case 'group_key_response':   _handleGroupKeyResponse(data);  break;
        case 'group_key_not_found':  _handleGroupKeyNotFound(data);  break;
        case 'group_member_added':   _handleGroupMemberAdded(data);  break;
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

  // ── Обработка входящих сообщений ─────────────────────────────────────────

  void _handleIncomingMessage(Map<String, dynamic> data) {
    final senderUid = data['from_uid'] as String?;
    final groupId   = data['group_id'] as String?;

    // Для групповых сообщений: group_id должен совпасть с targetUid,
    // для личных: from_uid должен совпасть.
    if (groupId != null && groupId.isNotEmpty) {
      if (groupId != widget.targetUid) return;
    } else {
      if (senderUid != widget.targetUid) return;
    }

    final msgId = data['id']?.toString();
    if (msgId == null || _messageIds.contains(msgId)) return;

    // Группа: дешифруем групповым ключом (targetUid = groupId)
    // Личный чат: дешифруем shared secret с отправителем
    final isGroupMsg = groupId != null && groupId.isNotEmpty;
    final decryptUid = isGroupMsg ? widget.targetUid : (senderUid ?? widget.targetUid);

    if (!widget.cipher.hasSharedSecret(decryptUid)) {
      debugPrint('⏳ [Keys] Buffering message $msgId — key not ready yet');
      if (!_pendingMessages.any((m) => m['id']?.toString() == msgId)) {
        _pendingMessages.add(data);
      }
      // Для группы — запрашиваем групповой ключ; для личного — публичный
      if (isGroupMsg) {
        _socket.requestGroupKey(decryptUid);
      } else {
        _socket.requestPublicKey(decryptUid);
      }
      return;
    }

    _decryptAndShowMessage(data);
  }

  /// Загружает симметричный ключ группы.
  /// Порядок: 1) уже в памяти  2) кэш Hive  3) запрос к серверу
  Future<void> _loadGroupKey() async {
    final groupId = widget.targetUid;
    if (widget.cipher.hasSharedSecret(groupId)) return;
    // Пробуем кэш Hive (plain base64 ключ)
    final cached = _storage.getGroupKeyBlob(groupId);
    if (cached != null && cached['blob']!.isNotEmpty) {
      try {
        final keyBytes = base64Decode(cached['blob']!);
        widget.cipher.setGroupKey(groupId, keyBytes);
        debugPrint('✅ [GroupKey] Loaded from Hive cache for $groupId');
        if (mounted) setState(() => _keysExchanged = true);
        _flushPendingMessages();
        return;
      } catch (e) {
        debugPrint('⚠️ [GroupKey] Cache load failed: $e');
      }
    }
    debugPrint('🔑 [GroupKey] Requesting from server for $groupId');
    _socket.requestGroupKey(groupId);
  }

  void _handleGroupKeyNotFound(Map<String, dynamic> data) {
    // В упрощённой схеме сервер всегда генерирует ключ, это не должно случаться.
    // Но на случай гонки — просто повторяем запрос через секунду.
    debugPrint('⚠️ [GroupKey] Not found — retrying in 1s');
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) _socket.requestGroupKey(widget.targetUid);
    });
  }

  void _handleGroupMemberAdded(Map<String, dynamic> data) {
    final groupId = data['group_id'] as String?;
    final newUid  = data['new_uid']  as String?;
    if (groupId == null || groupId != widget.targetUid || newUid == null) return;
    final members = _storage.getGroupMembers(groupId);
    if (!members.contains(newUid)) {
      members.add(newUid);
      final creator = _storage.getGroupCreator(groupId) ?? widget.myUid;
      _storage.saveGroup(
        groupId:    groupId,
        groupName:  _storage.getGroupName(groupId),
        members:    members,
        creatorUid: creator,
      );
    }
    if (mounted) setState(() {});
  }

  /// Обрабатывает ответ сервера с групповым ключом (упрощённая схема).
  /// Сервер возвращает plain base64 ключ — просто декодируем и ставим.
  Future<void> _handleGroupKeyResponse(Map<String, dynamic> data) async {
    final groupId = data['group_id'] as String?;
    final keyB64  = data['group_key'] as String?;   // новое поле (упрощённая схема)
    if (groupId == null || groupId != widget.targetUid) return;
    if (keyB64 == null || keyB64.isEmpty) return;

    try {
      final keyBytes = base64Decode(keyB64);
      widget.cipher.setGroupKey(groupId, keyBytes);
      // Кэшируем в Hive (blob = plain base64)
      await _storage.saveGroupKeyBlob(groupId, keyB64, 'server');
      debugPrint('✅ [GroupKey] Set for $groupId (${keyBytes.length} bytes)');
      if (mounted) setState(() => _keysExchanged = true);
      _flushPendingMessages();
    } catch (e) {
      debugPrint('❌ [GroupKey] Failed to set: $e');
      if (mounted) _showError('Не удалось загрузить ключ группы');
    }
  }


  /// Сбрасывает буфер: дешифрует все сообщения, накопленные до получения ключа.
  /// Также перешифровывает сообщения с status='pending_decrypt' из Hive —
  /// они были сохранены HomeScreen'ом до того как ключи были загружены.
  void _flushPendingMessages() {
    // 1. Сбрасываем socket-буфер
    if (_pendingMessages.isNotEmpty) {
      debugPrint('📬 [Keys] Flushing ${_pendingMessages.length} buffered messages');
      final toProcess = List<Map<String, dynamic>>.from(_pendingMessages);
      _pendingMessages.clear();
      for (final data in toProcess) {
        _decryptAndShowMessage(data);
      }
    }

    // 2. Перешифровываем pending_decrypt сообщения из истории.
    // Для групп: убеждаемся что ключ загружен перед попыткой дешифровки.
    // ВАЖНО: обновляем только текст. Медиафайлы НЕ скачиваем автоматически —
    // пользователь нажмёт кнопку повтора сам. Иначе каждый reconnect
    // триггерит лавину HTTP-запросов к /download.
    final pendingInHistory = _messages
        .where((m) => m['status'] == 'pending_decrypt' && m['encrypted_text'] != null)
        .toList();

    if (pendingInHistory.isNotEmpty) {
      debugPrint('🔓 [Keys] Re-decrypting ${pendingInHistory.length} pending messages from history');
      for (final msg in pendingInHistory) {
        final encrypted = msg['encrypted_text'] as String?;
        final msgId     = msg['id']?.toString();
        if (msgId == null || encrypted == null) continue;

        widget.cipher.decryptText(encrypted, fromUid: widget.targetUid).then((decrypted) async {
          if (decrypted.startsWith('[⚠️') || decrypted.startsWith('[❌')) return;

          final idx = _messages.indexWhere((m) => m['id']?.toString() == msgId);
          if (idx == -1 || !mounted) return;

          final updated = Map<String, dynamic>.from(_messages[idx])
            ..['text']   = decrypted
            ..['status'] = 'delivered';
          updated.remove('encrypted_text'); // больше не нужен

          setState(() => _messages[idx] = updated);
          await _storage.saveMessage(widget.targetUid, updated);
          // Медиафайл покажет _retryButton — пользователь скачает сам
        });
      }
    }
  }

  /// Дешифрует одно входящее сообщение и добавляет его в UI + Hive.
  void _decryptAndShowMessage(Map<String, dynamic> data) {
    final senderUid = (data['from_uid'] as String?) ?? widget.targetUid;
    final groupId   = data['group_id'] as String?;
    final msgId     = data['id']?.toString();
    if (msgId == null || _messageIds.contains(msgId)) return;

    // ── ВАЖНО: добавляем ID сразу, до async-дешифровки.
    // Без этого несколько копий одного сообщения (из global queue + specific queue)
    // одновременно пройдут проверку выше и запустят параллельные загрузки медиа.
    _messageIds.add(msgId);

    final encrypted = data['encrypted_text'];
    final signature = data['signature'];
    final msgTyp    = (data['messageType'] as String? ?? 'text').toMsgType();
    final rawTime   = data['time'];

    // For groups: decrypt with sender's key. For personal: use targetUid.
    final decryptFromUid = (groupId != null && groupId.isNotEmpty) ? senderUid : widget.targetUid;
    // For groups: decrypt with group key (stored under groupId).
    // For personal: decrypt with sender's shared secret.
    final useUid = (groupId != null && groupId.isNotEmpty) ? groupId : decryptFromUid;
    widget.cipher.decryptText(encrypted, fromUid: useUid).then((decrypted) async {
      // ── Обнаружение несоответствия ключей ─────────────────────────────────
      if (decrypted.contains('Authentication failed') || decrypted.contains('Wrong key')) {
        widget.cipher.clearSharedSecret(decryptFromUid);
        await _storage.clearCachedKeys(decryptFromUid);
        _socket.requestPublicKey(decryptFromUid);
        final errorMsg = {
          'id': msgId,
          'text': '⚠️ Несоответствие ключей — попроси собеседника переотправить.',
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

      // ── Верификация Ed25519-подписи ────────────────────────────────────────
      SignatureStatus sigStatus = SignatureStatus.unknown;
      if (signature != null) {
        final isValid = await widget.cipher.verifySignature(
          decrypted,
          signature,
          senderUid,
        );
        sigStatus = isValid ? SignatureStatus.valid : SignatureStatus.invalid;
        if (!isValid) {
          debugPrint('⚠️ [Security] Invalid signature on message $msgId from $senderUid');
        }
      }

      // ── Медиафайлы ──────────────────────────────────────────────────────
      String? localPath;
      if (msgTyp != MsgType.text && data['mediaData'] != null) {
        final String mediaStr = data['mediaData'] as String;
        if (mediaStr.startsWith('FILE_ID:')) {
          final fileId = mediaStr.substring(8);
          // Не скачиваем если файл уже помечен как недоступный в этой сессии
          // или в Hive (персистентный кэш 404).
          if (!_failedDownloads.contains(fileId)) {
            localPath = await _downloadFileEncrypted(fileId, data['fileName'] as String?);
          }
        } else {
          localPath = await _saveMediaToDiskBase64(
            base64Data: mediaStr,
            msgType: msgTyp,
            fileName: data['fileName'] as String?,
          );
        }
      }

      // Резолвим replyToId в текст ответа из локальных сообщений
      String? replyText = data['replyTo'] as String?;
      final replyId = data['replyToId'] as String?;
      String? replyToSender;
      if (replyId != null) {
        final original = _messages.cast<Map<String, dynamic>?>().firstWhere(
          (m) => m?['id']?.toString() == replyId,
          orElse: () => null,
        );
        if (replyText == null) {
          replyText = original?['text'] as String? ?? '[сообщение]';
        }
        // Определяем имя автора оригинального сообщения
        final origFrom = original?['from'] as String?;
        if (origFrom != null) {
          replyToSender = origFrom == widget.myUid
              ? 'Вы'
              : _storage.getContactDisplayName(origFrom);
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
        'replyTo':         replyText,
        'replyToId':       replyId,
        'replyToSender':   replyToSender,
        'type':            data['messageType'] ?? 'text',
        'filePath':        localPath,
        'mediaData':       data['mediaData'],
        'fileName':        data['fileName'],
        'fileSize':        data['fileSize'],
        'mimeType':        data['mimeType'],
        'edited':          data['edited'] ?? false,
        'editedAt':        data['editedAt'],
        'forwardedFrom':   data['forwarded_from'],
        'signatureStatus': sigStatus.index,
        'message_ttl':     data['message_ttl'] as int?,
        'expire_at':       _calcExpireAt(data['message_ttl'] as int?),
      };

      if (mounted) {
        setState(() {
          _messages.add(msg);
          _messageIds.add(msgId);
        });
        _scrollToBottom();
        SystemSound.play(SystemSoundType.alert);
        _storage.saveMessage(widget.targetUid, msg);
        _sendReadReceipt(msgId);
        _scheduleDisappear(msg);
      }
    }).catchError((Object e) {
      debugPrint('Decrypt error: $e');
    });
  }

  void _handleTypingIndicator(Map<String, dynamic> data) {
    if (!mounted) return;
    final fromUid  = data['from_uid'] as String?;
    final isTyping = data['typing'] == true;
    final isGroup  = _storage.isGroup(widget.targetUid);

    if (isGroup && fromUid != null) {
      setState(() {
        if (isTyping) {
          _groupTypingMap[fromUid] = true;
        } else {
          _groupTypingMap.remove(fromUid);
        }
      });
      if (isTyping) _scrollToBottom();
    } else if (fromUid == widget.targetUid) {
      setState(() => _targetIsTyping = isTyping);
      if (isTyping) _scrollToBottom();
    }
  }

  void _handlePublicKeyResponse(Map<String, dynamic> data) {
    if (data['target_uid'] != widget.targetUid) return;
    final x25519Key  = data['x25519_key'];
    final ed25519Key = data['ed25519_key'];
    if (x25519Key != null && ed25519Key != null) {
      widget.cipher
          .establishSharedSecret(widget.targetUid, x25519Key as String, theirSignKeyB64: ed25519Key as String)
          .then((_) {
            if (!mounted) return;
            setState(() => _keysExchanged = true);
            // Сбрасываем буфер: дешифруем все сообщения, пришедшие до ключа
            _flushPendingMessages();
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
    final myUid = widget.myUid;
    final isGroup = _storage.isGroup(widget.targetUid);
    // В группах сообщения приходят от разных UIDs, не от targetUid
    // Отмечаем все входящие (не мои) как прочитанные
    final unreadIds = _messages
        .where((m) => m['from'] != myUid && m['status'] != 'read')
        .map((m) => m['id'].toString())
        .toList();
    if (!isGroup) {
      for (final id in unreadIds) { _sendReadReceipt(id); }
    }
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

    // @mention detection (только в группах)
    if (_storage.isGroup(widget.targetUid)) {
      final text = _messageController.text;
      final cursor = _messageController.selection.baseOffset;
      if (cursor > 0 && cursor <= text.length) {
        // Ищем последний @ перед курсором
        final before = text.substring(0, cursor);
        final atIdx = before.lastIndexOf('@');
        if (atIdx >= 0 && (atIdx == 0 || before[atIdx - 1] == ' ')) {
          final query = before.substring(atIdx + 1).toLowerCase();
          if (!query.contains(' ')) {
            setState(() { _showMentionList = true; _mentionQuery = query; });
            return;
          }
        }
      }
      if (_showMentionList) setState(() => _showMentionList = false);
    }
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
    String? forwardedFrom,
  }) async {
    if (_editingMessageId != null) { await _saveEditedMessage(); return; }

    final messageText = text ?? _messageController.text.trim();
    if (messageText.isEmpty && mediaData == null) return;

    final isGroup = _storage.isGroup(widget.targetUid);

    if (isGroup) {
      await _sendGroupMessage(
        text: messageText, messageType: messageType,
        mediaData: mediaData, filePath: filePath,
        fileName: fileName, fileSize: fileSize, mimeType: mimeType,
        forwardedFrom: forwardedFrom,
      );
      return;
    }

    // ── Личный чат ────────────────────────────────────────────────────────────
    if (!widget.cipher.hasSharedSecret(widget.targetUid)) {
      final loaded = await widget.cipher.tryLoadCachedKeys(widget.targetUid, _storage);
      if (!loaded) {
        _socket.requestPublicKey(widget.targetUid);
        await Future.delayed(const Duration(milliseconds: 800));
        if (!widget.cipher.hasSharedSecret(widget.targetUid)) {
          _showError('Нет ключа шифрования — собеседник не в сети');
          return;
        }
      }
    }

    final msgId      = _uuid.v4();
    final now        = DateTime.now().millisecondsSinceEpoch;
    final replyId    = _replyToId;
    final replyText  = _replyToText;
    final replySender = _replyToSender;

    try {
      final encrypted = await widget.cipher.encryptText(messageText, targetUid: widget.targetUid);
      final signature = await widget.cipher.signMessage(messageText);

      final ttl = _storage.getMessageTtl(widget.targetUid);

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
        'replyToSender':   replySender,
        'type':            messageType,
        'filePath':        filePath,
        'fileName':        fileName,
        'fileSize':        fileSize,
        'mimeType':        mimeType,
        'edited':          false,
        'forwardedFrom':   forwardedFrom,
        'signatureStatus': SignatureStatus.valid.index,
        'message_ttl':     ttl > 0 ? ttl : null,
        'expire_at':       ttl > 0 ? _calcExpireAt(ttl) : null,
      };

      if (mounted) {
        setState(() {
          _messages.add(myMsg);
          _messageIds.add(msgId);
          _messageController.clear();
          _replyToText   = null;
          _replyToId     = null;
          _replyToSender = null;
        });
        _scrollToBottom();
        SystemSound.play(SystemSoundType.click);
        if (ttl > 0) _scheduleDisappear(myMsg);
      }

      await _storage.saveMessage(widget.targetUid, myMsg);

      _socket.sendMessage(
        widget.targetUid, encrypted, signature, msgId,
        replyToId:     replyId,
        messageType:   messageType,
        mediaData:     mediaData,
        fileName:      fileName,
        fileSize:      fileSize,
        mimeType:      mimeType,
        forwardedFrom: forwardedFrom,
        messageTtl:    ttl > 0 ? ttl : null,
      );

      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'sent';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'failed';
        });
      }
      _showError('Ошибка отправки: $e');
    }
  }

  /// Групповая отправка: шифруем ОДИН РАЗ симметричным ключом группы.
  /// Сервер делает fan-out всем участникам.
  Future<void> _sendGroupMessage({
    String? text,
    String  messageType  = 'text',
    String? mediaData,
    String? filePath,
    String? fileName,
    int?    fileSize,
    String? mimeType,
    String? forwardedFrom,
  }) async {
    final messageText = text ?? '';
    if (messageText.isEmpty && mediaData == null) return;

    // Проверяем что групповой ключ установлен
    if (!widget.cipher.hasSharedSecret(widget.targetUid)) {
      _showError('Ключ группы не загружен. Попробуй закрыть и открыть чат.');
      return;
    }

    // Проверяем ограничение "только администратор"
    if (_onlyAdminsCanPost) {
      final creator = _storage.getGroupCreator(widget.targetUid);
      if (creator != widget.myUid) {
        _showError('Только администратор может отправлять сообщения в эту группу');
        return;
      }
    }

    final msgId      = _uuid.v4();
    final now        = DateTime.now().millisecondsSinceEpoch;
    final replyId    = _replyToId;
    final replyText  = _replyToText;
    final replySender = _replyToSender;

    try {
      // Шифруем ОДИН РАЗ групповым ключом
      final encrypted = await widget.cipher.encryptText(
          messageText, targetUid: widget.targetUid);
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
        'replyToSender':   replySender,
        'type':            messageType,
        'filePath':        filePath,
        'fileName':        fileName,
        'fileSize':        fileSize,
        'mimeType':        mimeType,
        'edited':          false,
        'forwardedFrom':   forwardedFrom,
        'group_id':        widget.targetUid,
        'signatureStatus': SignatureStatus.valid.index,
      };

      if (mounted) {
        setState(() {
          _messages.add(myMsg);
          _messageIds.add(msgId);
          _messageController.clear();
          _replyToText   = null;
          _replyToId     = null;
          _replyToSender = null;
        });
        _scrollToBottom();
        // Звук отправленного группового сообщения
        SystemSound.play(SystemSoundType.click);
      }

      // Сохраняем ПЕРЕД отправкой — если приложение свернут/убит не потеряем
      await _storage.saveMessage(widget.targetUid, myMsg);

      final delivered = await _socket.sendGroupMessage(
        groupId:      widget.targetUid,
        encryptedText: encrypted,
        signature:    signature,
        msgId:        msgId,
        messageType:  messageType,
        mediaData:    mediaData,
        fileName:     fileName,
        fileSize:     fileSize,
        mimeType:     mimeType,
        replyToId:    replyId,
      );

      // Обновляем статус: delivered если хотя бы один участник онлайн
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) {
            _messages[idx]['status'] = delivered ? 'delivered' : 'sent';
          }
        });
        // Обновляем в Hive
        final updatedMsg = Map<String, dynamic>.from(
          _messages.firstWhere((m) => m['id'] == msgId, orElse: () => {}),
        );
        if (updatedMsg.isNotEmpty) {
          await _storage.saveMessage(widget.targetUid, updatedMsg);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == msgId);
          if (idx != -1) _messages[idx]['status'] = 'failed';
        });
      }
      _showError('Ошибка отправки: $e');
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
        if (fileId == null) { _showError('Ошибка загрузки: $fileName'); continue; }
        final localPath = await _copyFileToMediaDir(file, MsgType.image, fileName);
        await _sendMessage(
          text: '📷 Photo', messageType: 'image',
          mediaData: 'FILE_ID:$fileId', filePath: localPath,
          fileName: fileName, fileSize: fileSize, mimeType: 'image/jpeg',
        );
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      _showError('Ошибка отправки фото: $e');
    } finally {
      if (mounted) setState(() { _isSendingFile = false; _uploadProgress = 0.0; });
    }
  }

  // ── Видео из галереи ──────────────────────────────────────────────────────
  Future<void> _sendVideo() async {
    try {
      final video = await _imagePicker.pickVideo(source: ImageSource.gallery);
      if (video == null) return;

      if (mounted) setState(() { _isSendingFile = true; _uploadProgress = 0.0; });
      final file   = File(video.path);
      final fileId = await _uploadFileEncrypted(file);

      if (fileId != null) {
        final localPath = await _copyFileToMediaDir(file, MsgType.video_gallery, video.name);
        await _sendMessage(
          text:        '🎬 Видео из галереи',
          messageType: 'video_gallery',
          mediaData:   'FILE_ID:$fileId',
          filePath:    localPath,
          fileName:    video.name,
          fileSize:    await file.length(),
          mimeType:    'video/mp4',
        );
      } else {
        _showError('Ошибка загрузки видео');
      }
    } catch (e) {
      _showError('Ошибка видео: $e');
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
        _showError('Ошибка загрузки файла');
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
      _showError('Ошибка отправки файла: $e');
    } finally {
      if (mounted) setState(() { _isSendingFile = false; _uploadProgress = 0.0; });
    }
  }

  Future<void> _startRecording() async {
    if (await _audioRecorder.hasPermission()) {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      setState(() { _isRecording = true; _voiceTempPath = path; _recordingDuration = 0; _amplitudes.clear(); });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingDuration++);
      });
      // Сэмплируем амплитуду 10 раз в секунду для волны
      _amplitudeTimer?.cancel();
      _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
        try {
          final amp = await _audioRecorder.getAmplitude();
          // amp.current: -∞..0 dBFS, нормализуем в 0..1
          final normalized = ((amp.current + 50) / 50).clamp(0.0, 1.0);
          if (mounted) setState(() => _amplitudes.add(normalized));
        } catch (_) {}
      });
    } else {
      _showError('Нет доступа к микрофону');
    }
  }

  Future<void> _cancelRecording() async {
    try {
      await _audioRecorder.stop();
      _recordingTimer?.cancel();
      _amplitudeTimer?.cancel();
      _cleanTempVoiceFile();
      if (mounted) setState(() { _isRecording = false; _recordingDuration = 0; _amplitudes.clear(); });
    } catch (e) {
      debugPrint('Error cancelling recording: $e');
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      final path = await _audioRecorder.stop();
      _recordingTimer?.cancel();
      _amplitudeTimer?.cancel();

      // Даунсэмплим амплитуды в 28 столбиков для отображения волны
      final waveform = _downsampleAmplitudes(_amplitudes, 28);
      final waveformStr = waveform.map((v) => v.toStringAsFixed(2)).join(',');

      if (mounted) setState(() => _isRecording = false);

      if (path != null) {
        _voiceTempPath = path;
        final file = File(path);
        if (_recordingDuration < 1) { _cleanTempVoiceFile(); _amplitudes.clear(); return; }

        if (mounted) setState(() { _isSendingFile = true; _uploadProgress = 0.0; });
        final fileId = await _uploadFileEncrypted(file);
        if (fileId == null) {
          _showError('Ошибка загрузки голосового');
          _cleanTempVoiceFile();
          if (mounted) setState(() => _isSendingFile = false);
          _amplitudes.clear();
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
        // Сохраняем волну в сообщение
        final idx = _messages.lastIndexWhere((m) => m['fileName'] == fileName);
        if (idx != -1) {
          _messages[idx]['waveform'] = waveformStr;
          _storage.updateMessageField(widget.targetUid, _messages[idx]['id'].toString(), 'waveform', waveformStr);
        }
        _cleanTempVoiceFile();
        _amplitudes.clear();
        if (mounted) setState(() => _isSendingFile = false);
      }
    } catch (e) {
      _showError('Ошибка отправки голосового: $e');
      _cancelRecording();
      _amplitudes.clear();
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
      // Программный зум 1.25x — убирает эффект «рыбьего глаза» фронтальной камеры
      try {
        final maxZoom = await _cameraController!.getMaxZoomLevel();
        final zoom    = 1.25.clamp(1.0, maxZoom);
        await _cameraController!.setZoomLevel(zoom);
      } catch (_) {/* не все устройства поддерживают zoom */}
      await _cameraController!.startVideoRecording();
      setState(() { _isVideoRecording = true; _recordingDuration = 0; });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingDuration++);
      });
    } catch (e) {
      _showError('Ошибка камеры: $e');
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
      _showError('Ошибка отправки видео: $e');
    } finally {
      if (mounted) setState(() => _isSendingFile = false);
    }
  }

  Future<void> _playVoiceMessage(Map<String, dynamic> msg) async {
    final msgId = msg['id']?.toString();
    try {
      if (_playingMessageId == msgId) {
        await _audioPlayer.stop();
        setState(() { _playingMessageId = null; _voicePosition = Duration.zero; });
        return;
      }
      final localPath = msg['filePath'] as String?;
      if (localPath == null || !File(localPath).existsSync()) {
        _showError('Голосовое сообщение недоступно на этом устройстве');
        return;
      }

      await _audioPlayer.play(DeviceFileSource(localPath));
      setState(() {
        _playingMessageId = msgId;
        _voicePosition = Duration.zero;
        _voiceDuration = Duration.zero;
      });

      _positionSub?.cancel();
      _positionSub = _audioPlayer.onPositionChanged.listen((pos) {
        if (mounted) setState(() => _voicePosition = pos);
      });

      _durationSub?.cancel();
      _durationSub = _audioPlayer.onDurationChanged.listen((dur) {
        if (mounted) setState(() => _voiceDuration = dur);
      });

      _completeSub?.cancel();
      _completeSub = _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) setState(() { _playingMessageId = null; _voicePosition = Duration.zero; });
      });
    } catch (e) {
      _showError('Ошибка воспроизведения: $e');
    }
  }

  Future<void> _seekVoice(Duration position) async {
    await _audioPlayer.seek(position);
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
      _showError('Ошибка редактирования: $e');
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
    final contacts = _storage.getContactsList();
    if (contacts.isEmpty) {
      _showError('Нет контактов для пересылки');
      return;
    }

    final selected = <String>{};

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(child: Text(
                      'Переслать${selected.isEmpty ? '' : ' (${selected.length})'}',
                      style: GoogleFonts.orbitron(color: Colors.white, fontSize: 14),
                    )),
                    if (selected.isNotEmpty)
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00D9FF),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                        ),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          int ok = 0;
                          for (final uid in selected) {
                            try {
                              await _sendForwardedMessage(message, toUid: uid);
                              ok++;
                            } catch (_) {}
                          }
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('Переслано $ok/${selected.length}'),
                              backgroundColor: const Color(0xFF1A4A2E),
                            ));
                          }
                        },
                        child: const Text('ОТПРАВИТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12),
              Expanded(
                child: ListView.builder(
                  itemCount: contacts.length,
                  itemBuilder: (_, i) {
                    final uid  = contacts[i];
                    final name = _storage.getContactDisplayName(uid);
                    final isSelected = selected.contains(uid);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isSelected ? const Color(0xFF00D9FF) : const Color(0xFF0A0E27),
                        child: isSelected
                            ? const Icon(Icons.check, color: Colors.black, size: 20)
                            : Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(color: Colors.cyan)),
                      ),
                      title: Text(name, style: TextStyle(
                          color: isSelected ? const Color(0xFF00D9FF) : Colors.white)),
                      subtitle: Text(uid, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      onTap: () {
                        setS(() {
                          if (isSelected) {
                            selected.remove(uid);
                          } else {
                            selected.add(uid);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
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
    final displayName  = _storage.getContactDisplayName(originalFrom);
    final forwardLabel = displayName.isNotEmpty ? displayName : originalFrom;

    // msg['text'] — уже расшифрованный текст в памяти.
    // _sendMessage заново зашифрует его публичным ключом получателя.
    // Нельзя пересылать зашифрованный блоб напрямую — получатель не откроет
    // его своим ключом (ECDH-секрет уникален для каждой пары).
    final plainText  = message['text'] as String? ?? '';
    final msgType    = message['type'] as String? ?? 'text';
    final localPath  = message['filePath'] as String?;
    final fileName   = message['fileName'] as String?;
    final fileSize   = message['fileSize'] as int?;
    final mimeType   = message['mimeType'] as String?;

    // Убеждаемся что ключ получателя доступен
    if (!widget.cipher.hasSharedSecret(toUid)) {
      final loaded = await widget.cipher.tryLoadCachedKeys(toUid, _storage);
      if (!loaded) {
        _showError('Нет ключа для $forwardLabel — откройте чат с ним сначала');
        return;
      }
    }

    if (msgType != 'text' && localPath != null && File(localPath).existsSync()) {
      // ── Медиа: перешифровываем и загружаем заново ──────────────────────
      // FILE_ID нельзя переиспользовать — файл зашифрован старым shared secret.
      if (mounted) setState(() => _isSendingFile = true);
      try {
        final fileId = await _uploadFileEncryptedForUid(File(localPath), toUid);
        if (fileId == null) { _showError('Ошибка загрузки файла'); return; }
        await _sendMessage(
          messageType:   msgType,
          mediaData:     'FILE_ID:$fileId',
          filePath:      localPath,
          fileName:      fileName,
          fileSize:      fileSize,
          mimeType:      mimeType,
          forwardedFrom: forwardLabel,
        );
      } finally {
        if (mounted) setState(() => _isSendingFile = false);
      }
    } else {
      // ── Текст: _sendMessage зашифрует plainText ключом toUid ───────────
      await _sendMessage(
        text:          plainText,
        messageType:   msgType,
        forwardedFrom: forwardLabel,
      );
    }
    if (toUid != widget.targetUid) {
      _showSuccess('Переслано в чат $forwardLabel');
    }
  }

  /// Шифрует файл для конкретного получателя и загружает на сервер.
  /// Используется при пересылке медиа — нельзя переиспользовать FILE_ID
  /// т.к. шифрование E2EE привязано к паре отправитель-получатель.
  Future<String?> _uploadFileEncryptedForUid(File file, String targetUid) async {
    try {
      final bytes          = await file.readAsBytes();
      final encryptedBytes = await widget.cipher.encryptFileBytes(bytes, targetUid: targetUid);
      final tempDir  = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${file.path.split('/').last}.enc');
      await tempFile.writeAsBytes(encryptedBytes);
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(tempFile.path, filename: tempFile.path.split('/').last),
      });
      final options  = Options(headers: {if (StorageService.uploadToken != null) 'X-Upload-Token': StorageService.uploadToken!});
      final response = await _dio.post('$SERVER_HTTP_URL/upload', data: formData, options: options);
      if (await tempFile.exists()) await tempFile.delete();
      if (response.statusCode == 200 && response.data['status'] == 'success') {
        return response.data['file_id'] as String?;
      }
    } catch (e) {
      debugPrint('Forward upload error: $e');
    }
    return null;
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

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFF1A4A2E)),
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

  // Делегаты к утилитам из models/chat_models.dart
  String _formatLastSeen(int ts)          => formatLastSeen(ts);
  String _formatRecordingTime(int s)      => formatRecordingTime(s);
  String _mimeTypeFromExtension(String f) => mimeTypeFromExtension(f);


  void _setReplyTo(Map<String, dynamic> message) {
    final fromUid = message['from'] as String?;
    String? senderName;
    if (fromUid != null && fromUid != widget.myUid) {
      senderName = _storage.getContactDisplayName(fromUid);
    } else if (fromUid == widget.myUid) {
      senderName = 'Вы';
    }
    setState(() {
      _replyToText   = message['text'] as String?;
      _replyToId     = message['id']?.toString();
      _replyToSender = senderName;
    });
  }

  void _cancelReply() => setState(() { _replyToText = null; _replyToId = null; _replyToSender = null; });

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) _searchController.clear();
    });
  }

  void _copyMessageText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Скопировано в буфер')),
    );
  }

  List<Map<String, dynamic>> get _filteredMessages {
    if (!_isSearching || _searchController.text.isEmpty) return _messages;
    final q = _searchController.text.toLowerCase();
    return _messages.where((m) => (m['text'] ?? '').toLowerCase().contains(q)).toList();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Просмотр и сохранение файлов
  // ──────────────────────────────────────────────────────────────────────────

  /// Повторная загрузка медиафайла для сообщений, у которых filePath == null
  /// (первая загрузка упала при получении — нет связи, ключи ещё не подгружены и т.п.)
  Future<void> _retryDownloadMedia(Map<String, dynamic> msg) async {
    final mediaData = msg['mediaData'] as String?;
    if (mediaData == null || !mediaData.startsWith('FILE_ID:')) {
      _showError('Данные файла недоступны — попросите собеседника переотправить');
      return;
    }

    if (mounted) setState(() => _isSendingFile = true);
    try {
      final fileId   = mediaData.substring(8);
      final fileName = msg['fileName'] as String?;
      final newPath  = await _downloadFileEncrypted(fileId, fileName, msgId: msg['id']?.toString());

      if (newPath != null) {
        final idx = _messages.indexWhere((m) => m['id'] == msg['id']);
        if (idx != -1 && mounted) {
          setState(() => _messages[idx]['filePath'] = newPath);
        }
        // Обновляем в Hive через пересохранение обновлённого сообщения
        final updated = Map<String, dynamic>.from(msg)..['filePath'] = newPath;
        await _storage.saveMessage(widget.targetUid, updated);
        _showSuccess('Файл загружен');
      } else {
        _showError('Не удалось загрузить файл — проверь подключение');
      }
    } finally {
      if (mounted) setState(() => _isSendingFile = false);
    }
  }


  /// Сохраняет медиафайл из сообщения в галерею устройства.
  Future<void> _saveToGallery(Map<String, dynamic> msg) async {
    final filePath = msg['filePath'] as String?;
    final msgType  = (msg['type'] as String? ?? 'text').toMsgType();
    final fileName = msg['fileName'] as String? ?? 'ddchat_file';

    if (filePath == null || !File(filePath).existsSync()) {
      // Файл не скачан — пробуем скачать сначала
      if (msg['mediaData'] != null) {
        if (mounted) setState(() => _isSendingFile = true);
        await _retryDownloadMedia(msg);
        if (mounted) setState(() => _isSendingFile = false);
        // Перечитываем путь после скачивания
        final idx = _messages.indexWhere((m) => m['id'] == msg['id']);
        final updatedPath = idx != -1 ? _messages[idx]['filePath'] as String? : null;
        if (updatedPath == null || !File(updatedPath).existsSync()) {
          if (mounted) _showError('Файл недоступен — возможно истёк срок хранения');
          return;
        }
        await _saveToGallery(_messages[idx]);
        return;
      }
      if (mounted) _showError('Файл не найден на устройстве');
      return;
    }

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          if (mounted) _showError('Нет разрешения на сохранение в галерею');
          return;
        }
      }

      if (msgType == MsgType.image) {
        await Gal.putImage(filePath, album: 'DDChat');
      } else if (msgType == MsgType.video_note || msgType == MsgType.video_gallery) {
        await Gal.putVideo(filePath, album: 'DDChat');
      } else {
        // Для файлов (аудио, документы) — копируем в Downloads
        if (Platform.isAndroid) {
          final dir = Directory('/storage/emulated/0/Download/DDChat');
          if (!await dir.exists()) await dir.create(recursive: true);
          await File(filePath).copy('${dir.path}/$fileName');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('✅ Сохранено: Download/DDChat/$fileName')),
            );
          }
          return;
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Сохранено в галерею'),
            backgroundColor: Color(0xFF1A4A2E),
          ),
        );
      }
    } catch (e) {
      debugPrint('Save to gallery error: $e');
      if (mounted) _showError('Ошибка сохранения: $e');
    }
  }

  // MethodChannel для FLAG_SECURE (заменяет flutter_windowmanager)
  static const _secureChannel = MethodChannel('com.deepdrift.secure/window');

  void _enableSecureScreen() async {
    if (!Platform.isAndroid || _debugMode) return;
    try {
      await _secureChannel.invokeMethod('addSecureFlag');
    } catch (e) {
      debugPrint('Screenshot protection enable error: $e');
    }
  }


  /// Открывает фото профиля контакта на весь экран с Hero-анимацией и pinch-to-zoom.
  // ──────────────────────────────────────────────────────────────────────────
  // Групповые настройки
  // ──────────────────────────────────────────────────────────────────────────

  void _showGroupMembersDialog(String groupName, List<String> members) {
    final creator  = _storage.getGroupCreator(widget.targetUid);
    final isAdmin  = creator == widget.myUid;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.group, color: Color(0xFF00D9FF), size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'Участники: ${members.length}',
                    style: GoogleFonts.orbitron(
                        color: const Color(0xFF00D9FF), fontSize: 13),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),

            // ── Настройки администратора ─────────────────────────────────────
            if (isAdmin) ...[
              SwitchListTile(
                secondary:     const Icon(Icons.admin_panel_settings,
                    color: Color(0xFF00D9FF)),
                title:         const Text('Только администратор',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                subtitle:      const Text('Запретить участникам отправлять сообщения',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
                activeColor:   const Color(0xFF00D9FF),
                value:         _onlyAdminsCanPost,
                onChanged: (val) async {
                  setSheet(() {});
                  if (mounted) setState(() => _onlyAdminsCanPost = val);
                  await _storage.saveSetting(
                      'group_only_admin_${widget.targetUid}', val);
                  _socket.updateGroupSettings(
                      widget.targetUid, onlyAdminsCanPost: val);
                },
              ),
              const Divider(color: Colors.white12, height: 1),
              ListTile(
                leading: const Icon(Icons.person_add, color: Colors.green),
                title: const Text('Добавить участника',
                    style: TextStyle(color: Colors.green, fontSize: 14)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showAddMemberDialog();
                },
              ),
              const Divider(color: Colors.white12, height: 1),
            ],

            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: members.length,
                itemBuilder: (_, i) {
                  final uid  = members[i];
                  final name = _storage.getContactDisplayName(uid);
                  final isCreator = uid == creator;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFF0A2A3A),
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.cyan),
                      ),
                    ),
                    title: Text(name, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      isCreator ? '$uid · Администратор' : uid,
                      style: TextStyle(
                        color: isCreator
                            ? const Color(0xFF00D9FF).withValues(alpha: 0.7)
                            : Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showAddMemberDialog() {
    final ctrl = TextEditingController();
    String? error;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1A1F3C),
          title: Text('Добавить участника',
              style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 13)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'ID участника (6 цифр)',
                  labelStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF0A0E27),
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D9FF),
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                final uid = ctrl.text.trim();
                if (uid.length != 6 || int.tryParse(uid) == null) {
                  setD(() => error = 'Введи 6 цифр');
                  return;
                }
                final members = _storage.getGroupMembers(widget.targetUid);
                if (members.contains(uid)) {
                  setD(() => error = 'Уже участник');
                  return;
                }
                Navigator.pop(ctx);
                await _addMemberToGroup(uid);
              },
              child: const Text('ДОБАВИТЬ'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addMemberToGroup(String newUid) async {
    final groupId = widget.targetUid;
    // Упрощённая схема: сервер сам знает групповой ключ, просто добавляем участника
    _socket.send({
      'type':           'add_member',
      'group_id':       groupId,
      'new_member_uid': newUid,
    });
    // Обновляем локальное хранилище
    final members = _storage.getGroupMembers(groupId);
    if (!members.contains(newUid)) {
      members.add(newUid);
      final creator = _storage.getGroupCreator(groupId) ?? widget.myUid;
      final name    = _storage.getGroupName(groupId);
      await _storage.saveGroup(
        groupId:    groupId,
        groupName:  name,
        members:    members,
        creatorUid: creator,
      );
    }
    if (mounted) {
      setState(() {});
      _showSuccess('✅ $newUid добавлен в группу');
    }
  }
  void _showRenameGroupDialog() {
    final ctrl = TextEditingController(
      text: _storage.getGroupName(widget.targetUid),
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Переименовать группу',
            style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 13)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Название группы',
            labelStyle: TextStyle(color: Colors.white54),
            filled: true,
            fillColor: Color(0xFF0A0E27),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D9FF),
              foregroundColor: Colors.black,
            ),
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isEmpty) return;
              await _storage.setContactDisplayName(widget.targetUid, newName);
              // Обновляем метаданные группы
              final members = _storage.getGroupMembers(widget.targetUid);
              final creator = _storage.getGroupCreator(widget.targetUid) ?? widget.myUid;
              await _storage.saveGroup(
                groupId:   widget.targetUid,
                groupName: newName,
                members:   members,
                creatorUid: creator,
              );
              if (mounted) {
                setState(() {});
                Navigator.pop(ctx);
                _showSuccess('Название изменено');
              }
            },
            child: const Text('СОХРАНИТЬ'),
          ),
        ],
      ),
    );
  }

  void _showLeaveGroupDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Покинуть группу?',
            style: GoogleFonts.orbitron(color: Colors.red, fontSize: 13)),
        content: const Text(
          'Ты выйдешь из группы и перестанешь получать сообщения.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              // Отправляем событие на сервер
              _socket.send({
                'type':     'leave_group',
                'group_id': widget.targetUid,
              });
              // Удаляем группу из локального хранилища
              await _storage.removeContact(widget.targetUid);
              if (mounted) Navigator.of(context).pop(); // Выходим из чата
            },
            child: const Text('ПОКИНУТЬ'),
          ),
        ],
      ),
    );
  }

  void _showContactProfilePhoto(String displayName, String? avatarId) {
    final hasPhoto = avatarId != null && avatarId.isNotEmpty;
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, __, ___) => GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              backgroundColor: Colors.black54,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(displayName,
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
            body: Center(
              child: Hero(
                tag: 'contact_avatar_${widget.targetUid}',
                child: InteractiveViewer(
                  panEnabled:  true,
                  minScale:    0.5,
                  maxScale:    4.0,
                  child: hasPhoto
                      ? CachedNetworkImage(
                          imageUrl: '$SERVER_HTTP_URL/download/$avatarId',
                          fit: BoxFit.contain,
                          placeholder: (_, __) => const CircularProgressIndicator(color: Colors.cyan),
                          errorWidget: (_, __, ___) => _avatarFallback(displayName),
                        )
                      : _avatarFallback(displayName),
                ),
              ),
            ),
          ),
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  Widget _avatarFallback(String displayName) => CircleAvatar(
    radius: 80,
    backgroundColor: const Color(0xFF0A0E27),
    child: Text(
      displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
      style: const TextStyle(color: Colors.cyan, fontSize: 60),
    ),
  );

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
                        SnackBar(content: Text('✅ Сохранено: $newPath')),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
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
      _showError('Файл недоступен на этом устройстве');
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
            content: const Text('Файл сохранён в Downloads/DDchat'),
            action: SnackBarAction(label: 'ОК', onPressed: () {}),
          ));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Сохранено: $filePath')),
          );
        }
      }
    } catch (e) {
      debugPrint('Save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Сохранено в: $filePath')),
        );
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Message actions
  // ──────────────────────────────────────────────────────────────────────────

  void _showMessageActions(Map<String, dynamic> message) {
    final isMe = message['from'] == widget.myUid;
    final messageId = message['id'].toString();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag-handle
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // ── Quick Reactions Bar (Telegram-стиль) ────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ...['👍', '❤️', '🔥', '😂', '😮', '😢'].map((emoji) =>
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _addReaction(messageId, emoji);
                        },
                        child: Container(
                          width: 42, height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(emoji, style: const TextStyle(fontSize: 24)),
                          ),
                        ),
                      ),
                    ),
                    // Кнопка «+» для полного пикера
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _showFullEmojiPicker(messageId);
                      },
                      child: Container(
                        width: 42, height: 42,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: Icon(Icons.add, color: Colors.white54, size: 22),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 16),

              // ── Действия ────────────────────────────────────────────────────
              if (message['type'] == 'text')
                _actionTile(Icons.copy, 'Копировать', () {
                  Navigator.pop(ctx);
                  _copyMessageText(message['text'] as String? ?? '');
                }),
              if (message['type'] != 'text' && message['filePath'] != null)
                _actionTile(Icons.save_alt, 'Сохранить в галерею', () async {
                  Navigator.pop(ctx);
                  await _saveToGallery(message);
                }, color: Colors.greenAccent),
              _actionTile(Icons.reply, 'Ответить', () {
                Navigator.pop(ctx);
                _setReplyTo(message);
              }),
              _actionTile(Icons.forward, 'Переслать', () {
                Navigator.pop(ctx);
                _forwardMessage(message);
              }),
              if (isMe && message['type'] == 'text')
                _actionTile(Icons.edit, 'Редактировать', () {
                  Navigator.pop(ctx);
                  _startEditingMessage(message);
                }),
              if (isMe)
                _actionTile(Icons.delete, 'Удалить для всех', () {
                  Navigator.pop(ctx);
                  _confirmDelete(messageId, deleteForEveryone: true);
                }, color: Colors.red),
              _actionTile(Icons.delete_outline, 'Удалить у себя', () {
                Navigator.pop(ctx);
                _confirmDelete(messageId, deleteForEveryone: false);
              }, color: Colors.orange),
              // Сброс ключей — для дебага / фикса
              _actionTile(Icons.refresh, 'Сбросить ключи', () async {
                Navigator.pop(ctx);
                widget.cipher.clearSharedSecret(widget.targetUid);
                await _storage.clearCachedKeys(widget.targetUid);
                _socket.requestPublicKey(widget.targetUid);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🔑 Новые ключи запрошены'),
                      backgroundColor: Color(0xFF1A4A2E),
                      duration: Duration(seconds: 3),
                    ),
                  );
                }
              }, color: Colors.greenAccent),
            ],
          ),
        ),
      ),
    );
  }

  ListTile _actionTile(IconData icon, String label, VoidCallback onTap, {Color color = Colors.cyan}) =>
      ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(icon, color: color, size: 22),
        title: Text(label, style: TextStyle(color: color == Colors.cyan ? Colors.white : color, fontSize: 14)),
        onTap: onTap,
      );

  void _confirmDelete(String messageId, {required bool deleteForEveryone}) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Удалить сообщение?', style: TextStyle(color: Colors.white)),
        content: Text(
          deleteForEveryone
              ? 'Сообщение будет удалено у всех'
              : 'Сообщение будет удалено только у тебя',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ОТМЕНА'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteMessage(messageId, deleteForEveryone: deleteForEveryone);
            },
            child: const Text('УДАЛИТЬ', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  // ── Полный emoji-пикер (Telegram-стиль с категориями) ─────────────────────
  void _showFullEmojiPicker(String messageId) {
    const categories = <String, List<String>>{
      '😀': [
        '😀', '😃', '😄', '😁', '😆', '🥹', '😅', '🤣', '😂', '🙂', '😉', '😊',
        '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙', '🥲', '😋', '😛', '😜',
        '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🫡', '🤐', '🤨', '😐', '😑',
        '😶', '🫥', '😏', '😒', '🙄', '😬', '😮‍💨', '🤥', '🫠', '😌', '😔', '😪',
        '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮', '🥴', '😵', '🤯', '🥱', '😎',
      ],
      '👋': [
        '👍', '👎', '👊', '✊', '🤛', '🤜', '👏', '🙌', '🫶', '👐', '🤲', '🤝',
        '🙏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '👇', '☝️',
        '🫵', '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '💪', '🦾', '🖕', '✍️',
      ],
      '❤️': [
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❤️‍🔥', '❤️‍🩹',
        '💖', '💗', '💓', '💞', '💕', '💘', '💝', '💟', '♥️', '🫀', '💋', '💯',
        '🔥', '✨', '⭐', '🌟', '💫', '🎉', '🎊', '🎁', '🏆', '🥇', '🏅', '🎯',
      ],
      '🐱': [
        '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮',
        '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🦅', '🦆', '🦉', '🦋', '🐛', '🐝',
        '🐢', '🐍', '🦎', '🐙', '🦈', '🐬', '🐳', '🐠', '🦀', '🐚', '🌸', '🌺',
      ],
      '🍕': [
        '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈', '🍒', '🍑',
        '🥭', '🍍', '🥥', '🥝', '🍅', '🥑', '🍕', '🍔', '🌭', '🍟', '🍗', '🥩',
        '🌮', '🌯', '🥗', '🍜', '🍣', '🍱', '🍩', '🍪', '🎂', '🍰', '🧁', '☕',
        '🍺', '🍷', '🥂', '🍾', '🧃', '🥤', '🧋', '🍵',
      ],
      '⚽': [
        '⚽', '🏀', '🏈', '⚾', '🎾', '🏐', '🏉', '🎱', '🏓', '🏸', '🥊', '🎮',
        '🕹️', '🎲', '♟️', '🎯', '🎳', '🎪', '🎨', '🎬', '🎤', '🎧', '🎵', '🎶',
        '🎹', '🎸', '🎻', '🥁', '🎷', '🎺', '📱', '💻', '🖥️', '🔒', '🔑', '💡',
      ],
    };

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0A0E27),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        String activeCategory = categories.keys.first;
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.45,
            child: Column(
              children: [
                // Handle
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 8),
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Tabs
                SizedBox(
                  height: 40,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: categories.keys.map((cat) {
                      final isActive = cat == activeCategory;
                      return GestureDetector(
                        onTap: () => setSheetState(() => activeCategory = cat),
                        child: Container(
                          width: 40, height: 36,
                          decoration: BoxDecoration(
                            color: isActive
                                ? const Color(0xFF00D9FF).withValues(alpha: 0.15)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: isActive
                                ? Border.all(color: const Color(0xFF00D9FF).withValues(alpha: 0.4))
                                : null,
                          ),
                          child: Center(
                            child: Text(cat, style: TextStyle(fontSize: isActive ? 22 : 18)),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                // Grid
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 8,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemCount: categories[activeCategory]!.length,
                    itemBuilder: (_, i) {
                      final emoji = categories[activeCategory]![i];
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(ctx);
                          _addReaction(messageId, emoji);
                        },
                        child: Center(
                          child: Text(emoji, style: const TextStyle(fontSize: 26)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Message bubble
  // ──────────────────────────────────────────────────────────────────────────

  // ─── Рендер одного сообщения ─────────────────────────────────────────────
  // Логика отображения вынесена в lib/widgets/message_bubble.dart.
  // _ChatScreenState остаётся ответственным только за колбэки (действия).
  Widget _buildMessage(Map<String, dynamic> msg, int index) {
    final isGroup  = _storage.isGroup(widget.targetUid);
    final fromUid  = msg['from'] as String?;
    final isMe     = fromUid == widget.myUid;
    final senderName = (isGroup && !isMe && fromUid != null)
        ? _storage.getContactDisplayName(fromUid)
        : null;

    return _SwipeToReply(
      onReply: () => _setReplyTo(msg),
      child: MessageBubble(
        msg:             msg,
        myUid:           widget.myUid,
        playingMessageId: _playingMessageId,
        voicePosition:   _voicePosition,
        voiceDuration:   _voiceDuration,
        reactions:       _reactions,
        onLongPress:     _showMessageActions,
        onRetryDownload: _retryDownloadMedia,
        onPlayVoice:     _playVoiceMessage,
        onSeekVoice:     _seekVoice,
        onOpenImage:     _showFullImageFromFile,
        onOpenFile:      (path, name) => _openFile(path, name),
        onRemoveReaction: _removeReaction,
        senderName:      senderName,
      ),
    );
  }


  // Bubble widgets перенесены в lib/widgets/message_bubble.dart

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isGroup      = _storage.isGroup(widget.targetUid);
    final displayName  = isGroup
        ? _storage.getGroupName(widget.targetUid)
        : _storage.getContactDisplayName(widget.targetUid);
    final groupMembers = isGroup ? _storage.getGroupMembers(widget.targetUid) : <String>[];
    final displayMessages = _filteredMessages;

    return PopScope(
      canPop: !_isSendingFile,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSendingFile) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Подожди, пока файл загружается...')),
          );
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E27),
        appBar: _buildAppBar(displayName, isGroup: isGroup, groupMembers: groupMembers),
        body: Stack(
          children: [
            Column(
              children: [
                if (_replyToText != null) _buildReplyBanner(),
                // Предупреждение о лимите сообщений
                if (_messages.length >= 900)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: Colors.orange.withValues(alpha: 0.15),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber, color: Colors.orange, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Достигнут лимит ${_messages.length}/1000 сообщений. '
                            'Старые сообщения будут удалены автоматически.',
                            style: const TextStyle(color: Colors.orange, fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                // Вверху экрана — максимально близко к физическому глазку камеры,
                // чтобы пользователь смотрел в объектив, а не вниз
                top:   80,
                right: 16,
                child: Container(
                  width: 160, height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.cyan, width: 3),
                    boxShadow: [BoxShadow(color: Colors.cyan.withValues(alpha: 0.5), blurRadius: 10)],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(aspectRatio: 1, child: CameraPreview(_cameraController!)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Disappearing messages ─────────────────────────────────────────────────

  int? _calcExpireAt(int? ttlSeconds) {
    if (ttlSeconds == null || ttlSeconds <= 0) return null;
    return DateTime.now().millisecondsSinceEpoch + ttlSeconds * 1000;
  }

  void _scheduleDisappear(Map<String, dynamic> msg) {
    final expireAt = msg['expire_at'] as int?;
    if (expireAt == null) return;
    final remaining = expireAt - DateTime.now().millisecondsSinceEpoch;
    if (remaining <= 0) {
      _removeMessage(msg['id']?.toString());
      return;
    }
    Future.delayed(Duration(milliseconds: remaining), () {
      if (mounted) _removeMessage(msg['id']?.toString());
    });
  }

  void _removeMessage(String? msgId) {
    if (msgId == null) return;
    setState(() {
      _messages.removeWhere((m) => m['id']?.toString() == msgId);
      _messageIds.remove(msgId);
    });
    _storage.deleteMessage(widget.targetUid, msgId);
  }

  void _startDisappearTimers() {
    for (final msg in List.of(_messages)) {
      _scheduleDisappear(msg);
    }
  }

  void _showTtlPicker() {
    final currentTtl = _storage.getMessageTtl(widget.targetUid);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Исчезающие сообщения', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            ...AppConfig.disappearingMessageOptions.map((seconds) {
              final label = AppConfig.formatTtl(seconds);
              final isSelected = currentTtl == seconds;
              return ListTile(
                leading: Icon(
                  seconds == 0 ? Icons.timer_off : Icons.timer,
                  color: isSelected ? Colors.cyan : Colors.white54,
                ),
                title: Text(label, style: TextStyle(color: isSelected ? Colors.cyan : Colors.white)),
                trailing: isSelected ? const Icon(Icons.check, color: Colors.cyan) : null,
                onTap: () {
                  _storage.setMessageTtl(widget.targetUid, seconds);
                  Navigator.pop(ctx);
                  setState(() {});
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(seconds == 0
                          ? 'Исчезающие сообщения выключены'
                          : 'Сообщения будут исчезать через $label'),
                      backgroundColor: const Color(0xFF1A4A2E),
                    ));
                  }
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Медиагалерея ──────────────────────────────────────────────────────────

  void _openMediaGallery() {
    final displayName = _storage.isGroup(widget.targetUid)
        ? _storage.getGroupName(widget.targetUid)
        : _storage.getContactDisplayName(widget.targetUid);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MediaGalleryScreen(
          chatWith: widget.targetUid,
          chatName: displayName,
          onOpenImage: _showFullImageFromFile,
        ),
      ),
    );
  }

  // ── Блокировка ────────────────────────────────────────────────────────────

  void _toggleBlockUser() {
    final isBlocked = _storage.isBlocked(widget.targetUid);
    final name = _storage.getContactDisplayName(widget.targetUid);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text(isBlocked ? 'Разблокировать?' : 'Заблокировать?',
            style: const TextStyle(color: Colors.white)),
        content: Text(
          isBlocked
              ? '$name сможет снова отправлять вам сообщения и звонить.'
              : '$name не сможет отправлять вам сообщения и звонить.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ОТМЕНА')),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (isBlocked) {
                await _storage.unblockUser(widget.targetUid);
                _socket.unblockUser(widget.targetUid);
              } else {
                await _storage.blockUser(widget.targetUid);
                _socket.blockUser(widget.targetUid);
              }
              if (mounted) {
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(isBlocked ? '$name разблокирован' : '$name заблокирован'),
                ));
              }
            },
            child: Text(isBlocked ? 'РАЗБЛОКИРОВАТЬ' : 'ЗАБЛОКИРОВАТЬ',
                style: TextStyle(color: isBlocked ? Colors.green : Colors.red)),
          ),
        ],
      ),
    );
  }

  // ── Даунсэмплирование амплитуд ─────────────────────────────────────────
  List<double> _downsampleAmplitudes(List<double> input, int targetCount) {
    if (input.isEmpty) return List.filled(targetCount, 0.3);
    if (input.length <= targetCount) {
      return [...input, ...List.filled(targetCount - input.length, 0.2)];
    }
    final step = input.length / targetCount;
    return List.generate(targetCount, (i) {
      final start = (i * step).floor();
      final end   = ((i + 1) * step).floor().clamp(start + 1, input.length);
      final chunk = input.sublist(start, end);
      return chunk.reduce((a, b) => a > b ? a : b); // peak в окне
    });
  }

  // ── Планирование сообщений ────────────────────────────────────────────────

  void _showScheduleDialog() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Отправить позже', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            ...[
              _scheduleOption(ctx, 'Через 5 минут',  const Duration(minutes: 5)),
              _scheduleOption(ctx, 'Через 15 минут', const Duration(minutes: 15)),
              _scheduleOption(ctx, 'Через 1 час',    const Duration(hours: 1)),
              _scheduleOption(ctx, 'Через 3 часа',   const Duration(hours: 3)),
            ],
            ListTile(
              leading: const Icon(Icons.access_time, color: Colors.cyan),
              title: const Text('Выбрать время...', style: TextStyle(color: Colors.cyan)),
              onTap: () async {
                Navigator.pop(ctx);
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.fromDateTime(
                    DateTime.now().add(const Duration(minutes: 30)),
                  ),
                );
                if (time != null) {
                  final now = DateTime.now();
                  var scheduled = DateTime(now.year, now.month, now.day, time.hour, time.minute);
                  if (scheduled.isBefore(now)) scheduled = scheduled.add(const Duration(days: 1));
                  _scheduleMessage(text, scheduled.difference(now));
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  ListTile _scheduleOption(BuildContext ctx, String label, Duration delay) {
    return ListTile(
      leading: const Icon(Icons.schedule, color: Colors.white70),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      onTap: () {
        Navigator.pop(ctx);
        _scheduleMessage(_messageController.text.trim(), delay);
      },
    );
  }

  void _scheduleMessage(String text, Duration delay) {
    _messageController.clear();
    final sendAt = DateTime.now().add(delay);
    final timeStr = '${sendAt.hour.toString().padLeft(2, '0')}:${sendAt.minute.toString().padLeft(2, '0')}';

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('📅 Сообщение запланировано на $timeStr'),
      backgroundColor: const Color(0xFF1A4A2E),
      action: SnackBarAction(
        label: 'ОТМЕНА',
        textColor: Colors.cyan,
        onPressed: () {
          if (_scheduledTimers.isNotEmpty) {
            _scheduledTimers.last.cancel();
            _scheduledTimers.removeLast();
          }
        },
      ),
    ));

    final timer = Timer(delay, () {
      if (mounted) {
        _sendMessage(text: text);
      }
    });
    _scheduledTimers.add(timer);
  }

  // ── Настройки группы ────────────────────────────────────────────────────

  void _openGroupSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupSettingsScreen(
          myUid:   widget.myUid,
          groupId: widget.targetUid,
        ),
      ),
    );
  }

  // ── Стикеры ───────────────────────────────────────────────────────────────

  void _showStickerPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0A0E27),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StickerPicker(
        onStickerSelected: (sticker, packName) {
          Navigator.pop(context);
          _sendSticker(sticker);
        },
      ),
    );
  }

  Future<void> _sendSticker(String sticker) async {
    await _sendMessage(text: sticker, messageType: 'sticker');
  }

  // ── Вызов ─────────────────────────────────────────────────────────────────
  void _startCall(String callType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          myUid:     widget.myUid,
          targetUid: widget.targetUid,
          callType:  callType,
          isIncoming: false,
        ),
      ),
    );
  }

  AppBar _buildAppBar(String displayName, {bool isGroup = false, List<String> groupMembers = const []}) {
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
                GestureDetector(
                  onTap: () => _showContactProfilePhoto(displayName, avatar),
                  child: Hero(
                    tag: 'contact_avatar_${widget.targetUid}',
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: isGroup ? const Color(0xFF0A2A3A) : const Color(0xFF0A0E27),
                      backgroundImage: (!isGroup && avatar != null && avatar.isNotEmpty)
                          ? CachedNetworkImageProvider('$SERVER_HTTP_URL/download/$avatar')
                          : null,
                      child: isGroup
                          ? const Icon(Icons.group, color: Color(0xFF00D9FF), size: 18)
                          : (avatar == null || avatar.isEmpty)
                              ? Text(
                                  displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.cyan, fontSize: 14),
                                )
                              : null,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName, style: GoogleFonts.orbitron(fontSize: 14)),
                      if (isGroup)
                        Builder(builder: (_) {
                          final typers = _groupTypingMap.keys
                              .map(_storage.getContactDisplayName)
                              .toList();
                          if (typers.isEmpty) {
                            return Text(
                              '${groupMembers.length} участников',
                              style: const TextStyle(fontSize: 10, color: Colors.white54),
                            );
                          }
                          return Text('${typers.length == 1 ? typers[0] : "${typers.length} чел."} печатает...',
                              style: const TextStyle(fontSize: 10, color: Colors.cyan));
                        })
                      else if (_targetIsTyping)
                        const Text('печатает...', style: TextStyle(fontSize: 10, color: Colors.cyan))
                      else if (isOnline)
                        const Text('онлайн', style: TextStyle(fontSize: 10, color: Colors.green))
                      else if (lastSeen > 0)
                        Text(
                          'был(а) ${_formatLastSeen(lastSeen)}',
                          style: const TextStyle(fontSize: 10, color: Colors.white54),
                        ),
                    ],
                  ),
                ),
              ],
            ),
      actions: [
        // ── Кнопки вызова (только для личных чатов) ─────────────────────
        if (!isGroup && !_isSearching) ...[
          IconButton(
            icon: const Icon(Icons.call, color: Colors.white70, size: 20),
            tooltip: 'Голосовой вызов',
            onPressed: () => _startCall('audio'),
          ),
          IconButton(
            icon: const Icon(Icons.videocam, color: Colors.white70, size: 20),
            tooltip: 'Видеозвонок',
            onPressed: () => _startCall('video'),
          ),
        ],
        IconButton(
          icon: Icon(_isSearching ? Icons.close : Icons.search),
          onPressed: _toggleSearch,
        ),
        if (!_isSearching)
          PopupMenuButton<String>(
            color: const Color(0xFF1A1F3C),
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            onSelected: (value) async {
              switch (value) {
                case 'gallery':   _openMediaGallery(); break;
                case 'timer':     _showTtlPicker(); break;
                case 'block':     _toggleBlockUser(); break;
                case 'members':   _showGroupMembersDialog(displayName, groupMembers); break;
                case 'rename':    _showRenameGroupDialog(); break;
                case 'leave':     _showLeaveGroupDialog(); break;
                case 'group_settings': _openGroupSettings(); break;
              }
            },
            itemBuilder: (_) {
              final ttl = _storage.getMessageTtl(widget.targetUid);
              final blocked = !isGroup && _storage.isBlocked(widget.targetUid);
              return [
                _popupItem('gallery', Icons.photo_library_outlined, 'Медиагалерея'),
                PopupMenuItem(
                  value: 'timer',
                  child: Row(children: [
                    Icon(ttl > 0 ? Icons.timer : Icons.timer_off_outlined,
                        color: ttl > 0 ? Colors.cyan : Colors.white70, size: 20),
                    const SizedBox(width: 12),
                    Text(ttl > 0 ? 'Таймер: ${AppConfig.formatTtl(ttl)}' : 'Исчезающие сообщения',
                        style: TextStyle(color: ttl > 0 ? Colors.cyan : Colors.white)),
                  ]),
                ),
                if (isGroup) ...[
                  const PopupMenuDivider(),
                  _popupItem('group_settings', Icons.admin_panel_settings, 'Настройки группы'),
                  _popupItem('members', Icons.group, 'Участники группы'),
                  _popupItem('rename', Icons.edit, 'Переименовать'),
                  const PopupMenuDivider(),
                  PopupMenuItem(value: 'leave', child: Row(children: [
                    const Icon(Icons.exit_to_app, color: Colors.red, size: 20),
                    const SizedBox(width: 12),
                    const Text('Покинуть группу', style: TextStyle(color: Colors.red)),
                  ])),
                ],
                if (!isGroup) ...[
                  const PopupMenuDivider(),
                  PopupMenuItem(value: 'block', child: Row(children: [
                    Icon(blocked ? Icons.lock_open : Icons.block,
                        color: blocked ? Colors.green : Colors.red, size: 20),
                    const SizedBox(width: 12),
                    Text(blocked ? 'Разблокировать' : 'Заблокировать',
                        style: TextStyle(color: blocked ? Colors.green : Colors.red)),
                  ])),
                ],
              ];
            },
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_replyToSender != null)
                Text(
                  _replyToSender!,
                  style: const TextStyle(color: Colors.cyan, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              Text(
                _replyToText!,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
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
              icon: const Icon(Icons.attach_file, color: Colors.cyan),
              onSelected: (value) {
                switch (value) {
                  case 'photo_camera':  _sendPhoto(source: ImageSource.camera);  break;
                  case 'photo_gallery': _sendPhoto(source: ImageSource.gallery); break;
                  case 'video':         _sendVideo();                            break;
                  case 'file':          _sendFile();                             break;
                }
              },
              itemBuilder: (_) => [
                // ── Медиа (фото) ──────────────────────────────────────────────
                _popupItem('photo_camera',  Icons.camera_alt,        'Сфотографировать'),
                _popupItem('photo_gallery', Icons.photo_library,     'Фото из галереи'),
                // ── Видео ──────────────────────────────────────────────────────
                _popupItem('video',         Icons.video_library,     'Видео из галереи'),
                // ── Файлы ─────────────────────────────────────────────────────
                _popupItem('file',          Icons.insert_drive_file, 'Файл / Документ'),
              ],
            ),

            // Кнопка стикеров
            IconButton(
              icon: const Icon(Icons.emoji_emotions_outlined, color: Colors.white54, size: 22),
              tooltip: 'Стикеры',
              onPressed: _showStickerPicker,
            ),

            if (_isSendingFile || _downloadingMsgId != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 24, height: 24,
                      child: CircularProgressIndicator(
                        value: _downloadingMsgId != null ? _downloadProgress : _uploadProgress,
                        strokeWidth: 3,
                        color: _downloadingMsgId != null ? Colors.green : Colors.cyan,
                      ),
                    ),
                    Text(
                      _downloadingMsgId != null
                          ? '${(_downloadProgress * 100).toInt()}%'
                          : '${(_uploadProgress * 100).toInt()}%',
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
                  return GestureDetector(
                    onLongPress: _showScheduleDialog,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.cyan),
                      onPressed: _sendMessage,
                    ),
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
// VideoNotePlayer и VideoGalleryPlayer перенесены в lib/widgets/video_players.dart

// ─── Свайп для ответа ────────────────────────────────────────────────────────
class _SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback onReply;
  const _SwipeToReply({required this.child, required this.onReply});
  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  double _drag = 0;
  bool   _fired = false;
  static const double _trigger = 64.0;
  static const double _maxDrag = 80.0;
  late AnimationController _ctrl;
  late Animation<double>   _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    _anim = const AlwaysStoppedAnimation(0);
    _ctrl.addListener(() { if (mounted) setState(() => _drag = _anim.value); });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _onUpdate(DragUpdateDetails d) {
    if ((d.primaryDelta ?? 0) > 0) return;
    final next = (_drag + (d.primaryDelta ?? 0)).clamp(-_maxDrag, 0.0);
    setState(() => _drag = next);
    if (!_fired && next <= -_trigger) {
      _fired = true;
      HapticFeedback.mediumImpact();
    }
  }

  void _onEnd(DragEndDetails _) {
    if (_fired) widget.onReply();
    _fired = false;
    _anim = Tween(begin: _drag, end: 0.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final pct = ((-_drag - 16) / (_trigger - 16)).clamp(0.0, 1.0);
    return GestureDetector(
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      child: Stack(clipBehavior: Clip.none, children: [
        if (_drag < -16)
          Positioned(
            right: 8, top: 0, bottom: 0,
            child: Center(
              child: Opacity(
                opacity: pct,
                child: Transform.scale(
                  scale: 0.5 + 0.5 * pct,
                  child: Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF00D9FF).withValues(alpha: 0.15),
                      border: Border.all(color: const Color(0xFF00D9FF).withValues(alpha: 0.6)),
                    ),
                    child: const Icon(Icons.reply_rounded, color: Color(0xFF00D9FF), size: 18),
                  ),
                ),
              ),
            ),
          ),
        Transform.translate(
          offset: Offset(_drag, 0),
          child: widget.child,
        ),
      ]),
    );
  }
}

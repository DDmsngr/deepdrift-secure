import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import 'identity_service.dart';
import 'chat_screen.dart';
import 'storage_service.dart';
import 'socket_service.dart';
import 'crypto_service.dart';
import 'notification_service.dart';
import 'settings_screen.dart';
import 'providers/app_providers.dart';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'models/chat_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Tab indices
// ─────────────────────────────────────────────────────────────────────────────
class _Tab {
  static const int favorites = 0;
  static const int contacts  = 1;
  static const int groups    = 2;
  static const int channels  = 3;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {

  String?      _myUid;
  List<String> _chats = [];
  final Map<String, Map<String, bool>> _groupTypingUsers = {};
  bool         _isConnected      = false;
  bool         _isReady          = false;
  String       _connectionStatus = 'ОФФЛАЙН';
  StreamSubscription? _socketSub;

  final _idService   = IdentityService();
  final _storage     = StorageService();
  final _socket      = SocketService();
  late  SecureCipher _cipher;
  final _imagePicker = ImagePicker();

  final _serverController = TextEditingController(
    text: 'wss://deepdrift-backend.onrender.com/ws',
  );

  bool   _isSearching = false;
  final  _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];

  late TabController _tabController;
  Timer? _statusCheckTimer;

  // ─────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cipher = context.read<CipherProvider>().cipher;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() => setState(() {}));
    NotificationService().setOpenChatCallback(_openChatWithUid);
    _setup();
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_isConnected) _socket.checkStatuses(_chats);
    });
  }

  @override
  void dispose() {
    NotificationService().clearOpenChatCallback();
    WidgetsBinding.instance.removeObserver(this);
    _socketSub?.cancel();
    _statusCheckTimer?.cancel();
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_socket.isConnected) _socket.forceReconnect();
      _socket.checkStatuses(_chats);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Tab filtering
  // ─────────────────────────────────────────────────────────────────────────

  List<String> _filteredChats(int tabIndex) {
    switch (tabIndex) {
      case _Tab.favorites:
        return _chats.where((uid) => _storage.isContactPinned(uid)).toList();
      case _Tab.contacts:
        return _chats.where((uid) => !_storage.isGroup(uid) && !_storage.isChannel(uid)).toList();
      case _Tab.groups:
        return _chats.where((uid) => _storage.isGroup(uid)).toList();
      case _Tab.channels:
        return _chats.where((uid) => _storage.isChannel(uid)).toList();
      default:
        return _chats;
    }
  }

  int _unreadForTab(int tabIndex) {
    int count = 0;
    for (final uid in _filteredChats(tabIndex)) {
      count += _storage.getUnreadCount(uid);
    }
    return count;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Navigation
  // ─────────────────────────────────────────────────────────────────────────

  void _openChatWithUid(String fromUid) {
    if (!mounted) return;
    if (!_chats.contains(fromUid)) {
      _socket.getProfile(fromUid);
      _storage.addContact(fromUid, displayName: fromUid);
      if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
    }
    if (!_isReady || _myUid == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openChatWithUid(fromUid));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ChatScreen(myUid: _myUid!, targetUid: fromUid, cipher: _cipher)),
    ).then((_) {
      if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Setup & Connection
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _setup() async {
    try {
      await _storage.init();
      final uid = await _idService.getStoredUID();
      if (uid == null) {
        if (mounted) await _showOnboarding();
      } else {
        setState(() => _myUid = uid);
        await _autoConnect();
      }
    } catch (e) {
      if (mounted) setState(() { _connectionStatus = 'ОШИБКА'; _isReady = true; });
    }
  }

  Future<void> _autoConnect() async {
    try {
      setState(() => _connectionStatus = 'ПОДКЛЮЧЕНИЕ...');

      // SECURITY FIX: пароль не читается из хранилища — только salt + ключи
      final savedSalt       = _storage.getSetting('user_salt');
      final authToken       = _storage.getSetting('auth_token');
      final savedX25519Key  = _storage.getSetting('encrypted_x25519_key');
      final savedEd25519Key = _storage.getSetting('encrypted_ed25519_key');

      if (savedSalt == null) {
        if (mounted) await _showPasswordSetupDialog();
        return;
      }

      if (!_cipher.isInitialized) {
        if (mounted) await _showUnlockWithPasswordDialog();
        return;
      }

      _socket.init(_cipher);

      _socket.onAuthFailed = (reason) {
        if (!mounted) return;
        final msg = reason == 'uid_taken'
            ? 'Этот ID занят другим устройством. Импортируйте файл ключей.'
            : 'Ошибка аутентификации: $reason.';
        _showError(msg);
        setState(() { _connectionStatus = 'ОШИБКА АВТОРИЗАЦИИ'; _isReady = true; });
        _showImportKeysDialog();
      };

      _socket.connect(_serverController.text, _myUid!, authToken: authToken);

      _socketSub = _socket.messages.listen((data) {
        if (!mounted) return;
        final type = data['type'];

        if (type == 'uid_assigned') {
          setState(() { _isConnected = true; _connectionStatus = 'В СЕТИ'; });
          _registerPublicKeysOnServer();
          _socket.checkStatuses(_storage.getContacts());
          _registerAccountOnServer();
        }
        if (type == 'connection_status') {
          setState(() {
            _isConnected      = data['connected'] as bool? ?? false;
            _connectionStatus = _isConnected ? 'В СЕТИ' : 'ОФФЛАЙН';
          });
        }
        if (type == 'connection_failed') setState(() => _connectionStatus = 'ОШИБКА СЕТИ');
        if (type == 'user_status') {
          _storage.setContactStatus(data['uid'] as String, data['status'] == 'online', data['last_seen'] as int?);
          if (mounted) setState(() {});
        }
        if (type == 'typing_indicator') {
          final groupId  = data['group_id'] as String?;
          final fromUid  = data['from_uid'] as String?;
          final isTyping = data['typing'] == true;
          if (groupId != null && fromUid != null) {
            _groupTypingUsers.putIfAbsent(groupId, () => {})[fromUid] = isTyping;
            if (mounted) setState(() {});
          }
        }
        if (type == 'message') _handleIncomingMessageQuietly(data);
        if (type == 'group_invited' || type == 'group_added' || type == 'group_created') _handleGroupAdded(data);
        if (type == 'message' || type == 'status_update' || type == 'message_deleted' || type == 'user_status') {
          setState(() => _chats = _storage.getContactsSortedByActivity());
        }
      });

      setState(() { _isReady = true; _chats = _storage.getContactsSortedByActivity(); });
    } catch (e) {
      setState(() { _connectionStatus = 'ОШИБКА'; _isReady = true; });
    }
  }

  // SECURITY FIX: разблокировка по паролю без его хранения
  Future<void> _showUnlockWithPasswordDialog() async {
    final pwdCtrl  = TextEditingController();
    bool   obscure = true;
    String? error;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (ctx, setS) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1A1F3C),
            title: Text('ВВЕДИ ПАРОЛЬ', style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 14)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
                  ),
                  child: const Row(children: [
                    Icon(Icons.lock_outline, color: Colors.orange, size: 16),
                    SizedBox(width: 8),
                    Expanded(child: Text('Для расшифровки ключей введи пароль аккаунта.',
                        style: TextStyle(color: Colors.orange, fontSize: 11))),
                  ]),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: pwdCtrl, obscureText: obscure, autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Пароль', labelStyle: const TextStyle(color: Colors.white54),
                    filled: true, fillColor: const Color(0xFF0A0E27), border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
                      onPressed: () => setS(() => obscure = !obscure),
                    ),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                ],
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () async {
                  final salt       = _storage.getSetting('user_salt') as String?;
                  final x25519Key  = _storage.getSetting('encrypted_x25519_key') as String?;
                  final ed25519Key = _storage.getSetting('encrypted_ed25519_key') as String?;
                  if (salt == null) { setS(() => error = 'Данные аккаунта не найдены'); return; }
                  try {
                    await _cipher.init(pwdCtrl.text, salt,
                        encryptedX25519Key: x25519Key, encryptedEd25519Key: ed25519Key);
                    if (!_cipher.isInitialized) { setS(() => error = 'Неверный пароль'); return; }
                    Navigator.pop(ctx);
                    await _autoConnect();
                  } catch (_) {
                    setS(() => error = 'Неверный пароль или данные повреждены');
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D9FF), foregroundColor: Colors.black),
                child: const Text('РАЗБЛОКИРОВАТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _registerPublicKeysOnServer() async {
    try {
      final x25519Key  = await _cipher.getMyPublicKey();
      final ed25519Key = await _cipher.getMySigningKey();
      _socket.registerPublicKeys(x25519Key, ed25519Key);
    } catch (e) { debugPrint('Failed to register public keys: $e'); }
  }

  Future<void> _registerAccountOnServer() async {
    if (_myUid == null) return;
    try {
      final ed25519Key = await _cipher.getMySigningKey();
      _socket.registerNewAccount(_myUid!, ed25519Key);
    } catch (e) { debugPrint('Failed to register account: $e'); }
  }

  Future<void> _handleGroupAdded(Map<String, dynamic> data) async {
    final groupId    = data['group_id'] as String?;
    final groupName  = data['group_name'] as String? ?? groupId ?? 'Новая группа';
    final creatorUid = data['creator_uid'] as String? ?? data['from_uid'] as String? ?? '';
    final rawMembers = data['members'];
    final members    = rawMembers is List ? rawMembers.map((e) => e.toString()).toList() : <String>[];
    if (groupId == null) return;
    await _storage.saveGroup(groupId: groupId, groupName: groupName, members: members, creatorUid: creatorUid);
    _socket.requestGroupKey(groupId);
    final creatorName = _storage.getContactDisplayName(creatorUid);
    await NotificationService().showMessageNotification(
      fromUid: groupId, displayName: groupName, messageText: '$creatorName добавил(а) вас в группу',
    );
    if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
  }

  Future<void> _handleIncomingMessageQuietly(Map<String, dynamic> data) async {
    final senderUid = data['from_uid'] as String?;
    final groupId   = data['group_id'] as String?;
    final msgId     = data['id']?.toString();
    if (senderUid == null || msgId == null) return;

    final storageKey = (groupId != null && groupId.isNotEmpty) ? groupId : senderUid;
    if (_storage.hasMessage(storageKey, msgId)) return;

    // SECURITY FIX: незнакомцы идут в очередь запросов, а не сразу в контакты
    final contacts = _storage.getContacts();
    if (!contacts.contains(senderUid) && groupId == null) {
      await _storage.addIncomingRequest(senderUid);
      _socket.getProfile(senderUid);
      await NotificationService().showMessageNotification(
        fromUid: senderUid,
        displayName: _storage.getContactDisplayName(senderUid),
        messageText: 'Новый запрос на переписку',
      );
      if (mounted) setState(() {});
      return;
    }

    try {
      if (!_cipher.hasSharedSecret(senderUid)) await _cipher.tryLoadCachedKeys(senderUid, _storage);

      final encryptedText = data['encrypted_text'] as String? ?? '';
      final String decrypted;

      if (_cipher.hasSharedSecret(senderUid)) {
        decrypted = await _cipher.decryptText(encryptedText, fromUid: senderUid);
      } else {
        final pendingMsg = {
          'id': msgId, 'text': '', 'isMe': false,
          'time': data['time'] ?? DateTime.now().millisecondsSinceEpoch,
          'from': senderUid, 'to': _myUid, 'status': 'pending_decrypt',
          'type': data['messageType'] ?? 'text', 'encrypted_text': encryptedText,
          'signature': data['signature'], 'mediaData': data['mediaData'],
          'fileName': data['fileName'], 'fileSize': data['fileSize'],
          'signatureStatus': SignatureStatus.unknown.index,
        };
        await _storage.saveMessage(storageKey, pendingMsg);
        await NotificationService().showMessageNotification(
          fromUid: storageKey,
          displayName: (groupId != null) ? _storage.getGroupName(groupId) : _storage.getContactDisplayName(senderUid),
          messageText: 'Новое зашифрованное сообщение',
        );
        if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
        return;
      }

      if (decrypted.startsWith('[⚠️') || decrypted.startsWith('[❌')) return;

      final msg = {
        'id': msgId, 'text': decrypted, 'isMe': false,
        'time': data['time'] ?? DateTime.now().millisecondsSinceEpoch,
        'from': senderUid, 'to': _myUid, 'status': 'delivered',
        'type': data['messageType'] ?? 'text',
        'mediaData': data['mediaData'], 'fileName': data['fileName'], 'fileSize': data['fileSize'],
        'signatureStatus': SignatureStatus.unknown.index,
      };
      await _storage.saveMessage(storageKey, msg);
      _socket.sendReadReceipt(senderUid, msgId);

      // IMPROVEMENT: preview текста в уведомлении + имя отправителя в группах
      final senderName  = _storage.getContactDisplayName(senderUid);
      final previewText = decrypted.length > 60 ? '${decrypted.substring(0, 60)}…' : decrypted;
      final displayName = (groupId != null) ? '${_storage.getGroupName(groupId)} · $senderName' : senderName;
      await NotificationService().showMessageNotification(
        fromUid: storageKey, displayName: displayName, messageText: previewText,
      );
      if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
    } catch (e) {
      debugPrint('Quiet save error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  void _showLegalDocFromContext(BuildContext ctx, {required String title, required String assetPath}) {
    showModalBottomSheet(
      context: ctx, backgroundColor: const Color(0xFF0A0E27), isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false, initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.4,
        builder: (_, ctrl) => Column(
          children: [
            Container(margin: const EdgeInsets.only(top: 12, bottom: 4), width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
              child: Row(children: [
                const Icon(Icons.article_outlined, color: Color(0xFF00D9FF), size: 20),
                const SizedBox(width: 10),
                Expanded(child: Text(title, style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 13))),
                IconButton(icon: const Icon(Icons.close, color: Colors.white38, size: 20), onPressed: () => Navigator.pop(ctx)),
              ]),
            ),
            const Divider(color: Colors.white12, height: 1),
            Expanded(
              child: FutureBuilder<String>(
                future: rootBundle.loadString(assetPath),
                builder: (_, snap) {
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xFF00D9FF)));
                  return Markdown(
                    controller: ctrl, data: snap.data!,
                    styleSheet: MarkdownStyleSheet(
                      p: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                      h1: TextStyle(color: const Color(0xFF00D9FF), fontSize: 18, fontWeight: FontWeight.bold,
                          fontFamily: GoogleFonts.orbitron().fontFamily),
                      h2: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      strong: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      listBullet: const TextStyle(color: Color(0xFF00D9FF)),
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cacheKeyFingerprint() async {
    try {
      final x25519B64  = await _cipher.getMyPublicKey();
      final ed25519B64 = await _cipher.getMySigningKey();
      await _storage.saveSetting('cached_key_fingerprint', '$x25519B64:$ed25519B64');
    } catch (e) { debugPrint('Could not cache key fingerprint: $e'); }
  }

  void _openQrScanner() {
    final scannerCtrl = MobileScannerController();
    bool handled = false;
    showModalBottomSheet(
      context: context, backgroundColor: Colors.black, isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const Icon(Icons.qr_code_scanner, color: Colors.cyan),
                const SizedBox(width: 12),
                const Expanded(child: Text('Наведи камеру на QR-код контакта',
                    style: TextStyle(color: Colors.white, fontSize: 14))),
                IconButton(icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () { scannerCtrl.stop(); Navigator.pop(ctx); }),
              ]),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MobileScanner(
                  controller: scannerCtrl,
                  onDetect: (capture) {
                    if (handled) return;
                    final rawValue = capture.barcodes.firstOrNull?.rawValue;
                    if (rawValue == null || rawValue.isEmpty) return;
                    final uid = rawValue.trim();
                    if (uid.contains(' ') || uid.length < 4) return;
                    handled = true;
                    scannerCtrl.stop();
                    Navigator.pop(ctx);
                    _storage.addContact(uid, displayName: uid);
                    _socket.getProfile(uid);
                    setState(() => _chats = _storage.getContactsSortedByActivity());
                    _openChatWithUid(uid);
                    _showSuccess('Контакт добавлен: $uid');
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ).whenComplete(() => scannerCtrl.dispose());
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red));
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: const Color(0xFF1A4A2E)));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Profile dialog
  // ─────────────────────────────────────────────────────────────────────────

  void _showMyProfileDialog() {
    final profile      = _storage.getMyProfile();
    final nameCtrl     = TextEditingController(text: profile['nickname']);
    String? currentAvatar = profile['avatarUrl'];

    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setDialogState) {
          final hasAvatar = currentAvatar != null && currentAvatar!.isNotEmpty && currentAvatar != 'null';
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1F3C),
            title: Text('Мой профиль', style: GoogleFonts.orbitron()),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () async {
                      final img = await _imagePicker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512);
                      if (img != null) {
                        final fileId = await _socket.uploadFile(File(img.path));
                        if (fileId != null) { setDialogState(() => currentAvatar = fileId); }
                        else { _showError('Ошибка загрузки аватара'); }
                      }
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(36),
                      child: Container(
                        width: 80, height: 80,
                        color: const Color(0xFF0A0E27),
                        child: hasAvatar
                            ? Image.network('https://deepdrift-backend.onrender.com/download/$currentAvatar', fit: BoxFit.cover)
                            : const Icon(Icons.add_a_photo, size: 30, color: Colors.cyan),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Твой ID: $_myUid', style: const TextStyle(color: Colors.cyan, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: QrImageView(data: _myUid ?? '000000', version: QrVersions.auto, size: 140.0, backgroundColor: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  const Text('Покажи этот QR-код другу\nдля быстрого добавления',
                      textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl, style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'Твое имя (никнейм)', filled: true, fillColor: Color(0xFF0A0E27), border: OutlineInputBorder()),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('ОТМЕНА')),
              ElevatedButton(
                onPressed: () async {
                  await _storage.saveMyProfile(nickname: nameCtrl.text.trim(), avatarUrl: currentAvatar);
                  _socket.updateProfile(nameCtrl.text.trim(), currentAvatar);
                  Navigator.pop(context);
                  setState(() {});
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
                child: const Text('СОХРАНИТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Onboarding
  // ─────────────────────────────────────────────────────────────────────────

  // Вынесенный ToS-виджет — используется в нескольких диалогах (DRY)
  Widget _buildTosCheckbox(BuildContext ctx, bool value, ValueChanged<bool?>? onChanged) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(value: value, activeColor: const Color(0xFF00D9FF), checkColor: Colors.black, onChanged: onChanged),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              children: [
                const Text('Я прочитал и принимаю ', style: TextStyle(color: Colors.white70, fontSize: 12)),
                GestureDetector(
                  onTap: () => _showLegalDocFromContext(ctx, title: 'Условия использования', assetPath: 'assets/terms_of_service.md'),
                  child: const Text('Условия использования', style: TextStyle(color: Color(0xFF00D9FF), fontSize: 12, decoration: TextDecoration.underline)),
                ),
                const Text(' и ', style: TextStyle(color: Colors.white70, fontSize: 12)),
                GestureDetector(
                  onTap: () => _showLegalDocFromContext(ctx, title: 'Политику конфиденциальности', assetPath: 'assets/privacy_policy.md'),
                  child: const Text('Политику конфиденциальности', style: TextStyle(color: Color(0xFF00D9FF), fontSize: 12, decoration: TextDecoration.underline)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showOnboarding() async {
    final uid = await _showStep1ChooseUid();
    if (uid == null || !mounted) return;
    final password = await _showStep2CreatePassword();
    if (password == null || !mounted) return;
    final salt = SecureCipher.generateSalt();
    await _cipher.init(password, salt);
    final keys = await _cipher.exportBothKeys(password);
    await _idService.saveUID(uid);
    // SECURITY FIX: пароль НЕ сохраняется
    await _storage.saveSetting('user_salt', salt);
    await _storage.saveSetting('encrypted_x25519_key', keys['x25519']!);
    await _storage.saveSetting('encrypted_ed25519_key', keys['ed25519']!);
    await _cacheKeyFingerprint();
    if (mounted) setState(() => _myUid = uid);
    if (mounted) await _showStep3KeyBackup(uid, password, keys);
    if (!mounted) return;
    await _autoConnect();
  }

  Future<String?> _showStep1ChooseUid() async {
    final uidCtrl = TextEditingController();
    String? result;
    bool tosAccepted = false;
    await showDialog(
      context: context, barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF1A1F3C),
          title: Text('ДОБРО ПОЖАЛОВАТЬ', style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 15)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Придумай свой ID из 6 цифр.\nПо нему тебя будут находить в DDChat.',
                  style: TextStyle(color: Colors.white70, fontSize: 13), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextField(
                controller: uidCtrl, keyboardType: TextInputType.number, maxLength: 6,
                style: const TextStyle(color: Colors.white, fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  hintText: '000000', hintStyle: TextStyle(color: Colors.white24),
                  filled: true, fillColor: Color(0xFF0A0E27), counterStyle: TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF00D9FF))),
                ),
              ),
              const SizedBox(height: 16),
              _buildTosCheckbox(ctx, tosAccepted, (v) => setS(() => tosAccepted = v ?? false)),
            ]),
          ),
          actions: [
            ElevatedButton(
              onPressed: !tosAccepted ? null : () {
                if (uidCtrl.text.length == 6) { result = uidCtrl.text; Navigator.pop(ctx); }
                else { _showError('ID должен состоять ровно из 6 цифр'); }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: tosAccepted ? const Color(0xFF00D9FF) : Colors.white12, foregroundColor: Colors.black),
              child: const Text('ДАЛЕЕ →', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<String?> _showStep2CreatePassword() async {
    final pwdCtrl  = TextEditingController();
    final confCtrl = TextEditingController();
    String? result;
    bool obscure1 = true, obscure2 = true;
    await showDialog(
      context: context, barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF1A1F3C),
          title: Text('СОЗДАЙ ПАРОЛЬ', style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 15)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFF0A0E27), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.5))),
              child: const Row(children: [
                Icon(Icons.lock_outline, color: Colors.orange, size: 16), SizedBox(width: 8),
                Expanded(child: Text('Пароль шифрует ключи. Он не сохраняется — запомни его.',
                    style: TextStyle(color: Colors.orange, fontSize: 11))),
              ]),
            ),
            const SizedBox(height: 16),
            TextField(controller: pwdCtrl, obscureText: obscure1, style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: 'Пароль (минимум 8 символов)',
                    labelStyle: const TextStyle(color: Colors.white54), filled: true, fillColor: const Color(0xFF0A0E27),
                    suffixIcon: IconButton(icon: Icon(obscure1 ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
                        onPressed: () => setS(() => obscure1 = !obscure1)))),
            const SizedBox(height: 12),
            TextField(controller: confCtrl, obscureText: obscure2, style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: 'Повтори пароль',
                    labelStyle: const TextStyle(color: Colors.white54), filled: true, fillColor: const Color(0xFF0A0E27),
                    suffixIcon: IconButton(icon: Icon(obscure2 ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
                        onPressed: () => setS(() => obscure2 = !obscure2)))),
          ]),
          actions: [
            ElevatedButton(
              onPressed: () {
                if (pwdCtrl.text.length < 8) { _showError('Минимум 8 символов'); return; }
                if (pwdCtrl.text != confCtrl.text) { _showError('Пароли не совпадают'); return; }
                result = pwdCtrl.text; Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D9FF), foregroundColor: Colors.black),
              child: const Text('ДАЛЕЕ →', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<void> _showStep3KeyBackup(String uid, String password, Map<String, String> encryptedKeys) async {
    bool savedConfirmed = false;
    final backupSalt = _storage.getSetting('user_salt') ?? '';
    final backupJson = jsonEncode({
      'app': 'DDChat', 'version': '1.2', 'uid': uid, 'salt': backupSalt,
      'created_at': DateTime.now().toIso8601String(),
      'note': 'Держи этот файл в тайне. Для восстановления нужен файл + пароль.',
      'x25519_encrypted': encryptedKeys['x25519'], 'ed25519_encrypted': encryptedKeys['ed25519'],
    });
    await showDialog(
      context: context, barrierDismissible: false,
      builder: (c) => StatefulBuilder(
        builder: (ctx, setS) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF1A1F3C),
            title: Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 22), const SizedBox(width: 8),
              Text('СОХРАНИ КЛЮЧИ', style: GoogleFonts.orbitron(color: Colors.red, fontSize: 14)),
            ]),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF1A0A0A), borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.6))),
                  child: const Text(
                    '⚠️  Аккаунт ни к чему не привязан.\n\nБез файла восстановления — аккаунт утрачен навсегда.\n\nСохрани файл прямо сейчас.',
                    style: TextStyle(color: Colors.red, fontSize: 12, height: 1.5),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async { await _shareKeyBackupFile(uid, backupJson); setS(() => savedConfirmed = true); },
                    icon: const Icon(Icons.save_alt, color: Color(0xFF00D9FF)),
                    label: const Text('Сохранить / отправить файл ключей', style: TextStyle(color: Color(0xFF00D9FF))),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF00D9FF)), padding: const EdgeInsets.symmetric(vertical: 12)),
                  ),
                ),
                if (savedConfirmed) ...[
                  const SizedBox(height: 8),
                  const Row(children: [Icon(Icons.check_circle, color: Colors.green, size: 16), SizedBox(width: 6),
                    Text('Файл открыт для сохранения', style: TextStyle(color: Colors.green, fontSize: 12))]),
                ],
                const SizedBox(height: 12),
                const Text('Файл зашифрован твоим паролем. Без пароля он бесполезен.', style: TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
            ),
            actions: [
              if (savedConfirmed)
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  child: const Text('Я СОХРАНИЛ ✓', style: TextStyle(fontWeight: FontWeight.bold)),
                )
              else
                TextButton(onPressed: () => _showError('Сначала сохрани файл ключей!'),
                    child: const Text('Продолжить', style: TextStyle(color: Colors.white30))),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareKeyBackupFile(String uid, String backupJson) async {
    try {
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/ddchat_backup_$uid.json');
      await file.writeAsString(backupJson);
      await Share.shareXFiles([XFile(file.path, mimeType: 'application/json')],
          subject: 'DDChat — файл восстановления аккаунта $uid',
          text: 'Зашифрованный файл ключей DDChat. Храни в безопасном месте.');
    } catch (e) { _showError('Ошибка при создании файла: $e'); }
  }

  void _showRestoreAccountDialog() => _showImportKeysDialog();

  Future<void> _deleteAccount() async {
    await _storage.wipeAllData();
    try { _socket.dispose(); } catch (_) {}
    if (mounted) Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
  }

  Future<void> _showImportKeysDialog() async {
    String? selectedFilePath;
    String? selectedFileName;
    final pwdCtrl     = TextEditingController();
    bool   obscurePwd = true;
    String? errorText;
    bool   isLoading  = false;
    bool   tosAccepted = false;

    await showDialog(
      context: context, barrierDismissible: false,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (dlgCtx, setS) {
          Future<void> pickFile() async {
            final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
            if (result != null && result.files.single.path != null) {
              setS(() { selectedFilePath = result.files.single.path; selectedFileName = result.files.single.name; errorText = null; });
            }
          }
          void resetSelection() => setS(() { selectedFilePath = null; selectedFileName = null; pwdCtrl.clear(); errorText = null; });

          Future<void> authorize() async {
            if (selectedFilePath == null) { setS(() => errorText = 'Выбери файл восстановления'); return; }
            if (pwdCtrl.text.isEmpty)     { setS(() => errorText = 'Введи пароль'); return; }
            setS(() { isLoading = true; errorText = null; });
            try {
              final jsonStr   = await File(selectedFilePath!).readAsString();
              final data      = jsonDecode(jsonStr) as Map<String, dynamic>;
              final importUid = data['uid'] as String?;
              final x25519    = data['x25519_encrypted'] as String?;
              final ed25519   = data['ed25519_encrypted'] as String?;
              if (importUid == null || x25519 == null || ed25519 == null) {
                setS(() { errorText = 'Неверный формат файла'; isLoading = false; }); return;
              }
              final fileSalt = data['salt'] as String?;
              final salt     = fileSalt ?? _storage.getSetting('user_salt') ?? SecureCipher.generateSalt();
              await _cipher.init(pwdCtrl.text, salt, encryptedX25519Key: x25519, encryptedEd25519Key: ed25519);
              setS(() => isLoading = false);
              final currentUid = _myUid;
              final isSameId   = currentUid == importUid;
              Navigator.of(dlgCtx).pop();
              if (!mounted) return;
              final confirmed = await showDialog<bool>(
                context: context, barrierDismissible: false,
                builder: (cCtx) => AlertDialog(
                  backgroundColor: const Color(0xFF1A1F3C),
                  title: Text(isSameId ? 'ПОДТВЕРДИ ВОССТАНОВЛЕНИЕ' : '⚠️ СМЕНА АККАУНТА',
                      style: GoogleFonts.orbitron(color: isSameId ? const Color(0xFF00D9FF) : Colors.orange, fontSize: 13)),
                  content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (!isSameId) ...[
                      Container(padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.orange.withValues(alpha: 0.4))),
                          child: const Text('⚠️ В файле найден другой ID. Текущие ключи будут заменены.',
                              style: TextStyle(color: Colors.orange, fontSize: 12))),
                      const SizedBox(height: 12),
                    ],
                    _idRow('ID в файле', importUid, color: const Color(0xFF00D9FF)),
                    if (currentUid != null && !isSameId) _idRow('Текущий ID', currentUid, color: Colors.white38),
                  ]),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(cCtx, false), child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38))),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: isSameId ? const Color(0xFF00D9FF) : Colors.orange, foregroundColor: Colors.black),
                      onPressed: () => Navigator.pop(cCtx, true),
                      child: Text(isSameId ? 'ВОССТАНОВИТЬ' : 'СМЕНИТЬ АККАУНТ', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              );
              if (confirmed != true || !mounted) return;
              await _idService.saveUID(importUid);
              // SECURITY FIX: пароль не сохраняется
              await _storage.saveSetting('user_salt', salt);
              await _storage.saveSetting('encrypted_x25519_key', x25519);
              await _storage.saveSetting('encrypted_ed25519_key', ed25519);
              await _cacheKeyFingerprint();
              if (mounted) {
                setState(() => _myUid = importUid);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('✅ Аккаунт $importUid восстановлен'),
                    backgroundColor: const Color(0xFF1A4A2E), duration: const Duration(seconds: 3)));
                await _autoConnect();
              }
            } catch (e) {
              setS(() { errorText = 'Неверный пароль или файл повреждён'; isLoading = false; });
            }
          }

          return PopScope(
            canPop: !isLoading,
            child: AlertDialog(
              backgroundColor: const Color(0xFF1A1F3C),
              title: Text('ВОССТАНОВИТЬ АККАУНТ', style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 13)),
              content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Выбери файл ddchat_backup_XXXXXX.json и введи пароль.',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 16),
                  if (selectedFileName == null)
                    SizedBox(width: double.infinity,
                        child: OutlinedButton.icon(onPressed: isLoading ? null : pickFile,
                            icon: const Icon(Icons.folder_open, color: Color(0xFF00D9FF)),
                            label: const Text('Выбрать файл', style: TextStyle(color: Color(0xFF00D9FF))),
                            style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFF00D9FF)))))
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: const Color(0xFF0A2A1A), borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.withValues(alpha: 0.4))),
                      child: Row(children: [
                        const Icon(Icons.check_circle, color: Colors.green, size: 16), const SizedBox(width: 8),
                        Expanded(child: Text(selectedFileName!, style: const TextStyle(color: Colors.white, fontSize: 12), overflow: TextOverflow.ellipsis)),
                        TextButton(onPressed: isLoading ? null : resetSelection,
                            style: TextButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 8)),
                            child: const Text('Сменить', style: TextStyle(color: Colors.orange, fontSize: 11))),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  TextField(controller: pwdCtrl, obscureText: obscurePwd, enabled: !isLoading,
                      style: const TextStyle(color: Colors.white),
                      onChanged: (_) { if (errorText != null) setS(() => errorText = null); },
                      decoration: InputDecoration(labelText: 'Пароль', labelStyle: const TextStyle(color: Colors.white54),
                          filled: true, fillColor: const Color(0xFF0A0E27),
                          suffixIcon: IconButton(icon: Icon(obscurePwd ? Icons.visibility_off : Icons.visibility, color: Colors.white38, size: 20),
                              onPressed: () => setS(() => obscurePwd = !obscurePwd)))),
                  const SizedBox(height: 8),
                  _buildTosCheckbox(dlgCtx, tosAccepted, isLoading ? null : (v) => setS(() => tosAccepted = v ?? false)),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Container(padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.red.withValues(alpha: 0.4))),
                        child: Row(children: [
                          const Icon(Icons.error_outline, color: Colors.red, size: 16), const SizedBox(width: 8),
                          Expanded(child: Text(errorText!, style: const TextStyle(color: Colors.red, fontSize: 12))),
                        ])),
                  ],
                  if (isLoading) ...[const SizedBox(height: 12), const Center(child: CircularProgressIndicator(color: Color(0xFF00D9FF)))],
                ]),
              ),
              actions: [
                TextButton(onPressed: isLoading ? null : () { pwdCtrl.clear(); Navigator.of(dlgCtx).pop(); },
                    child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38))),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: (selectedFileName != null && tosAccepted) ? const Color(0xFF00D9FF) : Colors.white12,
                      foregroundColor: Colors.black),
                  onPressed: (selectedFileName != null && tosAccepted && !isLoading) ? authorize : null,
                  child: const Text('АВТОРИЗОВАТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _idRow(String label, String uid, {Color color = Colors.white}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text('$label: ', style: const TextStyle(color: Colors.white54, fontSize: 12)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.4))),
          child: Text(uid, style: TextStyle(color: color, fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 3)),
        ),
      ]),
    );
  }

  Future<void> _showPasswordSetupDialog() async {
    final pwdCtrl  = TextEditingController();
    final confCtrl = TextEditingController();
    return showDialog(
      context: context, barrierDismissible: false,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('СОЗДАЙ ПАРОЛЬ', style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF))),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('⚠️ Пароль не сохраняется — запомни его!', style: TextStyle(color: Colors.orange, fontSize: 11)),
          const SizedBox(height: 16),
          TextField(controller: pwdCtrl, obscureText: true, style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Пароль (минимум 8 символов)', filled: true, fillColor: Color(0xFF0A0E27))),
          const SizedBox(height: 12),
          TextField(controller: confCtrl, obscureText: true, style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Повтори пароль', filled: true, fillColor: Color(0xFF0A0E27))),
        ]),
        actions: [
          ElevatedButton(
            onPressed: () async {
              if (pwdCtrl.text.length < 8 || pwdCtrl.text != confCtrl.text) {
                _showError('Пароли должны совпадать (минимум 8 символов)'); return;
              }
              final salt = SecureCipher.generateSalt();
              await _cipher.init(pwdCtrl.text, salt);
              final keys = await _cipher.exportBothKeys(pwdCtrl.text);
              // SECURITY FIX: не сохраняем пароль
              await _storage.saveSetting('user_salt', salt);
              await _storage.saveSetting('encrypted_x25519_key', keys['x25519']!);
              await _storage.saveSetting('encrypted_ed25519_key', keys['ed25519']!);
              Navigator.pop(context);
              _autoConnect();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D9FF), foregroundColor: Colors.black),
            child: const Text('СОЗДАТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Add / Create dialogs
  // ─────────────────────────────────────────────────────────────────────────

  void _addContact() {
    final targetC = TextEditingController();
    final nameC   = TextEditingController();
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Добавить контакт', style: GoogleFonts.orbitron()),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: targetC, keyboardType: TextInputType.number, maxLength: 6,
              style: const TextStyle(color: Colors.white), textAlign: TextAlign.center,
              decoration: const InputDecoration(hintText: '000000', filled: true, fillColor: Color(0xFF0A0E27))),
          const SizedBox(height: 12),
          TextField(controller: nameC, style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Имя (необязательно)', filled: true, fillColor: Color(0xFF0A0E27))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ОТМЕНА')),
          ElevatedButton(
            onPressed: () async {
              if (targetC.text.length == 6 && targetC.text != _myUid) {
                _socket.getProfile(targetC.text);
                await _storage.addContact(targetC.text,
                    displayName: nameC.text.trim().isNotEmpty ? nameC.text.trim() : null);
                Navigator.pop(context);
                setState(() => _chats = _storage.getContactsSortedByActivity());
              } else { _showError('Неверный ID'); }
            },
            child: const Text('ДОБАВИТЬ')),
        ],
      ),
    );
  }

  void _createGroupDialog() {
    final nameCtrl   = TextEditingController();
    final memberCtrl = TextEditingController();
    final contacts   = _storage.getContacts().where((c) => !_storage.isGroup(c)).toList();
    final selected   = <String>{};
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF1A1F3C),
          title: Text('НОВАЯ ГРУППА', style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 14)),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(controller: nameCtrl, style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'Название группы',
                        labelStyle: TextStyle(color: Colors.white54), filled: true, fillColor: Color(0xFF0A0E27))),
                const SizedBox(height: 16),
                if (contacts.isNotEmpty) ...[
                  const Text('Выбери участников:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 8),
                  ...contacts.map((uid) {
                    final name = _storage.getContactDisplayName(uid);
                    return CheckboxListTile(dense: true, value: selected.contains(uid),
                        onChanged: (v) => setS(() { v! ? selected.add(uid) : selected.remove(uid); }),
                        title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                        subtitle: Text(uid, style: const TextStyle(color: Colors.white38, fontSize: 11)),
                        activeColor: const Color(0xFF00D9FF), checkColor: Colors.black,
                        controlAffinity: ListTileControlAffinity.leading);
                  }),
                  const Divider(color: Colors.white12),
                ],
                Row(children: [
                  Expanded(child: TextField(controller: memberCtrl, keyboardType: TextInputType.number, maxLength: 6,
                      style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 4), textAlign: TextAlign.center,
                      decoration: const InputDecoration(hintText: 'Добавить по ID', hintStyle: TextStyle(color: Colors.white24, fontSize: 13, letterSpacing: 0),
                          filled: true, fillColor: Color(0xFF0A0E27), counterStyle: TextStyle(color: Colors.white24)))),
                  const SizedBox(width: 8),
                  IconButton(icon: const Icon(Icons.add_circle, color: Color(0xFF00D9FF)),
                      onPressed: () {
                        final uid = memberCtrl.text.trim();
                        if (uid.length == 6 && uid != _myUid) { setS(() => selected.add(uid)); memberCtrl.clear(); }
                      }),
                ]),
                if (selected.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, children: selected.map((uid) => Chip(
                      label: Text(_storage.getContactDisplayName(uid), style: const TextStyle(color: Colors.white, fontSize: 11)),
                      backgroundColor: const Color(0xFF0A2A3A), deleteIconColor: Colors.white38,
                      onDeleted: () => setS(() => selected.remove(uid)))).toList()),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38))),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) { _showError('Введи название группы'); return; }
                if (selected.isEmpty) { _showError('Выбери хотя бы одного участника'); return; }
                Navigator.pop(ctx);
                await _createGroup(name, selected.toList());
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D9FF), foregroundColor: Colors.black),
              child: const Text('СОЗДАТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createGroup(String name, List<String> memberUids) async {
    if (_myUid == null) return;
    final groupId = 'g_${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';
    final members = [_myUid!, ...memberUids];
    final groupKeyBytes = _cipher.generateGroupKey();
    _cipher.setGroupKey(groupId, groupKeyBytes);
    final needKeys = <String>[];
    for (final uid in memberUids) {
      if (!_cipher.hasSharedSecret(uid)) {
        await _cipher.tryLoadCachedKeys(uid, _storage);
        if (!_cipher.hasSharedSecret(uid)) needKeys.add(uid);
      }
    }
    if (needKeys.isNotEmpty) {
      for (final uid in needKeys) _socket.requestPublicKey(uid);
      await Future.delayed(const Duration(milliseconds: 2500));
    }
    final encryptedKeys = <String, String>{};
    for (final uid in memberUids) {
      if (!_cipher.hasSharedSecret(uid)) await _cipher.tryLoadCachedKeys(uid, _storage);
      if (_cipher.hasSharedSecret(uid)) {
        try { encryptedKeys[uid] = await _cipher.encryptGroupKeyFor(uid, groupKeyBytes); }
        catch (e) { debugPrint('Could not encrypt group key for $uid: $e'); }
      }
    }
    await _storage.saveGroup(groupId: groupId, groupName: name, members: members, creatorUid: _myUid!);
    _socket.send({'type': 'create_group', 'group_id': groupId, 'group_name': name, 'members': members});
    if (encryptedKeys.isNotEmpty) _socket.distributeGroupKeys(groupId, encryptedKeys);
    if (mounted) {
      setState(() => _chats = _storage.getContactsSortedByActivity());
      Navigator.push(context, MaterialPageRoute(
          builder: (_) => ChatScreen(myUid: _myUid!, targetUid: groupId, cipher: _cipher)))
          .then((_) { if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity()); });
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FAB — контекстное действие зависит от таба
  // ─────────────────────────────────────────────────────────────────────────

  void _onFabTapped() {
    switch (_tabController.index) {
      case _Tab.contacts: _addContact(); break;
      case _Tab.groups:   _createGroupDialog(); break;
      case _Tab.channels: _showSuccess('Каналы — скоро'); break;
      default:            _showAddMenu(); break;
    }
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context, backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(margin: const EdgeInsets.only(top: 10, bottom: 8), width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          ListTile(leading: const Icon(Icons.person_add, color: Colors.cyan),
              title: const Text('Добавить контакт', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _addContact(); }),
          ListTile(leading: const Icon(Icons.group_add, color: Colors.cyan),
              title: const Text('Создать группу', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _createGroupDialog(); }),
          ListTile(leading: const Icon(Icons.qr_code_scanner, color: Colors.cyan),
              title: const Text('Сканировать QR', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _openQrScanner(); }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Contact options
  // ─────────────────────────────────────────────────────────────────────────

  void _showContactOptions(String uid) {
    final name     = _storage.getContactDisplayName(uid);
    final isPinned = _storage.isContactPinned(uid);
    final isMuted  = _storage.isContactMuted(uid);
    showModalBottomSheet(
      context: context, backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(children: [
              _buildSquircleAvatar(uid, radius: 20),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                Text('ID: $uid', style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ]),
            ]),
          ),
          const Divider(color: Colors.white12, height: 1),
          ListTile(
            leading: Icon(isPinned ? Icons.push_pin : Icons.push_pin_outlined, color: isPinned ? Colors.amber : Colors.white70),
            title: Text(isPinned ? 'Открепить' : 'Закрепить сверху', style: TextStyle(color: isPinned ? Colors.amber : Colors.white)),
            onTap: () async {
              Navigator.pop(context);
              await _storage.setContactPinned(uid, !isPinned);
              setState(() => _chats = _storage.getContactsSortedByActivity());
              _showSuccess(isPinned ? 'Откреплено' : '📌 $name закреплен');
            },
          ),
          ListTile(leading: const Icon(Icons.edit_outlined, color: Colors.white70),
              title: const Text('Переименовать', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _showRenameDialog(uid, name); }),
          ListTile(
            leading: Icon(isMuted ? Icons.volume_up_outlined : Icons.volume_off_outlined, color: isMuted ? Colors.white70 : Colors.orange),
            title: Text(isMuted ? 'Включить звук' : 'Без звука', style: TextStyle(color: isMuted ? Colors.white : Colors.orange)),
            onTap: () async {
              Navigator.pop(context);
              await _storage.setContactMuted(uid, !isMuted);
              setState(() {});
              _showSuccess(isMuted ? 'Звук включен для $name' : '🔇 $name заглушен');
            },
          ),
          ListTile(leading: const Icon(Icons.copy_outlined, color: Colors.white70),
              title: const Text('Скопировать ID', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); Clipboard.setData(ClipboardData(text: uid)); _showSuccess('ID скопирован: $uid'); }),
          ListTile(leading: const Icon(Icons.cleaning_services_outlined, color: Colors.orange),
              title: const Text('Очистить историю', style: TextStyle(color: Colors.orange)),
              onTap: () { Navigator.pop(context); _confirmClearHistory(uid, name); }),
          ListTile(leading: const Icon(Icons.person_remove_outlined, color: Colors.red),
              title: Text('Удалить "$name"', style: const TextStyle(color: Colors.red)),
              onTap: () { Navigator.pop(context); _confirmDeleteContact(uid, name); }),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _showRenameDialog(String uid, String currentName) {
    final ctrl = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Переименовать контакт', style: TextStyle(color: Colors.white)),
        content: TextField(controller: ctrl, autofocus: true, style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(hintText: 'Новое имя...', hintStyle: TextStyle(color: Colors.white38),
                filled: true, fillColor: Color(0xFF0A0E27), border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ОТМЕНА')),
          ElevatedButton(onPressed: () async {
            final newName = ctrl.text.trim();
            if (newName.isEmpty) return;
            await _storage.setContactDisplayName(uid, newName);
            Navigator.pop(context);
            setState(() => _chats = _storage.getContactsSortedByActivity());
            _showSuccess('Переименован в "$newName"');
          }, child: const Text('СОХРАНИТЬ')),
        ],
      ),
    );
  }

  void _confirmClearHistory(String uid, String name) {
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1A1F3C),
      title: const Text('Очистить историю?', style: TextStyle(color: Colors.white)),
      content: Text('Все сообщения с "$name" будут удалены с устройства.', style: const TextStyle(color: Colors.white70)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ОТМЕНА')),
        TextButton(onPressed: () async {
          Navigator.pop(context);
          await _storage.clearChatHistory(uid);
          setState(() => _chats = _storage.getContactsSortedByActivity());
          _showSuccess('История очищена');
        }, child: const Text('ОЧИСТИТЬ', style: TextStyle(color: Colors.orange))),
      ],
    ));
  }

  void _confirmDeleteContact(String uid, String name) {
    showDialog(context: context, builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF1A1F3C),
      title: const Text('Удалить контакт?', style: TextStyle(color: Colors.white)),
      content: Text('Удалить "$name" и всю историю переписки?', style: const TextStyle(color: Colors.white70)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ОТМЕНА')),
        TextButton(onPressed: () {
          Navigator.pop(context);
          _storage.removeContact(uid);
          setState(() => _chats = _storage.getContactsSortedByActivity());
        }, child: const Text('УДАЛИТЬ', style: TextStyle(color: Colors.red))),
      ],
    ));
  }

  void _performSearch(String query) {
    setState(() { _searchResults = query.isEmpty ? [] : _storage.searchMessages(query, limit: 50); });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Widget helpers
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildConnectionIndicator() {
    final color = _connectionStatus == 'В СЕТИ' ? Colors.green
        : (_connectionStatus == 'ПОДКЛЮЧЕНИЕ...' ? Colors.orange : Colors.red);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.circle, color: color, size: 8), const SizedBox(width: 4),
      Text(_connectionStatus, style: TextStyle(fontSize: 10, color: color)),
    ]);
  }

  // IMPROVEMENT: Squircle-аватар (скруглённый квадрат вместо круга)
  Widget _buildSquircleAvatar(String uid, {double radius = 24}) {
    final isGroup   = _storage.isGroup(uid);
    final isChannel = _storage.isChannel(uid);
    final name      = isGroup ? _storage.getGroupName(uid) : _storage.getContactDisplayName(uid);
    final avatar    = _storage.getContactAvatar(uid);
    final hasAvatar = !isGroup && !isChannel && avatar != null && avatar.isNotEmpty && avatar != 'null';
    final size      = radius * 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius * 0.44),
      child: Container(
        width: size, height: size,
        color: isGroup ? const Color(0xFF0A2A3A) : isChannel ? const Color(0xFF1A0A3A) : const Color(0xFF1A1F3C),
        child: hasAvatar
            ? Image.network('https://deepdrift-backend.onrender.com/download/$avatar',
                width: size, height: size, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _avatarFallback(name, isGroup, isChannel, radius))
            : _avatarFallback(name, isGroup, isChannel, radius),
      ),
    );
  }

  Widget _avatarFallback(String name, bool isGroup, bool isChannel, double radius) {
    if (isChannel) return Icon(Icons.campaign, color: const Color(0xFFB39DDB), size: radius);
    if (isGroup)   return Icon(Icons.group, color: const Color(0xFF00D9FF), size: radius);
    return Center(child: Text(
      name.isNotEmpty ? name[0].toUpperCase() : '?',
      style: TextStyle(color: Colors.cyan, fontSize: radius * 0.7, fontWeight: FontWeight.bold),
    ));
  }

  // Бейдж с числом непрочитанных над иконкой таба
  Widget _buildTabBadge(int tabIndex, {required Widget child}) {
    final unread = _unreadForTab(tabIndex);
    if (unread == 0) return child;
    return Stack(clipBehavior: Clip.none, children: [
      child,
      Positioned(
        top: -6, right: -8,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: const Color(0xFF00D9FF), borderRadius: BorderRadius.circular(8)),
          child: Text(unread > 99 ? '99+' : '$unread',
              style: const TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold)),
        ),
      ),
    ]);
  }

  Tab _buildTab(IconData icon, String label, int tabIndex) {
    return Tab(
      child: _buildTabBadge(tabIndex, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20), Text(label),
      ])),
    );
  }

  Widget _buildChatList(List<String> chats) {
    if (!_isReady) return const Center(child: CircularProgressIndicator(color: Colors.cyan));
    if (chats.isEmpty) return Center(child: Text('Пусто', style: GoogleFonts.orbitron(color: Colors.white38)));

    return ListView.builder(
      itemCount: chats.length,
      itemBuilder: (c, i) {
        final uid       = chats[i];
        final isGroup   = _storage.isGroup(uid);
        final isChannel = _storage.isChannel(uid);
        final name      = isGroup ? _storage.getGroupName(uid) : _storage.getContactDisplayName(uid);
        final meta      = _storage.getChatMetadata(uid);
        final unread    = meta['unreadCount'] as int? ?? 0;
        final isOnline  = _storage.isContactOnline(uid);
        final isPinned  = _storage.isContactPinned(uid);
        final isMuted   = _storage.isContactMuted(uid);
        final totalMsgs = meta['totalMessages'] as int? ?? 0;
        final lastText  = meta['lastMessageText'] as String? ?? 'Нет сообщений';
        final nearLimit = totalMsgs >= 900;

        return ListTile(
          leading: Stack(children: [
            _buildSquircleAvatar(uid),
            if (!isGroup && !isChannel && isOnline)
              Positioned(right: 0, bottom: 0, child: Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF0A0E27), width: 2)))),
            if (unread > 0)
              Positioned(right: 0, top: 0, child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(color: Colors.cyan, shape: BoxShape.circle),
                  child: Text('$unread', style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)))),
          ]),
          title: Row(children: [
            if (isPinned) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.push_pin, size: 12, color: Colors.amber)),
            if (isMuted)  const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.volume_off, size: 12, color: Colors.white38)),
            Expanded(child: Text(name, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal))),
          ]),
          subtitle: Text(
            nearLimit ? '⚠️ Лимит ($totalMsgs/1000) — $lastText' : lastText,
            style: TextStyle(
                color: nearLimit ? Colors.orange.withValues(alpha: 0.8) : (unread > 0 ? Colors.white54 : Colors.white24),
                fontSize: 12),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            Navigator.push(context, MaterialPageRoute(
                builder: (_) => ChatScreen(myUid: _myUid!, targetUid: uid, cipher: _cipher)))
                .then((_) { if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity()); });
          },
          onLongPress: () => _showContactOptions(uid),
        );
      },
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) return const Center(child: Icon(Icons.search_off, size: 64, color: Colors.white12));
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (c, i) {
        final r   = _searchResults[i];
        final uid = r['chatWith'] as String;
        return ListTile(
          leading: _buildSquircleAvatar(uid),
          title: Text(_storage.getContactDisplayName(uid)),
          subtitle: Text(r['text'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          onTap: () {
            setState(() => _isSearching = false);
            Navigator.push(context, MaterialPageRoute(
                builder: (_) => ChatScreen(myUid: _myUid!, targetUid: uid, cipher: _cipher)))
                .then((_) { if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity()); });
          },
        );
      },
    );
  }

  IconData get _fabIcon {
    switch (_tabController.index) {
      case _Tab.contacts: return Icons.person_add;
      case _Tab.groups:   return Icons.group_add;
      default:            return Icons.add;
    }
  }

  String get _fabTooltip {
    switch (_tabController.index) {
      case _Tab.contacts: return 'Добавить контакт';
      case _Tab.groups:   return 'Создать группу';
      default:            return 'Новый чат';
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final totalUnread = _storage.getTotalUnreadCount();
    final myProfile   = _storage.getMyProfile();
    final avatarUrl   = myProfile['avatarUrl'];
    final hasMyAvatar = avatarUrl != null && avatarUrl.isNotEmpty && avatarUrl != 'null';

    return PopScope(
      canPop: !_isSearching,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSearching) setState(() { _isSearching = false; _searchController.clear(); });
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E27),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1F3C),
          elevation: 0,
          title: _isSearching
              ? TextField(controller: _searchController, autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(hintText: 'Поиск...', border: InputBorder.none),
                  onChanged: _performSearch)
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('DDChat', style: GoogleFonts.orbitron(fontSize: 18)),
                    if (totalUnread > 0)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: Colors.cyan, borderRadius: BorderRadius.circular(10)),
                        child: Text('$totalUnread', style: const TextStyle(color: Colors.black, fontSize: 10)),
                      ),
                  ]),
                  Row(children: [
                    Text('ID: ${_myUid ?? '...'}', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                    const SizedBox(width: 8),
                    _buildConnectionIndicator(),
                  ]),
                ]),
          actions: [
            if (_isSearching)
              IconButton(icon: const Icon(Icons.close),
                  onPressed: () => setState(() { _isSearching = false; _searchController.clear(); }))
            else ...[
              IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => _isSearching = true)),
              IconButton(icon: const Icon(Icons.settings_outlined, color: Colors.white70),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => SettingsScreen(storage: _storage, cipher: _cipher, myUid: _myUid ?? '',
                          onSwitchAccount: _showRestoreAccountDialog, onDeleteAccount: _deleteAccount)))),
              GestureDetector(
                onTap: _showMyProfileDialog,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, left: 4),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(width: 32, height: 32, color: Colors.cyan.withValues(alpha: 0.2),
                        child: hasMyAvatar
                            ? Image.network('https://deepdrift-backend.onrender.com/download/$avatarUrl', fit: BoxFit.cover)
                            : const Icon(Icons.person, size: 20, color: Colors.cyan)),
                  ),
                ),
              ),
            ],
          ],
          // ── TabBar — 4 вкладки ────────────────────────────────────────────
          bottom: _isSearching ? null : PreferredSize(
            preferredSize: const Size.fromHeight(52),
            child: Container(
              color: const Color(0xFF1A1F3C),
              child: TabBar(
                controller: _tabController,
                indicatorColor: const Color(0xFF00D9FF),
                indicatorWeight: 3,
                indicatorSize: TabBarIndicatorSize.tab,
                labelColor: const Color(0xFF00D9FF),
                unselectedLabelColor: Colors.white38,
                labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                unselectedLabelStyle: const TextStyle(fontSize: 10),
                tabs: [
                  _buildTab(Icons.star_outline,     'Избранное', _Tab.favorites),
                  _buildTab(Icons.person_outline,   'Контакты',  _Tab.contacts),
                  _buildTab(Icons.group_outlined,   'Группы',    _Tab.groups),
                  _buildTab(Icons.campaign_outlined, 'Каналы',   _Tab.channels),
                ],
              ),
            ),
          ),
        ),
        body: _isSearching
            ? _buildSearchResults()
            : TabBarView(
                controller: _tabController,
                children: [
                  _buildChatList(_filteredChats(_Tab.favorites)),
                  _buildChatList(_filteredChats(_Tab.contacts)),
                  _buildChatList(_filteredChats(_Tab.groups)),
                  _buildChatList(_filteredChats(_Tab.channels)),
                ],
              ),
        floatingActionButton: _isSearching ? null : FloatingActionButton(
          onPressed: _onFabTapped,
          backgroundColor: const Color(0xFF00D9FF),
          tooltip: _fabTooltip,
          child: Icon(_fabIcon, color: Colors.black, size: 26),
        ),
      ),
    );
  }
}

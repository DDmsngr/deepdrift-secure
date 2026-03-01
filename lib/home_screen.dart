import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {

  String?      _myUid;
  List<String> _chats = [];
  bool         _isConnected     = false;
  bool         _isReady         = false;
  String       _connectionStatus = 'ОФФЛАЙН';
  StreamSubscription? _socketSub;

  final _idService   = IdentityService();
  final _storage     = StorageService();  // singleton
  final _socket      = SocketService();   // singleton
  late  SecureCipher _cipher;             // получаем из CipherProvider
  final _imagePicker = ImagePicker();

  final _idController     = TextEditingController();
  final _serverController = TextEditingController(
    text: 'wss://deepdrift-backend.onrender.com/ws',
  );

  bool   _isSearching = false;
  final  _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];


  Timer? _statusCheckTimer;

  // ──────────────────────────────────────────────────────────────────────────
  // Lifecycle
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Получаем единственный экземпляр SecureCipher из дерева провайдеров.
    // didChangeDependencies вызывается до build, поэтому _cipher всегда готов.
    _cipher = context.read<CipherProvider>().cipher;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 🟡-2 FIX: регистрируем callback навигации по нотификациям.
    // NotificationService вызовет _openChatWithUid() при тапе на уведомление.
    // Если при запуске уже есть _pendingUid (cold start), callback выполнится
    // немедленно через addPostFrameCallback — после завершения initState.
    NotificationService().setOpenChatCallback(_openChatWithUid);

    _setup();
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_isConnected) _socket.checkStatuses(_chats);
    });
  }

  @override
  void dispose() {
    // 🟡-2 FIX: снимаем callback чтобы не держать ссылку на мёртвый State
    NotificationService().clearOpenChatCallback();

    WidgetsBinding.instance.removeObserver(this);
    _socketSub?.cancel();
    _statusCheckTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_socket.isConnected) _socket.forceReconnect();
      _socket.checkStatuses(_chats);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // 🟡-2 FIX: Навигация к чату по uid (из нотификации)
  // ──────────────────────────────────────────────────────────────────────────

  /// Открывает чат с [fromUid]. Вызывается NotificationService при тапе
  /// на push-уведомление во всех трёх сценариях: foreground, background, cold start.
  ///
  /// Если пользователь ещё не авторизован (_myUid == null) или приложение
  /// ещё не готово (_isReady == false) — uid добавляется как контакт и чат
  /// откроется когда _setup() завершится.
  void _openChatWithUid(String fromUid) {
    if (!mounted) return;

    // Добавляем контакт если ещё нет (может прийти уведомление от нового пользователя)
    if (!_chats.contains(fromUid)) {
      _socket.getProfile(fromUid);
      _storage.addContact(fromUid, displayName: fromUid);
      if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
    }

    // Если приложение ещё инициализируется — ждём следующего кадра
    if (!_isReady || _myUid == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openChatWithUid(fromUid));
      return;
    }

    debugPrint('📲 Opening chat with $fromUid (from notification)');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          myUid:     _myUid!,
          targetUid: fromUid,
          cipher:    _cipher,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Setup & Connection
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _setup() async {
    try {
      await _storage.init();
      final uid = await _idService.getStoredUID();
      if (uid == null) {
        if (mounted) _showRegistrationDialog();
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

      final savedPassword   = _storage.getSetting('user_password');
      final savedSalt       = _storage.getSetting('user_salt');
      final authToken       = _storage.getSetting('auth_token');
      final savedX25519Key  = _storage.getSetting('encrypted_x25519_key');
      final savedEd25519Key = _storage.getSetting('encrypted_ed25519_key');

      if (savedPassword == null || savedSalt == null) {
        if (mounted) await _showPasswordSetupDialog();
        return;
      }

      await _cipher.init(
        savedPassword,
        savedSalt,
        encryptedX25519Key:  savedX25519Key,
        encryptedEd25519Key: savedEd25519Key,
      );

      if (savedX25519Key == null || savedEd25519Key == null) {
        final exportedKeys = await _cipher.exportBothKeys(savedPassword);
        await _storage.saveSetting('encrypted_x25519_key', exportedKeys['x25519']!);
        await _storage.saveSetting('encrypted_ed25519_key', exportedKeys['ed25519']!);
      }

      _socket.init(_cipher);
      _socket.connect(_serverController.text, _myUid!, authToken: authToken);

      _socketSub = _socket.messages.listen((data) {
        if (!mounted) return;
        final type = data['type'];

        if (type == 'uid_assigned') {
          setState(() { _isConnected = true; _connectionStatus = 'В СЕТИ'; });
          _registerPublicKeysOnServer();
          _socket.checkStatuses(_storage.getContacts());
        }
        if (type == 'connection_status') {
          setState(() {
            _isConnected     = data['connected'] as bool? ?? false;
            _connectionStatus = _isConnected ? 'В СЕТИ' : 'ОФФЛАЙН';
          });
        }
        if (type == 'connection_failed') {
          setState(() => _connectionStatus = 'ОШИБКА СЕТИ');
        }
        if (type == 'user_status') {
          _storage.setContactStatus(
            data['uid'] as String,
            data['status'] == 'online',
            data['last_seen'] as int?,
          );
          if (mounted) setState(() {});
        }
        if (type == 'message') _handleIncomingMessageQuietly(data);
        if (type == 'message' || type == 'status_update' ||
            type == 'message_deleted' || type == 'user_status') {
          setState(() => _chats = _storage.getContactsSortedByActivity());
        }
      });

      setState(() {
        _isReady = true;
        _chats   = _storage.getContactsSortedByActivity();
      });
    } catch (e) {
      setState(() { _connectionStatus = 'ОШИБКА'; _isReady = true; });
    }
  }

  Future<void> _registerPublicKeysOnServer() async {
    try {
      final x25519Key  = await _cipher.getMyPublicKey();
      final ed25519Key = await _cipher.getMySigningKey();
      _socket.registerPublicKeys(x25519Key, ed25519Key);
    } catch (e) {
      debugPrint('Failed to register public keys: $e'); // 🟢-3 FIX
    }
  }

  Future<void> _handleIncomingMessageQuietly(Map<String, dynamic> data) async {
    final senderUid = data['from_uid'] as String?;
    final msgId     = data['id']?.toString();
    if (senderUid == null || msgId == null) return;
    if (_storage.hasMessage(senderUid, msgId)) return;
    try {
      final decrypted = await _cipher.decryptText(
        data['encrypted_text'] as String,
        fromUid: senderUid,
      );
      final msg = {
        'id':       msgId,
        'text':     decrypted,
        'isMe':     false,
        'time':     data['time'] ?? DateTime.now().millisecondsSinceEpoch,
        'from':     senderUid,
        'to':       _myUid,
        'status':   'delivered',
        'type':     data['messageType'] ?? 'text',
        'fileName': data['fileName'],
        'fileSize': data['fileSize'],
        // Подпись не верифицируем в тихом режиме — сделает ChatScreen при открытии
        'signatureStatus': SignatureStatus.unknown.index,
      };
      await _storage.saveMessage(senderUid, msg);
      _socket.sendReadReceipt(senderUid, msgId);
      if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
    } catch (e) {
      debugPrint('Quiet save error: $e'); // 🟢-3 FIX
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Хелперы
  // ──────────────────────────────────────────────────────────────────────────

  // ──────────────────────────────────────────────────────────────────────────
  // QR-сканер: считывает UID контакта и сразу открывает с ним чат
  // ──────────────────────────────────────────────────────────────────────────
  void _openQrScanner() {
    final MobileScannerController scannerCtrl = MobileScannerController();
    bool _handled = false; // Флаг: не обрабатываем второй скан после pop

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.qr_code_scanner, color: Colors.cyan),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Наведи камеру на QR-код контакта',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () {
                      scannerCtrl.dispose();
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: MobileScanner(
                  controller: scannerCtrl,
                  onDetect: (capture) {
                    if (_handled) return;
                    final barcode = capture.barcodes.firstOrNull;
                    final rawValue = barcode?.rawValue;
                    if (rawValue == null || rawValue.isEmpty) return;

                    // UID — строка без пробелов. Отфильтруем случайные URL/мусор.
                    final uid = rawValue.trim();
                    if (uid.contains(' ') || uid.length < 4) return;

                    _handled = true;
                    scannerCtrl.dispose();
                    Navigator.pop(ctx); // Закрываем сканер

                    // Добавляем контакт и открываем чат
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: const Color(0xFF1A4A2E)),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Диалоги
  // ──────────────────────────────────────────────────────────────────────────

  void _showMyProfileDialog() {
    final profile      = _storage.getMyProfile();
    final nameCtrl     = TextEditingController(text: profile['nickname']);
    String? currentAvatar = profile['avatarUrl'];

    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setDialogState) {
          final hasAvatar = currentAvatar != null &&
              currentAvatar!.isNotEmpty && currentAvatar != 'null';
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1F3C),
            title: Text('Мой профиль', style: GoogleFonts.orbitron()),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () async {
                      final img = await _imagePicker.pickImage(
                        source: ImageSource.gallery, maxWidth: 512, maxHeight: 512,
                      );
                      if (img != null) {
                        final fileId = await _socket.uploadFile(File(img.path));
                        if (fileId != null) {
                          setDialogState(() => currentAvatar = fileId);
                        } else {
                          _showError('Ошибка загрузки аватара');
                        }
                      }
                    },
                    child: CircleAvatar(
                      radius: 40,
                      backgroundColor: const Color(0xFF0A0E27),
                      backgroundImage: hasAvatar
                          ? NetworkImage('https://deepdrift-backend.onrender.com/download/$currentAvatar')
                          : null,
                      child: !hasAvatar
                          ? const Icon(Icons.add_a_photo, size: 30, color: Colors.cyan)
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Твой ID: $_myUid',
                    style: const TextStyle(
                      color: Colors.cyan, fontSize: 18,
                      fontWeight: FontWeight.bold, letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // QR-код для добавления контакта
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: _myUid ?? '000000',
                      version: QrVersions.auto,
                      size: 140.0,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Покажи этот QR-код другу\nдля быстрого добавления',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  const SizedBox(height: 16),

                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: 'Твое имя (никнейм)',
                      filled: true, fillColor: Color(0xFF0A0E27),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ОТМЕНА'),
              ),
              ElevatedButton(
                onPressed: () async {
                  await _storage.saveMyProfile(
                    nickname: nameCtrl.text.trim(),
                    avatarUrl: currentAvatar,
                  );
                  _socket.updateProfile(nameCtrl.text.trim(), currentAvatar);
                  Navigator.pop(context);
                  setState(() {});
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyan,
                  foregroundColor: Colors.black,
                ),
                child: const Text('СОХРАНИТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showPasswordSetupDialog() async {
    final pwdCtrl  = TextEditingController();
    final confCtrl = TextEditingController();
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('ЗАЩИТА ЧАТОВ',
            style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '⚠️ Обязательно запомни его! Восстановить будет невозможно.',
              style: TextStyle(color: Colors.orange, fontSize: 11),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pwdCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Придумай пароль',
                filled: true, fillColor: Color(0xFF0A0E27),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confCtrl,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Повтори пароль',
                filled: true, fillColor: Color(0xFF0A0E27),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () async {
              if (pwdCtrl.text.length < 8 || pwdCtrl.text != confCtrl.text) {
                _showError('Пароли должны совпадать (минимум 8 символов)');
                return;
              }
              final salt = SecureCipher.generateSalt();
              await _cipher.init(pwdCtrl.text, salt);
              final keys = await _cipher.exportBothKeys(pwdCtrl.text);
              await _storage.saveSetting('user_password', pwdCtrl.text);
              await _storage.saveSetting('user_salt', salt);
              await _storage.saveSetting('encrypted_x25519_key', keys['x25519']!);
              await _storage.saveSetting('encrypted_ed25519_key', keys['ed25519']!);
              Navigator.pop(context);
              _autoConnect();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan, foregroundColor: Colors.black,
            ),
            child: const Text('СОЗДАТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showRegistrationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('ДОБРО ПОЖАЛОВАТЬ В DDCHAT',
            style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Придумай себе номер из 6 цифр.\nПо нему тебя будут находить друзья!',
              style: TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _idController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(
                color: Colors.white, fontSize: 24,
                letterSpacing: 6, fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                hintText: '000000',
                filled: true, fillColor: Color(0xFF0A0E27),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () async {
              if (_idController.text.length == 6) {
                await _idService.saveUID(_idController.text);
                Navigator.pop(context);
                _setup();
              } else {
                _showError('Номер должен состоять ровно из 6 цифр');
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyan, foregroundColor: Colors.black,
            ),
            child: const Text('СОЗДАТЬ', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _addContact() {
    final targetC = TextEditingController();
    final nameC   = TextEditingController();
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Добавить контакт', style: GoogleFonts.orbitron()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: targetC,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                hintText: '000000',
                filled: true, fillColor: Color(0xFF0A0E27),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameC,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Имя (необязательно)',
                filled: true, fillColor: Color(0xFF0A0E27),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ОТМЕНА'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (targetC.text.length == 6 && targetC.text != _myUid) {
                _socket.getProfile(targetC.text);
                await _storage.addContact(
                  targetC.text,
                  displayName: nameC.text.trim().isNotEmpty ? nameC.text.trim() : null,
                );
                Navigator.pop(context);
                setState(() => _chats = _storage.getContactsSortedByActivity());
              } else {
                _showError('Неверный ID');
              }
            },
            child: const Text('ДОБАВИТЬ'),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // FAB меню
  // ──────────────────────────────────────────────────────────────────────────

  void _showAddMenu() {
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
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_add, color: Colors.cyan),
              title: const Text('Добавить контакт', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _addContact(); },
            ),
            ListTile(
              leading: const Icon(Icons.group_add, color: Colors.cyan),
              title: const Text('Создать группу', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _showError('Группы в разработке'); },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner, color: Colors.cyan),
              title: const Text('Сканировать QR', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(ctx); _openQrScanner(); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Меню контакта
  // ──────────────────────────────────────────────────────────────────────────

  void _showContactOptions(String uid) {
    final name     = _storage.getContactDisplayName(uid);
    final isPinned = _storage.isContactPinned(uid);
    final isMuted  = _storage.isContactMuted(uid);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Шапка
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.cyan.withValues(alpha: 0.15),
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16,
                      )),
                      Text('ID: $uid', style: const TextStyle(
                        color: Colors.white38, fontSize: 12,
                      )),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),

            // Закрепить / открепить
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: isPinned ? Colors.amber : Colors.white70,
              ),
              title: Text(
                isPinned ? 'Открепить' : 'Закрепить сверху',
                style: TextStyle(color: isPinned ? Colors.amber : Colors.white),
              ),
              onTap: () async {
                Navigator.pop(context);
                await _storage.setContactPinned(uid, !isPinned);
                setState(() => _chats = _storage.getContactsSortedByActivity());
                _showSuccess(isPinned ? 'Откреплено' : '📌 $name закреплен');
              },
            ),

            // Переименовать
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Colors.white70),
              title: const Text('Переименовать', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(uid, name);
              },
            ),

            // Заглушить
            ListTile(
              leading: Icon(
                isMuted ? Icons.volume_up_outlined : Icons.volume_off_outlined,
                color: isMuted ? Colors.white70 : Colors.orange,
              ),
              title: Text(
                isMuted ? 'Включить звук' : 'Без звука',
                style: TextStyle(color: isMuted ? Colors.white : Colors.orange),
              ),
              onTap: () async {
                Navigator.pop(context);
                await _storage.setContactMuted(uid, !isMuted);
                setState(() {});
                _showSuccess(isMuted ? 'Звук включен для $name' : '🔇 $name заглушен');
              },
            ),

            // Скопировать ID
            ListTile(
              leading: const Icon(Icons.copy_outlined, color: Colors.white70),
              title: const Text('Скопировать ID', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                Clipboard.setData(ClipboardData(text: uid));
                _showSuccess('ID скопирован: $uid');
              },
            ),

            // Очистить историю
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined, color: Colors.orange),
              title: const Text('Очистить историю', style: TextStyle(color: Colors.orange)),
              onTap: () {
                Navigator.pop(context);
                _confirmClearHistory(uid, name);
              },
            ),

            // Удалить контакт
            ListTile(
              leading: const Icon(Icons.person_remove_outlined, color: Colors.red),
              title: Text('Удалить "$name"', style: const TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteContact(uid, name);
              },
            ),

            const SizedBox(height: 8),
          ],
        ),
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
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Новое имя...',
            hintStyle: TextStyle(color: Colors.white38),
            filled: true, fillColor: Color(0xFF0A0E27),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ОТМЕНА'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isEmpty) return;
              await _storage.setContactDisplayName(uid, newName);
              Navigator.pop(context);
              setState(() => _chats = _storage.getContactsSortedByActivity());
              _showSuccess('Переименован в "$newName"');
            },
            child: const Text('СОХРАНИТЬ'),
          ),
        ],
      ),
    );
  }

  void _confirmClearHistory(String uid, String name) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Очистить историю?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Все сообщения с "$name" будут удалены с устройства.\nСам контакт останется в списке.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ОТМЕНА'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await _storage.clearChatHistory(uid);
              setState(() => _chats = _storage.getContactsSortedByActivity());
              _showSuccess('История очищена');
            },
            child: const Text('ОЧИСТИТЬ', style: TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteContact(String uid, String name) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Удалить контакт?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Удалить "$name" и всю историю переписки?',
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
              _storage.removeContact(uid);
              setState(() => _chats = _storage.getContactsSortedByActivity());
            },
            child: const Text('УДАЛИТЬ', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _performSearch(String query) {
    setState(() {
      _searchResults = query.isEmpty ? [] : _storage.searchMessages(query, limit: 50);
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Виджеты
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildConnectionIndicator() {
    final color = _connectionStatus == 'В СЕТИ'
        ? Colors.green
        : (_connectionStatus == 'ПОДКЛЮЧЕНИЕ...' ? Colors.orange : Colors.red);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, color: color, size: 8),
        const SizedBox(width: 4),
        Text(_connectionStatus, style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }

  Widget _buildChatList() {
    if (!_isReady) {
      return const Center(child: CircularProgressIndicator(color: Colors.cyan));
    }
    if (_chats.isEmpty) {
      return Center(
        child: Text('Нет чатов', style: GoogleFonts.orbitron(color: Colors.white38)),
      );
    }

    return ListView.builder(
      itemCount: _chats.length,
      itemBuilder: (c, i) {
        final uid      = _chats[i];
        final name     = _storage.getContactDisplayName(uid);
        final avatar   = _storage.getContactAvatar(uid);
        final meta     = _storage.getChatMetadata(uid);
        final unread   = meta['unreadCount'] as int? ?? 0;
        final isOnline = _storage.isContactOnline(uid);
        final isPinned = _storage.isContactPinned(uid);
        final isMuted  = _storage.isContactMuted(uid);
        final hasAvatar = avatar != null && avatar.isNotEmpty && avatar != 'null';

        return ListTile(
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xFF1A1F3C),
                backgroundImage: hasAvatar
                    ? NetworkImage('https://deepdrift-backend.onrender.com/download/$avatar')
                    : null,
                child: !hasAvatar
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.cyan),
                      )
                    : null,
              ),
              if (isOnline)
                Positioned(
                  right: 0, bottom: 0,
                  child: Container(
                    width: 12, height: 12,
                    decoration: BoxDecoration(
                      color: Colors.greenAccent,
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF0A0E27), width: 2),
                    ),
                  ),
                ),
              if (unread > 0)
                Positioned(
                  right: 0, top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.cyan, shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$unread',
                      style: const TextStyle(
                        color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          title: Row(
            children: [
              if (isPinned)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.push_pin, size: 12, color: Colors.amber),
                ),
              if (isMuted)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.volume_off, size: 12, color: Colors.white38),
                ),
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(
            meta['lastMessageText'] as String? ?? 'Нет сообщений',
            style: TextStyle(
              color: unread > 0 ? Colors.white54 : Colors.white24,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  myUid:     _myUid!,
                  targetUid: uid,
                  cipher:    _cipher,
                ),
              ),
            ).then((_) {
              if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
            });
          },
          onLongPress: () => _showContactOptions(uid),
        );
      },
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final totalUnread = _storage.getTotalUnreadCount();
    final myProfile   = _storage.getMyProfile();
    final avatarUrl   = myProfile['avatarUrl'];
    final hasMyAvatar = avatarUrl != null && avatarUrl.isNotEmpty && avatarUrl != 'null';

    return PopScope(
      canPop: !_isSearching,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSearching) {
          setState(() { _isSearching = false; _searchController.clear(); });
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E27),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1F3C),
          title: _isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Поиск...',
                    border: InputBorder.none,
                  ),
                  onChanged: _performSearch,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('DDChat', style: GoogleFonts.orbitron(fontSize: 18)),
                        if (totalUnread > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.cyan,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$totalUnread',
                              style: const TextStyle(color: Colors.black, fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          'ID: ${_myUid ?? '...'}',
                          style: const TextStyle(fontSize: 10, color: Colors.white54),
                        ),
                        const SizedBox(width: 8),
                        _buildConnectionIndicator(),
                      ],
                    ),
                  ],
                ),
          actions: [
            if (_isSearching)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _isSearching = false;
                  _searchController.clear();
                }),
              )
            else ...[
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () => setState(() => _isSearching = true),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined, color: Colors.white70),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      storage: _storage,
                      cipher:  _cipher,
                      myUid:   _myUid ?? '',
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: _showMyProfileDialog,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, left: 4),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.cyan.withValues(alpha: 0.2),
                    backgroundImage: hasMyAvatar
                        ? NetworkImage(
                            'https://deepdrift-backend.onrender.com/download/$avatarUrl')
                        : null,
                    child: !hasMyAvatar
                        ? const Icon(Icons.person, size: 20, color: Colors.cyan)
                        : null,
                  ),
                ),
              ),
            ],
          ],
        ),
        body: _isSearching ? _buildSearchResults() : _buildChatList(),
        floatingActionButton: _isSearching
            ? null
            : FloatingActionButton(
                onPressed: _showAddMenu,
                backgroundColor: Colors.cyan,
                child: const Icon(Icons.add, color: Colors.black, size: 28),
              ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return const Center(child: Icon(Icons.search_off, size: 64, color: Colors.white12));
    }
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (c, i) {
        final r    = _searchResults[i];
        final name = _storage.getContactDisplayName(r['chatWith'] as String);
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF1A1F3C),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(color: Colors.cyan),
            ),
          ),
          title: Text(name),
          subtitle: Text(
            r['text'] as String? ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () {
            setState(() => _isSearching = false);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  myUid:     _myUid!,
                  targetUid: r['chatWith'] as String,
                  cipher:    _cipher,
                ),
              ),
            ).then((_) {
              if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
            });
          },
        );
      },
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'identity_service.dart';
import 'chat_screen.dart';
import 'storage_service.dart';
import 'socket_service.dart';
import 'crypto_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  String? _myUid;
  List<String> _chats = [];
  bool _isConnected = false;
  bool _isReady = false;
  String _connectionStatus = 'OFFLINE';
  StreamSubscription? _socketSub;

  final _idService = IdentityService();
  final _storage = StorageService();
  final _socket = SocketService();
  final _cipher = SecureCipher();

  final _idController = TextEditingController();
  final _serverController = TextEditingController(
      text: 'wss://deepdrift-backend.onrender.com/ws');

  late AnimationController _animController;
  late Animation<double> _pulseAnimation;

  bool _isSearching = false;
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animController = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulseAnimation =
        Tween<double>(begin: 0.8, end: 1.0).animate(_animController);
    _setup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animController.dispose();
    _socketSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Реконнектимся когда app возвращается на foreground
    if (state == AppLifecycleState.resumed && !_socket.isConnected) {
      _socket.forceReconnect();
    }
  }

  Future<void> _setup() async {
    try {
      print('🔧 Starting setup...');
      await _storage.init();
      print('✅ Storage initialized');
      
      final uid = await _idService.getStoredUID();
      print('🆔 Stored UID: $uid');

      if (uid == null) {
        print('📝 No UID found, showing registration dialog');
        if (mounted) _showRegistrationDialog();
      } else {
        setState(() => _myUid = uid);
        print('🔌 Starting auto-connect...');
        await _autoConnect();
      }
    } catch (e, stack) {
      print('❌ Setup error: $e');
      print('Stack trace: $stack');
      if (mounted) {
        setState(() {
          _connectionStatus = 'ERROR';
          _isReady = true; // Показываем UI даже при ошибке
        });
      }
    }
  }

  Future<void> _autoConnect() async {
    try {
      print('🔌 Auto-connect starting...');
      setState(() => _connectionStatus = 'CONNECTING...');

      // Загружаем сохраненные данные
      final savedPassword = _storage.getSetting('user_password');
      final savedSalt = _storage.getSetting('user_salt');
      final authToken = _storage.getSetting('auth_token');
      final savedX25519Key = _storage.getSetting('encrypted_x25519_key');
      final savedEd25519Key = _storage.getSetting('encrypted_ed25519_key');

      print('🔑 Password: ${savedPassword != null ? "✓" : "✗"}');
      print('🔑 Salt: ${savedSalt != null ? "✓" : "✗"}');
      print('🔑 X25519 key: ${savedX25519Key != null ? "✓" : "✗"}');
      print('🔑 Ed25519 key: ${savedEd25519Key != null ? "✓" : "✗"}');

      if (savedPassword == null || savedSalt == null) {
        // Первый запуск - нужно создать пароль
        print('📝 Password not set, showing setup dialog');
        if (mounted) await _showPasswordSetupDialog();
        return;
      }

      print('🔐 Initializing cipher...');
      // Инициализируем шифр с сохраненными данными
      // Если есть сохранённые ключи - восстанавливаем их
      await _cipher.init(
        savedPassword, 
        savedSalt,
        encryptedX25519Key: savedX25519Key,
        encryptedEd25519Key: savedEd25519Key,
      );
      print('✅ Cipher initialized');
      
      // Если это первая инициализация (новые ключи), сохраняем их
      if (savedX25519Key == null || savedEd25519Key == null) {
        print('💾 Exporting and saving new keys...');
        final exportedKeys = await _cipher.exportBothKeys(savedPassword);
        await _storage.saveSetting('encrypted_x25519_key', exportedKeys['x25519']!);
        await _storage.saveSetting('encrypted_ed25519_key', exportedKeys['ed25519']!);
        print('✅ New encryption keys saved');
      }
      
      print('🌐 Connecting to server...');
      _socket.init(_cipher);
      _socket.connect(_serverController.text, _myUid!, authToken: authToken);

      _socketSub = _socket.messages.listen((data) {
        if (!mounted) return;

        final type = data['type'];

        if (type == 'uid_assigned') {
          setState(() {
            _isConnected = true;
            _connectionStatus = 'ONLINE';
          });
          _registerPublicKeysOnServer();
        }

        if (type == 'connection_status') {
          setState(() {
            _isConnected = data['connected'] ?? false;
            _connectionStatus = _isConnected ? 'ONLINE' : 'OFFLINE';
          });
        }

        if (type == 'connection_failed') {
          setState(() {
            _connectionStatus = 'FAILED';
          });
          _showError('Connection failed. Tap to retry.');
        }

        // ✅ НОВОЕ: Обработка входящих сообщений прямо на главном экране
        if (type == 'message') {
          _handleIncomingMessageQuietly(data);
        }

        if (type == 'server_error') {
          _showError('Server: ${data['message']}');
        }

        // Обновляем список чатов (счетчики непрочитанных и т.д.)
        if (type == 'message' || type == 'status_update' || type == 'message_deleted') {
          setState(() => _chats = _storage.getContactsSortedByActivity());
        }
      });

      print('✅ Socket listener setup complete');
      setState(() {
        _isReady = true;
        _chats = _storage.getContactsSortedByActivity();
      });
      print('✅ Auto-connect complete, ready: $_isReady');
    } catch (e, stack) {
      debugPrint("❌ Setup Error: $e");
      debugPrint("Stack trace: $stack");
      setState(() {
        _connectionStatus = 'ERROR';
        _isReady = true; // Показываем UI даже при ошибке
      });
      _showError('Failed to initialize: ${e.toString()}');
    }
  }

  Future<void> _registerPublicKeysOnServer() async {
    try {
      print('🔑 Registering public keys on server...');
      final x25519Key = await _cipher.getMyPublicKey();
      final ed25519Key = await _cipher.getMySigningKey();
      
      _socket.registerPublicKeys(x25519Key, ed25519Key);
      print('✅ Public keys registration request sent');
    } catch (e) {
      print('❌ Failed to register public keys: $e');
    }
  }

  // Тихое сохранение сообщения, если пользователь на главном экране
  Future<void> _handleIncomingMessageQuietly(Map<String, dynamic> data) async {
    final senderUid = data['from_uid'];
    final msgId = data['id']?.toString();
    
    if (msgId == null || _storage.hasMessage(senderUid, msgId)) return;

    try {
      final encrypted = data['encrypted_text'];
      final decrypted = await _cipher.decryptText(encrypted, fromUid: senderUid);

      final msg = {
        'id': msgId,
        'text': decrypted,
        'isMe': false,
        'time': data['time'] ?? DateTime.now().millisecondsSinceEpoch,
        'from': senderUid,
        'to': _myUid,
        'status': 'delivered',
        'type': data['messageType'] ?? 'text',
        'fileName': data['fileName'],
        'fileSize': data['fileSize'],
        // Если это файл/фото - ChatScreen сам его скачает при открытии, 
        // так как в тексте будет FILE_ID:...
      };

      await _storage.saveMessage(senderUid, msg);
      _socket.sendReadReceipt(senderUid, msgId); // Подтверждаем доставку
      
      if (mounted) {
        setState(() => _chats = _storage.getContactsSortedByActivity());
      }
    } catch (e) {
      print("Error saving message in background: $e");
    }
  }

  Future<void> _showPasswordSetupDialog() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text(
          "SECURE YOUR MESSAGES",
          style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF)),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Create a strong encryption password",
                style: GoogleFonts.robotoMono(
                    color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                "⚠️ Write it down! You cannot recover this password.",
                style: GoogleFonts.robotoMono(
                    color: Colors.orange, fontSize: 11),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "Password",
                  labelStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF0A0E27),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "Confirm Password",
                  labelStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF0A0E27),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () async {
              final password = passwordController.text;
              final confirm = confirmController.text;

              if (password.isEmpty || password.length < 8) {
                _showError('Password must be at least 8 characters');
                return;
              }

              if (password != confirm) {
                _showError('Passwords do not match');
                return;
              }

              // Генерируем уникальную соль для пользователя
              final salt = SecureCipher.generateSalt();

              // Инициализируем cipher с новыми ключами
              await _cipher.init(password, salt);
              
              // Экспортируем и сохраняем ключи
              final exportedKeys = await _cipher.exportBothKeys(password);
              
              // Сохраняем всё
              await _storage.saveSetting('user_password', password);
              await _storage.saveSetting('user_salt', salt);
              await _storage.saveSetting('encrypted_x25519_key', exportedKeys['x25519']!);
              await _storage.saveSetting('encrypted_ed25519_key', exportedKeys['ed25519']!);

              Navigator.pop(context);
              _autoConnect();
            },
            child: const Text("CREATE"),
          )
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
        title: Text(
          "FRACTAL IDENTITY",
          style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Enter your unique 6-digit ID",
              style:
                  GoogleFonts.robotoMono(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _idController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: "000000",
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF0A0E27),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
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
                _showError('Please enter a valid 6-digit ID');
              }
            },
            child: const Text("SAVE"),
          )
        ],
      ),
    );
  }

  void _addContact() {
    final targetC = TextEditingController();
    final nameC = TextEditingController();
    
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text("Add contact", style: GoogleFonts.orbitron()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Enter 6-digit contact ID",
              style:
                  GoogleFonts.robotoMono(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: targetC,
              keyboardType: TextInputType.number,
              maxLength: 6,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                hintText: "000000",
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF0A0E27),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameC,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: "Display name (optional)",
                labelStyle: const TextStyle(color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF0A0E27),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCEL"),
          ),
          ElevatedButton(
            onPressed: () async {
              if (targetC.text.length == 6) {
                if (targetC.text == _myUid) {
                  _showError("You can't add yourself as a contact");
                  return;
                }
                
                final displayName = nameC.text.trim().isNotEmpty 
                    ? nameC.text.trim() 
                    : null;
                    
                await _storage.addContact(targetC.text, displayName: displayName);
                Navigator.pop(context);
                setState(() => _chats = _storage.getContactsSortedByActivity());
              } else {
                _showError('Please enter a valid 6-digit ID');
              }
            },
            child: const Text("ADD"),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        action: _connectionStatus == 'FAILED'
            ? SnackBarAction(
                label: 'RETRY',
                textColor: Colors.white,
                onPressed: () {
                  _socket.forceReconnect();
                },
              )
            : null,
      ),
    );
  }

  void _showContactOptions(String contactUid) {
    final displayName = _storage.getContactDisplayName(contactUid);
    final stats = _storage.getChatStats(contactUid);
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text(displayName),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('UID: $contactUid',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 16),
              Text('Statistics:', style: GoogleFonts.orbitron(fontSize: 14)),
              const SizedBox(height: 8),
              Text('Total messages: ${stats['totalMessages']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Text('Your messages: ${stats['myMessages']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Text('Their messages: ${stats['theirMessages']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const Divider(height: 24),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit, color: Colors.cyan),
                title: const Text('Change display name'),
                onTap: () {
                  Navigator.pop(context);
                  _editContactName(contactUid);
                },
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Remove contact'),
                onTap: () async {
                  await _storage.removeContact(contactUid);
                  await _storage.deleteChat(contactUid);
                  setState(() => _chats = _storage.getContactsSortedByActivity());
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _editContactName(String contactUid) {
    final nameController = TextEditingController(
      text: _storage.getContactDisplayName(contactUid) == contactUid 
          ? '' 
          : _storage.getContactDisplayName(contactUid)
    );
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Edit display name'),
        content: TextField(
          controller: nameController,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: contactUid,
            filled: true,
            fillColor: const Color(0xFF0A0E27),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                await _storage.setContactDisplayName(contactUid, name);
                setState(() {});
              }
              Navigator.pop(context);
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchResults.clear();
      });
      return;
    }

    setState(() {
      _searchResults = _storage.searchMessages(query, limit: 50);
    });
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Settings', style: GoogleFonts.orbitron()),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key, color: Colors.cyan),
                title: const Text('Change password'),
                onTap: () {
                  Navigator.pop(context);
                  _changePassword();
                },
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete_forever, color: Colors.orange),
                title: const Text('Delete old messages'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteOldMessages();
                },
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.download, color: Colors.green),
                title: const Text('Export all chats'),
                onTap: () async {
                  // В реальном приложении здесь должно быть сохранение в файл
                  _showError('Export feature coming soon!');
                  Navigator.pop(context);
                },
              ),
              const Divider(),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline, color: Colors.white54),
                title: const Text('About'),
                subtitle: const Text('DeepDrift Secure v2.0'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _changePassword() {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Change Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            TextField(
              controller: newController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            TextField(
              controller: confirmController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Confirm new password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () async {
              final oldPwd = oldController.text;
              final newPwd = newController.text;
              final confirm = confirmController.text;

              final savedPwd = _storage.getSetting('user_password');
              if (oldPwd != savedPwd) {
                _showError('Incorrect current password');
                return;
              }

              if (newPwd.length < 8) {
                _showError('New password must be at least 8 characters');
                return;
              }

              if (newPwd != confirm) {
                _showError('Passwords do not match');
                return;
              }

              // Генерируем новую соль
              final newSalt = SecureCipher.generateSalt();
              
              // Экспортируем существующие ключи с новым паролем
              final exportedKeys = await _cipher.exportBothKeys(newPwd);
              
              // Сохраняем новый пароль, соль и перешифрованные ключи
              await _storage.saveSetting('user_password', newPwd);
              await _storage.saveSetting('user_salt', newSalt);
              await _storage.saveSetting('encrypted_x25519_key', exportedKeys['x25519']!);
              await _storage.saveSetting('encrypted_ed25519_key', exportedKeys['ed25519']!);

              // Переинициализируем cipher с новым паролем (ключи остаются теми же)
              await _cipher.init(
                newPwd, 
                newSalt,
                encryptedX25519Key: exportedKeys['x25519'],
                encryptedEd25519Key: exportedKeys['ed25519'],
              );

              Navigator.pop(context);
              _showError('Password changed successfully');
            },
            child: const Text('CHANGE'),
          ),
        ],
      ),
    );
  }

  void _deleteOldMessages() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Delete Old Messages'),
        content: const Text('Delete messages older than:'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () async {
              await _storage.deleteOldMessages(30);
              setState(() => _chats = _storage.getContactsSortedByActivity());
              Navigator.pop(context);
              _showError('Deleted messages older than 30 days');
            },
            child: const Text('30 DAYS'),
          ),
          TextButton(
            onPressed: () async {
              await _storage.deleteOldMessages(90);
              setState(() => _chats = _storage.getContactsSortedByActivity());
              Navigator.pop(context);
              _showError('Deleted messages older than 90 days');
            },
            child: const Text('90 DAYS'),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionIndicator() {
    Color statusColor;
    IconData statusIcon;
    String statusText = _connectionStatus;

    switch (_connectionStatus) {
      case 'ONLINE':
        statusColor = Colors.green;
        statusIcon = Icons.circle;
        break;
      case 'CONNECTING...':
        statusColor = Colors.orange;
        statusIcon = Icons.circle;
        if (_socket.reconnectAttempts > 0) {
          statusText =
              'Reconnecting (${_socket.reconnectAttempts}/${SocketService.MAX_RECONNECT_ATTEMPTS})';
        }
        break;
      case 'OFFLINE':
      case 'FAILED':
      case 'ERROR':
        statusColor = Colors.red;
        statusIcon = Icons.circle;
        break;
      default:
        statusColor = Colors.grey;
        statusIcon = Icons.circle;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(statusIcon, color: statusColor, size: 8),
        const SizedBox(width: 4),
        Text(
          statusText,
          style: TextStyle(fontSize: 10, color: statusColor),
        ),
      ],
    );
  }

  Widget _buildChatList() {
    // Показываем загрузку пока не инициализировались
    if (!_isReady) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation(Color(0xFF00D9FF)),
            ),
            const SizedBox(height: 16),
            Text(
              "Initializing secure connection...",
              style: GoogleFonts.robotoMono(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      );
    }
    
    if (_chats.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ScaleTransition(
                scale: _pulseAnimation,
                child:
                    const Icon(Icons.shield_outlined, size: 64, color: Colors.white12)),
            const SizedBox(height: 16),
            Text(
              "No contacts yet",
              style: GoogleFonts.orbitron(color: Colors.white38),
            ),
            const SizedBox(height: 8),
            Text(
              "Tap + to add a contact",
              style: GoogleFonts.robotoMono(color: Colors.white24, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _chats.length,
      itemBuilder: (c, i) {
        final contactUid = _chats[i];
        final displayName = _storage.getContactDisplayName(contactUid);
        final metadata = _storage.getChatMetadata(contactUid);
        final unreadCount = metadata['unreadCount'] ?? 0;
        final lastMsgText = metadata['lastMessageText'] ?? "No messages yet";
        
        return ListTile(
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xFF1A1F3C),
                child: Text(
                  displayName[0].toUpperCase(),
                  style: const TextStyle(color: Color(0xFF00D9FF)),
                ),
              ),
              if (unreadCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.cyan,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Center(
                      child: Text(
                        unreadCount > 9 ? '9+' : '$unreadCount',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            displayName,
            style: TextStyle(
              color: Colors.white,
              fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            lastMsgText,
            style: TextStyle(
              color: unreadCount > 0 ? Colors.white54 : Colors.white24,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            if (!_isReady) {
              _showError('Please wait for connection');
              return;
            }
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => ChatScreen(
                  myUid: _myUid!,
                  targetUid: contactUid,
                  cipher: _cipher,
                ),
              ),
            ).then((_) {
              setState(() => _chats = _storage.getContactsSortedByActivity());
            });
          },
          onLongPress: () => _showContactOptions(contactUid),
        );
      },
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 64, color: Colors.white12),
            const SizedBox(height: 16),
            Text(
              "No results found",
              style: GoogleFonts.orbitron(color: Colors.white38),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final result = _searchResults[index];
        final contactUid = result['chatWith'];
        final displayName = _storage.getContactDisplayName(contactUid);

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: const Color(0xFF1A1F3C),
            child: Text(
              displayName[0].toUpperCase(),
              style: const TextStyle(color: Color(0xFF00D9FF)),
            ),
          ),
          title: Text(displayName),
          subtitle: Text(
            result['text'] ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () {
            setState(() => _isSearching = false);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (c) => ChatScreen(
                  myUid: _myUid!,
                  targetUid: contactUid,
                  cipher: _cipher,
                ),
              ),
            ).then((_) {
              setState(() => _chats = _storage.getContactsSortedByActivity());
            });
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalUnread = _storage.getTotalUnreadCount();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Search messages...',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
                onChanged: _performSearch,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        "DeepDrift Messenger",
                        style: GoogleFonts.orbitron(fontSize: 16),
                      ),
                      if (totalUnread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.cyan,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            totalUnread > 99 ? '99+' : '$totalUnread',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Row(
                    children: [
                      Text(
                        "ID: ${_myUid ?? '...'}",
                        style: const TextStyle(
                            fontSize: 10, color: Colors.white54),
                      ),
                      const SizedBox(width: 8),
                      const Text("|",
                          style:
                              TextStyle(fontSize: 10, color: Colors.white24)),
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
              onPressed: () {
                setState(() {
                  _isSearching = false;
                  _searchController.clear();
                  _searchResults.clear();
                });
              },
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                setState(() => _isSearching = true);
              },
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showSettings,
            ),
          ],
        ],
      ),
      body: _isSearching ? _buildSearchResults() : _buildChatList(),
      floatingActionButton: _isSearching
          ? null
          : FloatingActionButton(
              onPressed: _addContact,
              backgroundColor: const Color(0xFF00D9FF),
              child: const Icon(Icons.add, color: Colors.black),
            ),
    );
  }
}

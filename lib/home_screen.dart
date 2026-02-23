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

  // НОВЫЕ ПЕРЕМЕННЫЕ для улучшений
  final _quickIdController = TextEditingController();
  bool _hasUpdate = false;
  String _currentVersion = '3.0.0';
  String _latestVersion = '3.0.1';

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
    _checkForUpdatesInBackground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animController.dispose();
    _socketSub?.cancel();
    _searchController.dispose();
    _quickIdController.dispose();
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

      if (savedPassword == null || savedSalt == null) {
        // Первый запуск - нужно создать пароль
        print('📝 Password not set, showing setup dialog');
        if (mounted) await _showPasswordSetupDialog();
        return;
      }

      print('🔐 Initializing cipher...');
      // Инициализируем шифр с сохраненными данными
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

        if (data['type'] == 'uid_assigned') {
          print('✅ UID assigned by server');
          setState(() {
            _isConnected = true;
            _connectionStatus = 'ONLINE';
          });
          
          _registerPublicKeysOnServer();
        }

        if (data['type'] == 'connection_status') {
          setState(() {
            _isConnected = data['connected'] ?? false;
            _connectionStatus = _isConnected ? 'ONLINE' : 'OFFLINE';
          });
        }

        if (data['type'] == 'connection_failed') {
          setState(() {
            _connectionStatus = 'FAILED';
          });
          _showError('Connection failed. Tap to retry.');
        }

        if (data['type'] == 'server_error') {
          _showError('Server: ${data['message']}');
        }

        // Обновляем список чатов при новых сообщениях
        if (data['type'] == 'message' || data['type'] == 'status_update') {
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

              final salt = SecureCipher.generateSalt();
              await _cipher.init(password, salt);
              final exportedKeys = await _cipher.exportBothKeys(password);
              
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
              // НОВЫЙ пункт - проверка обновлений
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.system_update,
                  color: _hasUpdate ? Colors.red : Colors.green,
                ),
                title: const Text('Check for updates'),
                subtitle: _hasUpdate 
                    ? Text(
                        'New version available: v$_latestVersion',
                        style: const TextStyle(color: Colors.red, fontSize: 11),
                      )
                    : const Text(
                        'You\'re up to date',
                        style: TextStyle(color: Colors.green, fontSize: 11),
                      ),
                trailing: _hasUpdate 
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.red, width: 1),
                        ),
                        child: const Text(
                          'NEW',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      )
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  _showUpdateDialog();
                },
              ),
              const Divider(color: Colors.white12),
              
              // Остальные пункты меню
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
                subtitle: const Text('DDchat v3.0.0'),
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

              final newSalt = SecureCipher.generateSalt();
              final exportedKeys = await _cipher.exportBothKeys(newPwd);
              
              await _storage.saveSetting('user_password', newPwd);
              await _storage.saveSetting('user_salt', newSalt);
              await _storage.saveSetting('encrypted_x25519_key', exportedKeys['x25519']!);
              await _storage.saveSetting('encrypted_ed25519_key', exportedKeys['ed25519']!);

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

    return WillPopScope(
      onWillPop: () async {
        if (_isSearching) {
          setState(() {
            _isSearching = false;
            _searchController.clear();
            _searchResults.clear();
          });
          return false;
        }
        return true;
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
                          "DDchat",
                          style: GoogleFonts.orbitron(fontSize: 18),
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
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.settings),
                    if (_hasUpdate)
                      Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 10,
                            minHeight: 10,
                          ),
                          child: const Center(
                            child: Text(
                              '!',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                onPressed: _showSettings,
              ),
            ],
          ],
        ),
        body: _isSearching ? _buildSearchResults() : _buildChatList(),
        
        bottomNavigationBar: _isSearching 
          ? null 
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1F3C),
                border: Border(
                  top: BorderSide(color: Color(0xFF00D9FF), width: 0.5),
                ),
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    const Icon(Icons.flash_on, color: Color(0xFF00D9FF), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _quickIdController,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Enter ID for quick chat...',
                          hintStyle: const TextStyle(
                            color: Colors.white38,
                            fontSize: 13,
                          ),
                          filled: true,
                          fillColor: const Color(0xFF0A0E27),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (value) {
                          if (value.isNotEmpty) {
                            _addContactWithId(value);
                            _quickIdController.clear();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF00D9FF),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_forward, color: Colors.black),
                        iconSize: 20,
                        onPressed: () {
                          if (_quickIdController.text.isNotEmpty) {
                            _addContactWithId(_quickIdController.text);
                            setState(() => _quickIdController.clear());
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
        floatingActionButton: _isSearching
            ? null
            : FloatingActionButton(
                onPressed: _addContact,
                backgroundColor: const Color(0xFF00D9FF),
                child: const Icon(Icons.add, color: Colors.black),
              ),
      ),
    );
  }

  // ==========================================
  // НОВЫЕ ФУНКЦИИ
  // ==========================================

  void _addContactWithId(String contactId) {
    if (!_isReady) {
      _showError('Please wait for connection');
      return;
    }

    contactId = contactId.trim();
    
    if (contactId.isEmpty) {
      _showError('Please enter a valid ID');
      return;
    }

    if (contactId == _myUid) {
      _showError('Cannot add yourself as a contact');
      return;
    }

    if (_chats.contains(contactId)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (c) => ChatScreen(
            myUid: _myUid!,
            targetUid: contactId,
            cipher: _cipher,
          ),
        ),
      ).then((_) {
        setState(() => _chats = _storage.getContactsSortedByActivity());
      });
      return;
    }

    _storage.addContact(contactId, displayName: contactId);
    setState(() => _chats = _storage.getContactsSortedByActivity());
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => ChatScreen(
          myUid: _myUid!,
          targetUid: contactId,
          cipher: _cipher,
        ),
      ),
    ).then((_) {
      setState(() => _chats = _storage.getContactsSortedByActivity());
    });
  }

  Future<void> _checkForUpdatesInBackground() async {
    await Future.delayed(const Duration(seconds: 5));
    
    try {
      final hasUpdate = _compareVersions(_currentVersion, _latestVersion) < 0;
      
      if (mounted && hasUpdate) {
        setState(() => _hasUpdate = true);
      }
    } catch (e) {
      print('Error checking for updates: $e');
    }
  }

  int _compareVersions(String current, String latest) {
    final currentParts = current.split('.').map(int.parse).toList();
    final latestParts = latest.split('.').map(int.parse).toList();
    
    for (int i = 0; i < 3; i++) {
      if (latestParts[i] > currentParts[i]) return -1;
      if (latestParts[i] < currentParts[i]) return 1;
    }
    return 0;
  }

  void _showUpdateDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF00D9FF)),
            const SizedBox(width: 12),
            const Text('Updates'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Current version:'),
                Text(
                  'v$_currentVersion',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            if (_hasUpdate) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Latest version:'),
                  Text(
                    'v$_latestVersion',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00D9FF),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF00D9FF).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF00D9FF).withValues(alpha: 0.3),
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'What\'s new:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00D9FF),
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '• Quick ID input field\n'
                      '• Auto-scroll in chats\n'
                      '• Voice recording improvements\n'
                      '• Bug fixes and performance',
                      style: TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () {
                  Navigator.pop(context);
                  _showError('Visit: github.com/yourrepo/releases/latest');
                },
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00D9FF),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.download, color: Colors.black),
                      SizedBox(width: 8),
                      Text(
                        'Download Update',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'You\'re using the latest version!',
                        style: TextStyle(color: Colors.green),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }
}

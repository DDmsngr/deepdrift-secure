import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart'; // Подключили библиотеку QR

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

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  String? _myUid;
  List<String> _chats =[];
  bool _isConnected = false;
  bool _isReady = false;
  String _connectionStatus = 'OFFLINE';
  StreamSubscription? _socketSub;

  final _idService = IdentityService();
  final _storage = StorageService();
  final _socket = SocketService();
  final _cipher = SecureCipher();
  final _imagePicker = ImagePicker(); 

  final _idController = TextEditingController();
  final _serverController = TextEditingController(text: 'wss://deepdrift-backend.onrender.com/ws');

  bool _isSearching = false;
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults =[];

  final _quickIdController = TextEditingController();

  Timer? _statusCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup();
    
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isConnected) {
        _socket.checkStatuses(_chats);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _socketSub?.cancel();
    _statusCheckTimer?.cancel();
    _searchController.dispose();
    _quickIdController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
       if (!_socket.isConnected) _socket.forceReconnect();
       _socket.checkStatuses(_chats);
    }
  }

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
      if (mounted) setState(() { _connectionStatus = 'ERROR'; _isReady = true; });
    }
  }

  Future<void> _autoConnect() async {
    try {
      setState(() => _connectionStatus = 'CONNECTING...');

      final savedPassword = _storage.getSetting('user_password');
      final savedSalt = _storage.getSetting('user_salt');
      final authToken = _storage.getSetting('auth_token');
      final savedX25519Key = _storage.getSetting('encrypted_x25519_key');
      final savedEd25519Key = _storage.getSetting('encrypted_ed25519_key');

      if (savedPassword == null || savedSalt == null) {
        if (mounted) await _showPasswordSetupDialog();
        return;
      }

      await _cipher.init(savedPassword, savedSalt, encryptedX25519Key: savedX25519Key, encryptedEd25519Key: savedEd25519Key);
      
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
          setState(() { _isConnected = true; _connectionStatus = 'ONLINE'; });
          _registerPublicKeysOnServer();
          _socket.checkStatuses(_storage.getContacts());
        }

        if (type == 'connection_status') {
          setState(() {
            _isConnected = data['connected'] ?? false;
            _connectionStatus = _isConnected ? 'ONLINE' : 'OFFLINE';
          });
        }

        if (type == 'connection_failed') {
          setState(() => _connectionStatus = 'FAILED');
        }

        if (type == 'user_status') {
          final uid = data['uid'];
          final isOnline = data['status'] == 'online';
          final lastSeen = data['last_seen'];
          _storage.setContactStatus(uid, isOnline, lastSeen);
          if (mounted) setState(() {}); 
        }

        if (type == 'message') _handleIncomingMessageQuietly(data);

        if (type == 'message' || type == 'status_update' || type == 'message_deleted' || type == 'user_status') {
           setState(() => _chats = _storage.getContactsSortedByActivity());
        }
      });

      setState(() {
        _isReady = true;
        _chats = _storage.getContactsSortedByActivity();
      });
    } catch (e) {
      setState(() { _connectionStatus = 'ERROR'; _isReady = true; });
    }
  }

  Future<void> _registerPublicKeysOnServer() async {
    try {
      final x25519Key = await _cipher.getMyPublicKey();
      final ed25519Key = await _cipher.getMySigningKey();
      _socket.registerPublicKeys(x25519Key, ed25519Key);
    } catch (e) {
      print('Failed to register public keys: $e');
    }
  }

  Future<void> _handleIncomingMessageQuietly(Map<String, dynamic> data) async {
    final senderUid = data['from_uid'];
    final msgId = data['id']?.toString();
    
    if (msgId == null || _storage.hasMessage(senderUid, msgId)) return;

    try {
      final encrypted = data['encrypted_text'];
      final decrypted = await _cipher.decryptText(encrypted, fromUid: senderUid);

      final msg = {
        'id': msgId, 'text': decrypted, 'isMe': false,
        'time': data['time'] ?? DateTime.now().millisecondsSinceEpoch,
        'from': senderUid, 'to': _myUid, 'status': 'delivered',
        'type': data['messageType'] ?? 'text',
        'fileName': data['fileName'], 'fileSize': data['fileSize'],
      };

      await _storage.saveMessage(senderUid, msg);
      _socket.sendReadReceipt(senderUid, msgId); 
      
      if (mounted) setState(() => _chats = _storage.getContactsSortedByActivity());
    } catch (e) { print("Quiet save error: $e"); }
  }

  // ==========================================
  // ДИАЛОГИ И UI
  // ==========================================

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red));
  }

  void _showMyProfileDialog() {
    final profile = _storage.getMyProfile();
    final nameCtrl = TextEditingController(text: profile['nickname']);
    String? currentAvatar = profile['avatarUrl'];

    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setDialogState) {
          bool hasAvatar = currentAvatar != null && currentAvatar!.isNotEmpty && currentAvatar != 'null';
          
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1F3C),
            title: Text("Мой профиль", style: GoogleFonts.orbitron()),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children:[
                  GestureDetector(
                    onTap: () async {
                      final img = await _imagePicker.pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512);
                      if (img != null) {
                        String? fileId = await _socket.uploadFile(File(img.path));
                        if (fileId != null) {
                          setDialogState(() {
                            currentAvatar = fileId;
                          });
                        } else {
                          _showError("Ошибка загрузки аватара");
                        }
                      }
                    },
                    child: CircleAvatar(
                      radius: 40,
                      backgroundColor: const Color(0xFF0A0E27),
                      backgroundImage: hasAvatar ? NetworkImage('https://deepdrift-backend.onrender.com/download/$currentAvatar') : null,
                      child: !hasAvatar ? const Icon(Icons.add_a_photo, size: 30, color: Colors.cyan) : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text("Твой ID: $_myUid", style: const TextStyle(color: Colors.cyan, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  const SizedBox(height: 16),
                  
                  // ГЕНЕРАТОР QR-КОДА
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
                  const Text("Покажи этот QR-код другу\nдля быстрого добавления", textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 16),

                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: "Твое имя (никнейм)",
                      filled: true, fillColor: Color(0xFF0A0E27),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions:[
              TextButton(onPressed: () => Navigator.pop(context), child: const Text("ОТМЕНА")),
              ElevatedButton(
                onPressed: () async {
                  await _storage.saveMyProfile(nickname: nameCtrl.text.trim(), avatarUrl: currentAvatar);
                  _socket.updateProfile(nameCtrl.text.trim(), currentAvatar);
                  Navigator.pop(context);
                  setState(() {}); 
                },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
                child: const Text("СОХРАНИТЬ", style: TextStyle(fontWeight: FontWeight.bold)),
              )
            ],
          );
        }
      ),
    );
  }

  Future<void> _showPasswordSetupDialog() async {
    final pwdCtrl = TextEditingController();
    final confCtrl = TextEditingController();

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text("ЗАЩИТА ЧАТОВ", style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children:[
            const Text("⚠️ Обязательно запомни его! Восстановить будет невозможно.", style: TextStyle(color: Colors.orange, fontSize: 11)),
            const SizedBox(height: 16),
            TextField(controller: pwdCtrl, obscureText: true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "Придумай пароль", filled: true, fillColor: Color(0xFF0A0E27))),
            const SizedBox(height: 12),
            TextField(controller: confCtrl, obscureText: true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "Повтори пароль", filled: true, fillColor: Color(0xFF0A0E27))),
          ],
        ),
        actions:[
          ElevatedButton(
            onPressed: () async {
              if (pwdCtrl.text.length < 8 || pwdCtrl.text != confCtrl.text) {
                _showError("Пароли должны совпадать (минимум 8 символов)");
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
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
            child: const Text("СОЗДАТЬ", style: TextStyle(fontWeight: FontWeight.bold)),
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
        title: Text("ДОБРО ПОЖАЛОВАТЬ В DDCHAT", style: GoogleFonts.orbitron(color: const Color(0xFF00D9FF), fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children:[
            const Text("Придумай себе номер из 6 цифр.\nПо нему тебя будут находить друзья!", 
                style: TextStyle(color: Colors.white70, fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TextField(
              controller: _idController, keyboardType: TextInputType.number, maxLength: 6,
              style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 6, fontWeight: FontWeight.bold), textAlign: TextAlign.center,
              decoration: const InputDecoration(hintText: "000000", filled: true, fillColor: Color(0xFF0A0E27)),
            ),
          ],
        ),
        actions:[
          ElevatedButton(
            onPressed: () async {
              if (_idController.text.length == 6) {
                await _idService.saveUID(_idController.text);
                Navigator.pop(context);
                _setup();
              } else {
                _showError("Номер должен состоять ровно из 6 цифр");
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
            child: const Text("СОЗДАТЬ", style: TextStyle(fontWeight: FontWeight.bold)),
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
          children:[
            TextField(controller: targetC, keyboardType: TextInputType.number, maxLength: 6, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center, decoration: const InputDecoration(hintText: "000000", filled: true, fillColor: Color(0xFF0A0E27))),
            const SizedBox(height: 12),
            TextField(controller: nameC, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: "Display name (optional)", filled: true, fillColor: Color(0xFF0A0E27))),
          ],
        ),
        actions:[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCEL")),
          ElevatedButton(
            onPressed: () async {
              if (targetC.text.length == 6 && targetC.text != _myUid) {
                _socket.getProfile(targetC.text);
                await _storage.addContact(targetC.text, displayName: nameC.text.trim().isNotEmpty ? nameC.text.trim() : null);
                Navigator.pop(context);
                setState(() => _chats = _storage.getContactsSortedByActivity());
              } else {
                _showError("Invalid ID");
              }
            },
            child: const Text("ADD"),
          ),
        ],
      ),
    );
  }

  void _addContactWithId(String contactId) {
    if (!_isReady) return;
    contactId = contactId.trim();
    if (contactId.isEmpty || contactId == _myUid) {
      _showError("Invalid contact ID");
      return;
    }

    if (!_chats.contains(contactId)) {
      _socket.getProfile(contactId);
      _storage.addContact(contactId, displayName: contactId);
      setState(() => _chats = _storage.getContactsSortedByActivity());
    }
    
    Navigator.push(context, MaterialPageRoute(builder: (c) => ChatScreen(myUid: _myUid!, targetUid: contactId, cipher: _cipher)))
        .then((_) => setState(() => _chats = _storage.getContactsSortedByActivity()));
  }

  void _showContactOptions(String uid) {
    final name = _storage.getContactDisplayName(uid);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children:[
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text('Delete "$name"', style: const TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteContact(uid, name);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteContact(String uid, String name) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Delete contact?', style: TextStyle(color: Colors.white)),
        content: Text('Remove "$name" and all chat history?', style: const TextStyle(color: Colors.white70)),
        actions:[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _storage.removeContact(uid);
              setState(() => _chats = _storage.getContactsSortedByActivity());
            },
            child: const Text('DELETE', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _performSearch(String query) {
    setState(() {
      _searchResults = query.isEmpty ?[] : _storage.searchMessages(query, limit: 50);
    });
  }

  Widget _buildConnectionIndicator() {
    Color color = _connectionStatus == 'ONLINE' ? Colors.green : (_connectionStatus == 'CONNECTING...' ? Colors.orange : Colors.red);
    return Row(mainAxisSize: MainAxisSize.min, children:[Icon(Icons.circle, color: color, size: 8), const SizedBox(width: 4), Text(_connectionStatus, style: TextStyle(fontSize: 10, color: color))]);
  }

  Widget _buildChatList() {
    if (!_isReady) return const Center(child: CircularProgressIndicator(color: Colors.cyan));
    if (_chats.isEmpty) return Center(child: Text("No contacts yet", style: GoogleFonts.orbitron(color: Colors.white38)));

    return ListView.builder(
      itemCount: _chats.length,
      itemBuilder: (c, i) {
        final uid = _chats[i];
        final name = _storage.getContactDisplayName(uid);
        final avatar = _storage.getContactAvatar(uid);
        final meta = _storage.getChatMetadata(uid);
        final unread = meta['unreadCount'] ?? 0;
        final isOnline = _storage.isContactOnline(uid);

        bool hasAvatar = avatar != null && avatar.isNotEmpty && avatar != 'null';

        return ListTile(
          leading: Stack(
            children:[
              CircleAvatar(
                backgroundColor: const Color(0xFF1A1F3C),
                backgroundImage: hasAvatar ? NetworkImage('https://deepdrift-backend.onrender.com/download/$avatar') : null,
                child: !hasAvatar ? Text(name[0].toUpperCase(), style: const TextStyle(color: Colors.cyan)) : null,
              ),
              if (isOnline)
                Positioned(right: 0, bottom: 0, child: Container(width: 12, height: 12, decoration: BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF0A0E27), width: 2)))),
              if (unread > 0)
                Positioned(right: 0, top: 0, child: Container(padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: Colors.cyan, shape: BoxShape.circle), child: Text('$unread', style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)))),
            ],
          ),
          title: Text(name, style: TextStyle(color: Colors.white, fontWeight: unread > 0 ? FontWeight.bold : FontWeight.normal)),
          subtitle: Text(meta['lastMessageText'] ?? "No messages", style: TextStyle(color: unread > 0 ? Colors.white54 : Colors.white24, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (c) => ChatScreen(myUid: _myUid!, targetUid: uid, cipher: _cipher)))
                .then((_) => setState(() => _chats = _storage.getContactsSortedByActivity()));
          },
          onLongPress: () => _showContactOptions(uid),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalUnread = _storage.getTotalUnreadCount();
    final myProfile = _storage.getMyProfile();
    bool hasMyAvatar = myProfile['avatarUrl'] != null && myProfile['avatarUrl']!.isNotEmpty && myProfile['avatarUrl'] != 'null';

    return PopScope(
      canPop: !_isSearching,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isSearching) setState(() { _isSearching = false; _searchController.clear(); });
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E27),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A1F3C),
          title: _isSearching
              ? TextField(controller: _searchController, autofocus: true, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Search...', border: InputBorder.none), onChanged: _performSearch)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children:[
                    Row(
                      children:[
                        Text("DDChat", style: GoogleFonts.orbitron(fontSize: 18)),
                        if (totalUnread > 0) Container(margin: const EdgeInsets.only(left: 8), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.cyan, borderRadius: BorderRadius.circular(10)), child: Text('$totalUnread', style: const TextStyle(color: Colors.black, fontSize: 10))),
                      ],
                    ),
                    Row(children:[Text("ID: ${_myUid ?? '...'}", style: const TextStyle(fontSize: 10, color: Colors.white54)), const SizedBox(width: 8), _buildConnectionIndicator()]),
                  ],
                ),
          actions:[
            if (_isSearching) IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _isSearching = false; _searchController.clear(); }))
            else ...[
              IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => _isSearching = true)),
              GestureDetector(
                onTap: _showMyProfileDialog,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12, left: 8),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.cyan.withValues(alpha: 0.2),
                    backgroundImage: hasMyAvatar ? NetworkImage('https://deepdrift-backend.onrender.com/download/${myProfile['avatarUrl']}') : null,
                    child: !hasMyAvatar ? const Icon(Icons.person, size: 20, color: Colors.cyan) : null,
                  ),
                ),
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
                border: Border(top: BorderSide(color: Color(0xFF00D9FF), width: 0.5)),
              ),
              child: SafeArea(
                child: Row(
                  children:[
                    const Icon(Icons.flash_on, color: Color(0xFF00D9FF), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _quickIdController,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Enter ID for quick chat...',
                          hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                          filled: true, fillColor: const Color(0xFF0A0E27),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
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
                      decoration: const BoxDecoration(color: Color(0xFF00D9FF), shape: BoxShape.circle),
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
            
        floatingActionButton: _isSearching ? null : FloatingActionButton(onPressed: _addContact, backgroundColor: Colors.cyan, child: const Icon(Icons.add, color: Colors.black)),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) return const Center(child: Icon(Icons.search_off, size: 64, color: Colors.white12));
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (c, i) {
        final r = _searchResults[i];
        final name = _storage.getContactDisplayName(r['chatWith']);
        return ListTile(
          leading: CircleAvatar(backgroundColor: const Color(0xFF1A1F3C), child: Text(name[0].toUpperCase(), style: const TextStyle(color: Colors.cyan))),
          title: Text(name), subtitle: Text(r['text'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          onTap: () {
            setState(() => _isSearching = false);
            Navigator.push(context, MaterialPageRoute(builder: (c) => ChatScreen(myUid: _myUid!, targetUid: r['chatWith'], cipher: _cipher)))
                .then((_) => setState(() => _chats = _storage.getContactsSortedByActivity()));
          },
        );
      },
    );
  }
}

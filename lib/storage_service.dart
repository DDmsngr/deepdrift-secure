import 'dart:convert';
import 'dart:math';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'config/app_config.dart';

/// Сервис для локального хранения данных приложения.
///
/// ИЗМЕНЕНИЯ v6:
/// - Шифрованный Hive бокс для сообщений (E2E бессмысленна с открытым хранилищем)
/// - Механизм миграции версий хранилища
/// - Поддержка исчезающих сообщений (TTL)
/// - Локальный список заблокированных
/// - Per-key sequential future chain (_withLock)
class StorageService {
  static const String _msgBox       = 'messages_history_enc';
  static const String _contactsBox  = 'contacts_list';
  static const String _settingsBox  = 'settings';
  static const String _metadataBox  = 'metadata';
  static const String _reactionsBox = 'reactions';

  static const int MAX_MESSAGES_PER_CHAT = AppConfig.maxMessagesPerChat;

  // upload_token — синглтон в памяти
  static String? _uploadTokenCache;
  static String? get uploadToken => _uploadTokenCache;
  static void setUploadToken(String token) { _uploadTokenCache = token; }

  // SECURITY: auth_token хранится в Keychain/Keystore
  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<void> saveAuthToken(String token) =>
      _secureStorage.write(key: 'auth_token', value: token);
  Future<String?> getAuthToken() =>
      _secureStorage.read(key: 'auth_token');
  Future<void> deleteAuthToken() =>
      _secureStorage.delete(key: 'auth_token');

  Future<void> cachePassword(String password) =>
      _secureStorage.write(key: 'user_password_cache', value: password);
  Future<String?> getCachedPassword() =>
      _secureStorage.read(key: 'user_password_cache');
  Future<void> deleteCachedPassword() =>
      _secureStorage.delete(key: 'user_password_cache');

  // Per-key mutex
  final _locks = <String, Future<void>>{};

  // Кэш отсортированных контактов
  List<String>? _sortedContactsCache;
  bool          _sortedContactsDirty = true;

  void _invalidateSortedContacts() {
    _sortedContactsDirty = true;
    _sortedContactsCache = null;
  }

  Future<T> _withLock<T>(String key, Future<T> Function() fn) {
    final prev = _locks[key] ?? Future<void>.value();
    final next = prev.then<T>((_) => fn());
    _locks[key] = next.then<void>((_) {}).catchError((_) {});
    return next;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Инициализация с шифрованным боксом и миграцией
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    await Hive.initFlutter();

    // Получаем или генерируем ключ шифрования для Hive
    final encryptionKey = await _getOrCreateEncryptionKey();

    // Открываем шифрованный бокс для сообщений
    if (!Hive.isBoxOpen(_msgBox)) {
      await Hive.openBox(_msgBox, encryptionCipher: HiveAesCipher(encryptionKey));
    }

    // Остальные боксы — без шифрования (метаданные, настройки)
    if (!Hive.isBoxOpen(_contactsBox))  await Hive.openBox(_contactsBox);
    if (!Hive.isBoxOpen(_settingsBox))  await Hive.openBox(_settingsBox);
    if (!Hive.isBoxOpen(_metadataBox))  await Hive.openBox(_metadataBox);
    if (!Hive.isBoxOpen(_reactionsBox)) await Hive.openBox(_reactionsBox);

    // Миграция
    await _runMigrations();
  }

  /// Получает или создаёт 256-bit ключ шифрования Hive в Keystore.
  Future<List<int>> _getOrCreateEncryptionKey() async {
    const keyName = 'hive_encryption_key';
    final existing = await _secureStorage.read(key: keyName);

    if (existing != null) {
      return base64Decode(existing);
    }

    // Генерируем новый ключ
    final key = Hive.generateSecureKey();
    await _secureStorage.write(key: keyName, value: base64Encode(key));
    return key;
  }

  /// Выполняет миграции данных при обновлении формата.
  Future<void> _runMigrations() async {
    final settingsBox = Hive.box(_settingsBox);
    final currentVersion = settingsBox.get('storage_version', defaultValue: 1) as int;

    if (currentVersion < 2) {
      // Миграция v1 → v2: перенос из нешифрованного бокса в шифрованный
      // Если старый бокс существует — переносим данные
      try {
        const oldMsgBox = 'messages_history';
        if (!Hive.isBoxOpen(oldMsgBox)) {
          // Пытаемся открыть старый бокс (может не существовать)
          try {
            final oldBox = await Hive.openBox(oldMsgBox);
            final newBox = Hive.box(_msgBox);
            // Переносим все записи
            for (final key in oldBox.keys) {
              final value = oldBox.get(key);
              if (value != null) {
                await newBox.put(key, value);
              }
            }
            await oldBox.deleteFromDisk();
          } catch (_) {
            // Старый бокс не существует — ничего не делаем
          }
        }
      } catch (e) {
        // Не критично — просто теряем старые сообщения
      }
    }

    if (currentVersion < AppConfig.storageVersion) {
      await settingsBox.put('storage_version', AppConfig.storageVersion);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Профиль и статусы
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> saveMyProfile({String? nickname, String? avatarUrl}) async {
    if (nickname  != null) await saveSetting('my_nickname', nickname);
    if (avatarUrl != null) await saveSetting('my_avatar',   avatarUrl);
  }

  Map<String, String?> getMyProfile() => {
    'nickname':  getSetting('my_nickname'),
    'avatarUrl': getSetting('my_avatar'),
  };

  Future<void> setContactStatus(String uid, bool isOnline, int? lastSeen) async {
    final box = Hive.box(_metadataBox);
    await box.put('online_$uid', isOnline);
    if (lastSeen != null) await box.put('last_seen_$uid', lastSeen);
  }

  bool isContactOnline(String uid) =>
      Hive.box(_metadataBox).get('online_$uid', defaultValue: false) as bool;

  int getContactLastSeen(String uid) =>
      Hive.box(_metadataBox).get('last_seen_$uid', defaultValue: 0) as int;

  Future<void> setContactAvatar(String uid, String avatarUrl) async =>
      Hive.box(_contactsBox).put('avatar_$uid', avatarUrl);

  String? getContactAvatar(String uid) =>
      Hive.box(_contactsBox).get('avatar_$uid') as String?;

  // ──────────────────────────────────────────────────────────────────────────
  // Сообщения
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> saveMessage(String chatWith, Map<String, dynamic> msg) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);

      if (history.any((m) => m['id'] == msg['id'])) return;

      history.add(Map<String, dynamic>.from(msg));

      final trimmed = history.length > MAX_MESSAGES_PER_CHAT
          ? history.sublist(history.length - MAX_MESSAGES_PER_CHAT)
          : history;

      await box.put(chatWith, trimmed);
      await _updateChatMetadataInternal(chatWith, msg);
      _invalidateSortedContacts();
    });
  }

  bool hasMessage(String chatWith, String messageId) {
    return getHistory(chatWith).any((m) => m['id'] == messageId);
  }

  List<Map<String, dynamic>> getHistory(String chatWith) {
    return _readHistory(Hive.box(_msgBox), chatWith);
  }

  List<Map<String, dynamic>> getRecentMessages(String chatWith, {int limit = 50}) {
    final all = getHistory(chatWith);
    if (all.isEmpty || all.length <= limit) return List.from(all);
    return List.from(all.sublist(all.length - limit));
  }

  List<Map<String, dynamic>> getOlderMessages(
    String chatWith,
    int beforeIndex, {
    int limit = 50,
  }) {
    final all = getHistory(chatWith);
    if (beforeIndex <= 0 || all.isEmpty) return [];
    final start = (beforeIndex - limit).clamp(0, beforeIndex);
    return List.from(all.sublist(start, beforeIndex));
  }

  Future<void> updateMessageStatus(
    String chatWith,
    String messageId,
    String status,
  ) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);

      bool updated = false;
      for (final msg in history) {
        if (msg['id'] == messageId) {
          msg['status'] = status;
          updated = true;
          break;
        }
      }

      if (updated) {
        await box.put(chatWith, history);
        await _updateChatMetadataInternal(chatWith, null);
      }
    });
  }

  Future<void> deleteMessage(String chatWith, String messageId) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);

      history.removeWhere((m) => m['id'] == messageId);
      await box.put(chatWith, history);
    });
  }

  Future<void> editMessage(
    String chatWith,
    String messageId,
    String newText,
  ) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);

      for (final msg in history) {
        if (msg['id'] == messageId) {
          msg['text']     = newText;
          msg['isEdited'] = true;
          break;
        }
      }
      await box.put(chatWith, history);
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Исчезающие сообщения (Disappearing Messages)
  // ──────────────────────────────────────────────────────────────────────────

  /// Устанавливает TTL для чата (0 = отключено).
  Future<void> setChatTtl(String chatWith, int ttlSeconds) async {
    await Hive.box(_metadataBox).put('ttl_$chatWith', ttlSeconds);
  }

  /// Возвращает TTL для чата (0 = отключено).
  int getChatTtl(String chatWith) {
    return Hive.box(_metadataBox).get('ttl_$chatWith', defaultValue: 0) as int;
  }

  /// Удаляет истёкшие сообщения с TTL.
  Future<void> cleanExpiredMessages() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final box = Hive.box(_msgBox);

    for (final chatWith in List.of(box.keys)) {
      await _withLock(chatWith.toString(), () async {
        final history = _readHistory(box, chatWith.toString());
        final before  = history.length;

        history.removeWhere((msg) {
          final ttl = msg['ttl_seconds'] as int?;
          if (ttl == null || ttl == 0) return false;
          final time = msg['time'];
          if (time == null) return false;
          final msgTime = time is int ? time : 0;
          final expiresAt = msgTime + (ttl * 1000);
          return now > expiresAt;
        });

        if (history.length != before) {
          if (history.isEmpty) {
            await box.delete(chatWith);
          } else {
            await box.put(chatWith, history);
          }
        }
      });
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Блокировка пользователей (локальный список)
  // ──────────────────────────────────────────────────────────────────────────

  static const String _blockedKey = 'blocked_users';

  Future<void> blockUser(String uid) async {
    await _withLock(_blockedKey, () async {
      final box = Hive.box(_metadataBox);
      final dynamic raw = box.get(_blockedKey);
      final blocked = (raw is List) ? raw.map((e) => e.toString()).toList() : <String>[];
      if (!blocked.contains(uid)) {
        blocked.add(uid);
        await box.put(_blockedKey, blocked);
      }
    });
  }

  Future<void> unblockUser(String uid) async {
    await _withLock(_blockedKey, () async {
      final box = Hive.box(_metadataBox);
      final dynamic raw = box.get(_blockedKey);
      final blocked = (raw is List) ? raw.map((e) => e.toString()).toList() : <String>[];
      blocked.remove(uid);
      await box.put(_blockedKey, blocked);
    });
  }

  bool isUserBlocked(String uid) {
    final dynamic raw = Hive.box(_metadataBox).get(_blockedKey);
    if (raw is List) return raw.contains(uid);
    return false;
  }

  List<String> getBlockedUsers() {
    final dynamic raw = Hive.box(_metadataBox).get(_blockedKey);
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return [];
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Контакты
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> addContact(String uid, {String? displayName}) async {
    final box = Hive.box(_contactsBox);
    final contacts = _readContactsList(box);
    if (!contacts.contains(uid)) {
      contacts.add(uid);
      await box.put('list', contacts);
      _invalidateSortedContacts();
    }
    if (displayName != null) {
      await box.put('name_$uid', displayName);
    }
  }

  Future<void> removeContact(String uid) async {
    final box = Hive.box(_contactsBox);
    final contacts = _readContactsList(box);
    contacts.remove(uid);
    await box.put('list', contacts);
    _invalidateSortedContacts();
  }

  List<String> getContacts() => _readContactsList(Hive.box(_contactsBox));

  bool hasContact(String uid) => getContacts().contains(uid);

  String getContactDisplayName(String uid) {
    return Hive.box(_contactsBox).get('name_$uid', defaultValue: uid) as String;
  }

  Future<void> setContactDisplayName(String uid, String name) async {
    await Hive.box(_contactsBox).put('name_$uid', name);
    _invalidateSortedContacts();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Публичные ключи (кэш)
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> cachePublicKeys(String uid, String x25519Key, String ed25519Key) async {
    final box = Hive.box(_metadataBox);
    await box.put('x25519_$uid', x25519Key);
    await box.put('ed25519_$uid', ed25519Key);
  }

  String? getCachedX25519Key(String uid) =>
      Hive.box(_metadataBox).get('x25519_$uid') as String?;

  String? getCachedEd25519Key(String uid) =>
      Hive.box(_metadataBox).get('ed25519_$uid') as String?;

  // ──────────────────────────────────────────────────────────────────────────
  // Настройки
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> saveSetting(String key, String value) async {
    await Hive.box(_settingsBox).put(key, value);
  }

  String? getSetting(String key) =>
      Hive.box(_settingsBox).get(key) as String?;

  // ──────────────────────────────────────────────────────────────────────────
  // Реакции
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> addReaction(String messageId, String emoji, String fromUid) async {
    final box = Hive.box(_reactionsBox);
    final dynamic raw = box.get(messageId);
    final reactions = (raw is Map) ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    reactions[fromUid] = emoji;
    await box.put(messageId, reactions);
  }

  Future<void> removeReaction(String messageId, String fromUid) async {
    final box = Hive.box(_reactionsBox);
    final dynamic raw = box.get(messageId);
    if (raw is Map) {
      final reactions = Map<String, dynamic>.from(raw);
      reactions.remove(fromUid);
      await box.put(messageId, reactions);
    }
  }

  Map<String, String> getReactions(String messageId) {
    final dynamic raw = Hive.box(_reactionsBox).get(messageId);
    if (raw is Map) {
      return Map<String, String>.from(
        raw.map((k, v) => MapEntry(k.toString(), v.toString())),
      );
    }
    return {};
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Поиск по сообщениям
  // ──────────────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> searchMessages(String query, {int limit = 50}) {
    if (query.isEmpty) return [];
    final lowerQuery = query.toLowerCase();
    final results    = <Map<String, dynamic>>[];
    final box        = Hive.box(_msgBox);

    for (final chatWith in box.keys) {
      if (results.length >= limit) break;
      for (final msg in _readHistory(box, chatWith.toString())) {
        if (results.length >= limit) break;
        final text = msg['text']?.toString() ?? '';
        if (text.toLowerCase().contains(lowerQuery)) {
          results.add({...msg, 'chatWith': chatWith});
        }
      }
    }

    results.sort(
      (a, b) => _parseTime(b['time']).compareTo(_parseTime(a['time'])),
    );
    return results;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Очистка
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> deleteOldMessages(int olderThanDays) async {
    final cutoff = DateTime.now().subtract(Duration(days: olderThanDays));
    final box    = Hive.box(_msgBox);

    for (final chatWith in List.of(box.keys)) {
      await _withLock(chatWith.toString(), () async {
        final history = _readHistory(box, chatWith.toString());
        history.removeWhere((msg) => _parseTime(msg['time']).isBefore(cutoff));
        if (history.isEmpty) {
          await box.delete(chatWith);
        } else {
          await box.put(chatWith, history);
        }
      });
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Группы
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> saveGroup({
    required String groupId,
    required String groupName,
    required List<String> members,
    required String creatorUid,
  }) async {
    final box = Hive.box(_metadataBox);
    await box.put('group_$groupId', {
      'name':    groupName,
      'members': members,
      'creator': creatorUid,
    });
    await addContact(groupId, displayName: groupName);
  }

  bool isGroup(String uid)   => uid.startsWith('g_');
  bool isChannel(String uid) => uid.startsWith('ch_');

  // ── Входящие запросы ──────────────────────────────────────────────────────

  static const String _incomingRequestsKey = 'incoming_requests';

  Future<void> addIncomingRequest(String uid) async {
    await _withLock(_incomingRequestsKey, () async {
      final box      = Hive.box(_metadataBox);
      final dynamic raw = box.get(_incomingRequestsKey);
      final requests = (raw is List) ? raw.map((e) => e.toString()).toList() : <String>[];
      if (!requests.contains(uid)) {
        requests.add(uid);
        await box.put(_incomingRequestsKey, requests);
      }
    });
  }

  List<String> getIncomingRequests() {
    final dynamic raw = Hive.box(_metadataBox).get(_incomingRequestsKey);
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return [];
  }

  Future<void> acceptIncomingRequest(String uid) async {
    await removeIncomingRequest(uid);
    await addContact(uid);
  }

  Future<void> removeIncomingRequest(String uid) async {
    await _withLock(_incomingRequestsKey, () async {
      final box      = Hive.box(_metadataBox);
      final dynamic raw = box.get(_incomingRequestsKey);
      final requests = (raw is List) ? raw.map((e) => e.toString()).toList() : <String>[];
      requests.remove(uid);
      await box.put(_incomingRequestsKey, requests);
    });
  }

  String getGroupName(String groupId) {
    final box  = Hive.box(_metadataBox);
    final data = box.get('group_$groupId');
    if (data is Map) return (data['name'] as String?) ?? groupId;
    return getContactDisplayName(groupId);
  }

  List<String> getGroupMembers(String groupId) {
    final box  = Hive.box(_metadataBox);
    final data = box.get('group_$groupId');
    if (data is Map && data['members'] is List) {
      return (data['members'] as List).map((e) => e.toString()).toList();
    }
    return [];
  }

  String? getGroupCreator(String groupId) {
    final box  = Hive.box(_metadataBox);
    final data = box.get('group_$groupId');
    if (data is Map) return data['creator'] as String?;
    return null;
  }

  Future<void> saveGroupKeyBlob(String groupId, String encryptedBlob, String creatorUid) async {
    await Hive.box(_metadataBox).put('gkey_$groupId', {
      'blob':    encryptedBlob,
      'creator': creatorUid,
    });
  }

  Map<String, String>? getGroupKeyBlob(String groupId) {
    final data = Hive.box(_metadataBox).get('gkey_$groupId');
    if (data is Map) {
      return {
        'blob':    data['blob'] as String? ?? '',
        'creator': data['creator'] as String? ?? '',
      };
    }
    return null;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Полное удаление аккаунта
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> wipeAllData() async {
    _invalidateSortedContacts();
    await Hive.box(_msgBox).clear();
    await Hive.box(_contactsBox).clear();
    await Hive.box(_settingsBox).clear();
    await Hive.box(_metadataBox).clear();
    await Hive.box(_reactionsBox).clear();
    await _secureStorage.deleteAll();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Метаданные чатов
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _updateChatMetadataInternal(String chatWith, Map<String, dynamic>? msg) async {
    if (msg == null) return;
    final box = Hive.box(_metadataBox);
    await box.put('last_msg_time_$chatWith', msg['time'] ?? DateTime.now().millisecondsSinceEpoch);
    await box.put('last_msg_text_$chatWith', msg['text'] ?? '');
  }

  int getChatLastMessageTime(String chatWith) {
    return Hive.box(_metadataBox).get('last_msg_time_$chatWith', defaultValue: 0) as int;
  }

  String getChatLastMessageText(String chatWith) {
    return Hive.box(_metadataBox).get('last_msg_text_$chatWith', defaultValue: '') as String;
  }

  // Unread count
  Future<void> incrementUnread(String chatWith) async {
    final box = Hive.box(_metadataBox);
    final current = box.get('unread_$chatWith', defaultValue: 0) as int;
    await box.put('unread_$chatWith', current + 1);
  }

  Future<void> resetUnread(String chatWith) async {
    await Hive.box(_metadataBox).put('unread_$chatWith', 0);
  }

  int getUnreadCount(String chatWith) {
    return Hive.box(_metadataBox).get('unread_$chatWith', defaultValue: 0) as int;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Приватные методы
  // ──────────────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _readHistory(Box box, String chatWith) {
    final dynamic raw = box.get(chatWith);
    if (raw == null || raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<String> _readContactsList(Box box) {
    final dynamic raw = box.get('list');
    if (raw == null || raw is! List) return [];
    return raw.map((e) => e.toString()).toList();
  }

  DateTime _parseTime(dynamic raw) {
    if (raw == null) return DateTime(2000);
    if (raw is int)  return DateTime.fromMillisecondsSinceEpoch(raw);
    return DateTime.tryParse(raw.toString()) ?? DateTime(2000);
  }
}

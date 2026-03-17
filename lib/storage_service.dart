import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Сервис для локального хранения данных приложения.
///
/// КОНКУРЕНТНОСТЬ (🟡-5 FIX):
/// Hive не thread-safe для операций read-modify-write. Паттерн
///   `list = box.get(key); list.add(x); await box.put(key, list)`
/// при параллельных вызовах приводит к потере данных: второй читатель
/// видит список до первой записи, затем перезаписывает его.
///
/// Решение — per-key sequential future chain (_withLock). Для каждого
/// ключа новая операция добавляется в хвост цепочки Future'ов. Это
/// гарантирует что операции над одним chatWith выполняются строго
/// последовательно, без блокировки других чатов.
class StorageService {
  static const String _msgBox       = 'messages_history';
  static const String _contactsBox  = 'contacts_list';
  static const String _settingsBox  = 'settings';
  static const String _metadataBox  = 'metadata';
  static const String _reactionsBox = 'reactions';

  static const int MAX_MESSAGES_PER_CHAT = 1000;

  // upload_token — синглтон в памяти, обновляется при каждом uid_assigned
  // Используется во всех HTTP-запросах к /upload и /download
  static String? _uploadTokenCache;
  static String? get uploadToken => _uploadTokenCache;
  static void setUploadToken(String token) { _uploadTokenCache = token; }

  // SECURITY FIX: auth_token хранится в Keychain/Keystore, а не в Hive
  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // Сохранить auth_token в защищённом хранилище
  Future<void> saveAuthToken(String token) =>
      _secureStorage.write(key: 'auth_token', value: token);

  // Получить auth_token из защищённого хранилища
  Future<String?> getAuthToken() =>
      _secureStorage.read(key: 'auth_token');

  // Удалить auth_token (при выходе / wipe)
  Future<void> deleteAuthToken() =>
      _secureStorage.delete(key: 'auth_token');

  // Кэш пароля в Keychain/Keystore — чтобы не просить каждый раз при старте
  Future<void> cachePassword(String password) =>
      _secureStorage.write(key: 'user_password_cache', value: password);

  Future<String?> getCachedPassword() =>
      _secureStorage.read(key: 'user_password_cache');

  Future<void> deleteCachedPassword() =>
      _secureStorage.delete(key: 'user_password_cache');

  // 🟡-5 FIX: Per-key mutex через sequential Future chain.
  // Ключ — chatWith (или любой другой ключ операции).
  // Значение — последняя Future в цепочке для этого ключа.
  final _locks = <String, Future<void>>{};

  // ── Кэш отсортированного списка контактов ─────────────────────────────────
  List<String>? _sortedContactsCache;
  bool          _sortedContactsDirty = true;

  void _invalidateSortedContacts() {
    _sortedContactsDirty = true;
    _sortedContactsCache = null;
  }

  /// Ставит [fn] в очередь для [key] и возвращает Future с результатом.
  /// Ошибки в предыдущей операции не блокируют следующую (catchError на хвосте).
  Future<T> _withLock<T>(String key, Future<T> Function() fn) {
    final prev = _locks[key] ?? Future<void>.value();
    // Используем Completer чтобы поймать и пробросить ошибку из fn,
    // но при этом не сломать цепочку для следующих операций.
    final next = prev.then<T>((_) => fn());
    // Храним «тихий» хвост — без ошибок — чтобы следующая операция всегда запустилась
    _locks[key] = next.then<void>((_) {}).catchError((_) {});
    return next;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Инициализация
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    // Hive.initFlutter() идемпотентен — повторный вызов безопасен.
    // Вызывается и из main.dart, и здесь для гарантии (порядок запуска может меняться).
    await Hive.initFlutter();
    // Открываем только те боксы, которых ещё нет — isOpen guard предотвращает
    // предупреждение «box already open».
    if (!Hive.isBoxOpen(_msgBox))       await Hive.openBox(_msgBox);
    if (!Hive.isBoxOpen(_contactsBox))  await Hive.openBox(_contactsBox);
    if (!Hive.isBoxOpen(_settingsBox))  await Hive.openBox(_settingsBox);
    if (!Hive.isBoxOpen(_metadataBox))  await Hive.openBox(_metadataBox);
    if (!Hive.isBoxOpen(_reactionsBox)) await Hive.openBox(_reactionsBox);
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
      Hive.box(_metadataBox).get('online_$uid',    defaultValue: false) as bool;

  int getContactLastSeen(String uid) =>
      Hive.box(_metadataBox).get('last_seen_$uid', defaultValue: 0) as int;

  Future<void> setContactAvatar(String uid, String avatarUrl) async =>
      Hive.box(_contactsBox).put('avatar_$uid', avatarUrl);

  String? getContactAvatar(String uid) =>
      Hive.box(_contactsBox).get('avatar_$uid') as String?;

  // ──────────────────────────────────────────────────────────────────────────
  // Сообщения
  // ──────────────────────────────────────────────────────────────────────────

  /// Сохраняет сообщение в историю чата.
  ///
  /// 🟡-5 FIX: Операция выполняется под per-chat lock — параллельные вызовы
  /// для одного chatWith выстраиваются в очередь, исключая потерю данных.
  Future<void> saveMessage(String chatWith, Map<String, dynamic> msg) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);

      // Дедупликация по id — не добавляем повторно
      if (history.any((m) => m['id'] == msg['id'])) return;

      history.add(Map<String, dynamic>.from(msg));

      // Обрезаем до MAX_MESSAGES_PER_CHAT, сохраняя самые новые
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

  /// Возвращает полную историю чата как List<Map>.
  /// Только для чтения — не использовать как основу для записи без lock.
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

  /// Обновляет статус одного сообщения под lock.
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

  /// Обновляет произвольное поле одного сообщения (например filePath после перезагрузки).
  Future<void> updateMessageField(String chatWith, String messageId, String field, dynamic value) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);
      final idx = history.indexWhere((m) => m['id']?.toString() == messageId);
      if (idx != -1) {
        history[idx][field] = value;
        await box.put(chatWith, history);
      }
    });
  }

  /// Удаляет всё содержимое чата включая метаданные и реакции.
  Future<void> deleteChat(String chatWith) async {
    await _withLock(chatWith, () async {
      await Hive.box(_msgBox).delete(chatWith);
      await _deleteChatMetadata(chatWith);
      await Hive.box(_reactionsBox).delete(chatWith);
    });
  }

  /// Удаляет одно сообщение под lock.
  Future<void> deleteMessage(String chatWith, String messageId) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);
      history.removeWhere((msg) => msg['id'] == messageId);
      await box.put(chatWith, history);
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Реакции
  // ──────────────────────────────────────────────────────────────────────────

  Map<String, Set<String>> loadReactions(String chatWith) {
    final raw = Hive.box(_reactionsBox).get(chatWith);
    if (raw == null) return {};
    try {
      return (raw as Map).map((key, value) {
        final set = (value as List).map((e) => e.toString()).toSet();
        return MapEntry(key.toString(), set);
      });
    } catch (_) {
      return {};
    }
  }

  Future<void> saveReactions(
    String chatWith,
    Map<String, Set<String>> reactions,
  ) async {
    final serializable = reactions.map((k, v) => MapEntry(k, v.toList()));
    await Hive.box(_reactionsBox).put(chatWith, serializable);
  }

  Future<void> addReaction(String chatWith, String messageId, String emoji) async {
    final reactions = loadReactions(chatWith);
    reactions.putIfAbsent(messageId, () => {}).add(emoji);
    await saveReactions(chatWith, reactions);
  }

  Future<void> removeReaction(
    String chatWith,
    String messageId,
    String emoji,
  ) async {
    final reactions = loadReactions(chatWith);
    reactions[messageId]?.remove(emoji);
    if (reactions[messageId]?.isEmpty ?? false) reactions.remove(messageId);
    await saveReactions(chatWith, reactions);
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Контакты
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> addContact(String uid, {String? displayName}) async {
    await _withLock('contacts_list', () async {
      final box      = Hive.box(_contactsBox);
      final contacts = _readContactsList(box);
      if (!contacts.contains(uid)) {
        contacts.add(uid);
        await box.put('list', contacts);
      }
    });
    if (displayName != null) await setContactDisplayName(uid, displayName);
    _invalidateSortedContacts();
  }

  /// Возвращает список UID всех контактов.
  List<String> getContacts() {
    return _readContactsList(Hive.box(_contactsBox));
  }

  /// Алиас getContacts() — используется в ForwardMessage диалоге (chat_screen.dart).
  /// Возвращает список UID в порядке добавления (не по активности).
  List<String> getContactsList() => getContacts();

  /// Закреплённые вверху, затем по времени последнего сообщения.
  /// Результат кэшируется до следующего изменения данных (_invalidateSortedContacts).
  List<String> getContactsSortedByActivity() {
    if (!_sortedContactsDirty && _sortedContactsCache != null) {
      return _sortedContactsCache!;
    }
    final contacts = getContacts();
    final box      = Hive.box(_metadataBox);

    contacts.sort((a, b) {
      final aPinned = isContactPinned(a);
      final bPinned = isContactPinned(b);

      if (aPinned && !bPinned) return -1;
      if (!aPinned && bPinned) return 1;

      final aData = box.get('chat_$a');
      final bData = box.get('chat_$b');
      if (aData == null && bData == null) return 0;
      if (aData == null) return 1;
      if (bData == null) return -1;

      return _parseTime(bData['lastMessageTime'])
          .compareTo(_parseTime(aData['lastMessageTime']));
    });

    _sortedContactsCache = contacts;
    _sortedContactsDirty  = false;
    return contacts;
  }

  Future<void> removeContact(String uid) async {
    await _withLock('contacts_list', () async {
      final box      = Hive.box(_contactsBox);
      final contacts = _readContactsList(box);
      contacts.remove(uid);
      await box.put('list', contacts);
    });
    await _deleteChatMetadata(uid);
    final meta = Hive.box(_metadataBox);
    await meta.delete('pinned_$uid');
    await meta.delete('muted_$uid');
    _invalidateSortedContacts();
  }

  Future<void> setContactDisplayName(String uid, String displayName) async =>
      Hive.box(_contactsBox).put('name_$uid', displayName);

  String getContactDisplayName(String uid) =>
      Hive.box(_contactsBox).get('name_$uid', defaultValue: uid) as String;

  // ── Закрепить / открепить ─────────────────────────────────────────────────

  Future<void> setContactPinned(String uid, bool pinned) async =>
      Hive.box(_metadataBox).put('pinned_$uid', pinned);

  bool isContactPinned(String uid) =>
      Hive.box(_metadataBox).get('pinned_$uid', defaultValue: false) as bool;

  // ── Избранное ─────────────────────────────────────────────────────────────

  Future<void> setContactFavorite(String uid, bool fav) async =>
      Hive.box(_metadataBox).put('fav_$uid', fav);

  bool isContactFavorite(String uid) =>
      Hive.box(_metadataBox).get('fav_$uid', defaultValue: false) as bool;

  // ── Заглушить / включить ──────────────────────────────────────────────────

  Future<void> setContactMuted(String uid, bool muted) async =>
      Hive.box(_metadataBox).put('muted_$uid', muted);

  bool isContactMuted(String uid) =>
      Hive.box(_metadataBox).get('muted_$uid', defaultValue: false) as bool;

  // ── Очистить историю (контакт остаётся в списке) ──────────────────────────

  Future<void> clearChatHistory(String chatWith) async {
    await _withLock(chatWith, () async {
      await Hive.box(_msgBox).delete(chatWith);
      await Hive.box(_reactionsBox).delete(chatWith);
      await Hive.box(_metadataBox).delete('chat_$chatWith');
    });
  }

  // ── Непрочитанные ─────────────────────────────────────────────────────────

  int getUnreadCount(String chatWith) {
    return getHistory(chatWith)
        .where((m) => m['isMe'] == false && m['status'] != 'read')
        .length;
  }

  int getTotalUnreadCount() {
    int total = 0;
    for (final uid in getContacts()) total += getUnreadCount(uid);
    return total;
  }

  /// Помечает все входящие сообщения в чате как прочитанные.
  /// 🟡-5 FIX: Выполняется под per-chat lock.
  Future<void> markAllAsRead(String chatWith) {
    return _withLock(chatWith, () async {
      final box     = Hive.box(_msgBox);
      final history = _readHistory(box, chatWith);

      bool updated = false;
      for (final msg in history) {
        if (msg['isMe'] == false && msg['status'] != 'read') {
          msg['status'] = 'read';
          updated = true;
        }
      }

      if (updated) {
        await box.put(chatWith, history);
        await _updateChatMetadataInternal(chatWith, null);
      }
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Метаданные чатов
  // ──────────────────────────────────────────────────────────────────────────

  /// Внутренний метод — вызывается ТОЛЬКО внутри блока _withLock.
  /// Не вызывать снаружи напрямую.
  Future<void> _updateChatMetadataInternal(
    String chatWith,
    Map<String, dynamic>? lastMessage,
  ) async {
    final box      = Hive.box(_metadataBox);
    final metadata = Map<String, dynamic>.from(
      box.get('chat_$chatWith', defaultValue: {}) as Map,
    );

    if (lastMessage != null) {
      metadata['lastMessageText'] = lastMessage['text'];
      final rawTime = lastMessage['time'];
      metadata['lastMessageTime'] = rawTime is int
          ? DateTime.fromMillisecondsSinceEpoch(rawTime).toIso8601String()
          : rawTime;
      metadata['lastMessageIsMe'] = lastMessage['isMe'];
    }

    // getUnreadCount читает историю — вызываем _readHistory напрямую
    // чтобы не захватывать lock повторно (мы уже под ним).
    final history = _readHistory(Hive.box(_msgBox), chatWith);
    metadata['unreadCount']   =
        history.where((m) => m['isMe'] == false && m['status'] != 'read').length;
    metadata['totalMessages'] = history.length;

    await box.put('chat_$chatWith', metadata);
  }

  Future<void> _deleteChatMetadata(String chatWith) async =>
      Hive.box(_metadataBox).delete('chat_$chatWith');

  Map<String, dynamic> getChatMetadata(String chatWith) {
    return Map<String, dynamic>.from(
      Hive.box(_metadataBox).get('chat_$chatWith', defaultValue: {}) as Map,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Настройки
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> saveSetting(String key, dynamic value) async =>
      Hive.box(_settingsBox).put(key, value);

  dynamic getSetting(String key, {dynamic defaultValue}) =>
      Hive.box(_settingsBox).get(key, defaultValue: defaultValue);

  Future<void> deleteSetting(String key) async =>
      Hive.box(_settingsBox).delete(key);

  // ── Кэш публичных ключей контактов ────────────────────────────────────────

  Future<void> cachePublicKeys(
    String uid,
    String x25519Key,
    String ed25519Key,
  ) async {
    await saveSetting('cached_x25519_$uid',    x25519Key);
    await saveSetting('cached_ed25519_$uid',   ed25519Key);
    await saveSetting('cached_keys_time_$uid', DateTime.now().toIso8601String());
  }

  String? getCachedX25519Key(String uid)  => getSetting('cached_x25519_$uid')  as String?;
  String? getCachedEd25519Key(String uid) => getSetting('cached_ed25519_$uid') as String?;

  bool hasCachedKeys(String uid) =>
      getCachedX25519Key(uid) != null && getCachedEd25519Key(uid) != null;

  Future<void> clearCachedKeys(String uid) async {
    await deleteSetting('cached_x25519_$uid');
    await deleteSetting('cached_ed25519_$uid');
    await deleteSetting('cached_keys_time_$uid');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Поиск
  // ──────────────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> searchMessages(String query, {int limit = 100}) {
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
  // Группа хранится как контакт с uid = 'g_XXXXXX'.
  // Метаданные (имя, участники) — в _metadataBox под ключом 'group_g_XXXXXX'.
  // ──────────────────────────────────────────────────────────────────────────

  /// Создаёт/обновляет группу локально.
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
    // Добавляем в список чатов как обычный контакт
    await addContact(groupId, displayName: groupName);
  }

  /// Возвращает true если uid — группа.
  bool isGroup(String uid) => uid.startsWith('g_');

  /// Возвращает true если uid — канал.
  bool isChannel(String uid) => uid.startsWith('ch_');

  // ── Входящие запросы на переписку (SECURITY FIX) ──────────────────────────
  // Вместо автоматического добавления незнакомцев в контакты —
  // сохраняем их в отдельную очередь. Пользователь подтверждает вручную.

  static const String _incomingRequestsKey = 'incoming_requests';

  /// Добавляет uid в очередь входящих запросов (если его ещё нет в контактах).
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

  /// Возвращает список UID, ожидающих подтверждения.
  List<String> getIncomingRequests() {
    final dynamic raw = Hive.box(_metadataBox).get(_incomingRequestsKey);
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return [];
  }

  /// Принять запрос — переносит uid из очереди в контакты.
  Future<void> acceptIncomingRequest(String uid) async {
    await removeIncomingRequest(uid);
    await addContact(uid);
  }

  /// Отклонить запрос — удаляет из очереди.
  Future<void> removeIncomingRequest(String uid) async {
    await _withLock(_incomingRequestsKey, () async {
      final box      = Hive.box(_metadataBox);
      final dynamic raw = box.get(_incomingRequestsKey);
      final requests = (raw is List) ? raw.map((e) => e.toString()).toList() : <String>[];
      requests.remove(uid);
      await box.put(_incomingRequestsKey, requests);
    });
  }

  /// Возвращает имя группы (или uid если не найдено).
  String getGroupName(String groupId) {
    final box  = Hive.box(_metadataBox);
    final data = box.get('group_$groupId');
    if (data is Map) return (data['name'] as String?) ?? groupId;
    return getContactDisplayName(groupId);
  }

  /// Возвращает список участников группы (без самого пользователя).
  List<String> getGroupMembers(String groupId) {
    final box  = Hive.box(_metadataBox);
    final data = box.get('group_$groupId');
    if (data is Map && data['members'] is List) {
      return (data['members'] as List).map((e) => e.toString()).toList();
    }
    return [];
  }

  /// Возвращает UID создателя группы.
  String? getGroupCreator(String groupId) {
    final box  = Hive.box(_metadataBox);
    final data = box.get('group_$groupId');
    if (data is Map) return data['creator'] as String?;
    return null;
  }

  /// Сохраняет зашифрованный blob группового ключа (то что вернул сервер).
  /// Хранится локально чтобы не запрашивать при каждом открытии чата.
  Future<void> saveGroupKeyBlob(String groupId, String encryptedBlob, String creatorUid) async {
    await Hive.box(_metadataBox).put('gkey_$groupId', {
      'blob':    encryptedBlob,
      'creator': creatorUid,
    });
  }

  /// Возвращает {blob, creator} или null если ключ не сохранён.
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

  /// Удаляет все локальные данные приложения: сообщения, контакты, ключи, настройки.
  /// Вызывается при удалении аккаунта. После этого приложение перезапускается.
  Future<void> wipeAllData() async {
    _invalidateSortedContacts();
    await Hive.box(_msgBox).clear();
    await Hive.box(_contactsBox).clear();
    await Hive.box(_settingsBox).clear();
    await Hive.box(_metadataBox).clear();
    await Hive.box(_reactionsBox).clear();
    await _secureStorage.deleteAll(); // SECURITY FIX: удаляем и токен из Keystore
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Приватные вспомогательные методы
  // ──────────────────────────────────────────────────────────────────────────

  /// Читает историю чата из бокса и приводит к List<Map<String, dynamic>>.
  /// Не async — только синхронное чтение, запись всегда под lock.
  ///
  /// Намеренно не передаём defaultValue — иначе Dart inferит тип raw как
  /// List<dynamic> и `raw is! List` становится unnecessary_type_check.
  List<Map<String, dynamic>> _readHistory(Box box, String chatWith) {
    final dynamic raw = box.get(chatWith);
    if (raw == null || raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Читает список контактов из бокса как List<String>.
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

  // ═══════════════════════════════════════════════════════════════════════════
  // Блокировка пользователей
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> blockUser(String uid) async {
    final box = Hive.box(_metadataBox);
    final blocked = _getBlockedSet(box);
    blocked.add(uid);
    await box.put('blocked_users', blocked.toList());
  }

  Future<void> unblockUser(String uid) async {
    final box = Hive.box(_metadataBox);
    final blocked = _getBlockedSet(box);
    blocked.remove(uid);
    await box.put('blocked_users', blocked.toList());
  }

  bool isBlocked(String uid) => _getBlockedSet(Hive.box(_metadataBox)).contains(uid);

  List<String> getBlockedUsers() => _getBlockedSet(Hive.box(_metadataBox)).toList();

  Set<String> _getBlockedSet(Box box) {
    final raw = box.get('blocked_users');
    if (raw == null || raw is! List) return {};
    return raw.map((e) => e.toString()).toSet();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Непрочитанные сообщения
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> incrementUnreadCount(String chatWith) async {
    final box = Hive.box(_metadataBox);
    final current = box.get('unread_$chatWith', defaultValue: 0) as int;
    await box.put('unread_$chatWith', current + 1);
  }

  Future<void> resetUnreadCount(String chatWith) async =>
      Hive.box(_metadataBox).put('unread_$chatWith', 0);

  // ═══════════════════════════════════════════════════════════════════════════
  // Disappearing messages (TTL per chat)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> setMessageTtl(String chatWith, int seconds) async =>
      Hive.box(_metadataBox).put('msg_ttl_$chatWith', seconds);

  int getMessageTtl(String chatWith) =>
      Hive.box(_metadataBox).get('msg_ttl_$chatWith', defaultValue: 0) as int;

  // ═══════════════════════════════════════════════════════════════════════════
  // Медиагалерея — все медиафайлы из истории чата
  // ═══════════════════════════════════════════════════════════════════════════

  List<Map<String, dynamic>> getMediaMessages(String chatWith) {
    final box = Hive.box(_msgBox);
    final history = _readHistory(box, chatWith);
    return history.where((m) {
      final type = m['type'] as String? ?? 'text';
      return type == 'image' || type == 'video_gallery' || type == 'video_note';
    }).toList();
  }
}

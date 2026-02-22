import 'package:hive_flutter/hive_flutter.dart';
import 'dart:convert';

/// Сервис для локального хранения данных приложения
class StorageService {
  static const String _msgBox       = "messages_history";
  static const String _contactsBox  = "contacts_list";
  static const String _settingsBox  = "settings";
  static const String _metadataBox  = "metadata";
  static const String _reactionsBox = "reactions";

  static const int MAX_MESSAGES_PER_CHAT = 1000;

  Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox(_msgBox);
    await Hive.openBox(_contactsBox);
    await Hive.openBox(_settingsBox);
    await Hive.openBox(_metadataBox);
    await Hive.openBox(_reactionsBox);
  }

  // ============================================================
  // СООБЩЕНИЯ 
  // ============================================================

  Future<void> saveMessage(String chatWith, Map<String, dynamic> msg) async {
    var box = Hive.box(_msgBox);
    List history = box.get(chatWith, defaultValue: []);
    history = history.whereType<Map>().toList();

    bool exists = history.any((m) => m['id'] == msg['id']);
    if (exists) return;

    history.add(msg);

    if (history.length > MAX_MESSAGES_PER_CHAT) {
      history = history.sublist(history.length - MAX_MESSAGES_PER_CHAT);
    }

    await box.put(chatWith, history);
    await _updateChatMetadata(chatWith, msg);
  }

  List getHistory(String chatWith) {
    final data = Hive.box(_msgBox).get(chatWith, defaultValue: []);
    return (data is List) ? data : [];
  }

  List getRecentMessages(String chatWith, {int limit = 50}) {
    final all = getHistory(chatWith);
    if (all.isEmpty) return [];
    if (all.length <= limit) return all;
    return all.sublist(all.length - limit);
  }

  List getOlderMessages(String chatWith, int beforeIndex, {int limit = 50}) {
    final all = getHistory(chatWith);
    if (beforeIndex <= 0 || all.isEmpty) return [];
    final start = (beforeIndex - limit).clamp(0, beforeIndex);
    return all.sublist(start, beforeIndex);
  }

  Future<void> updateMessageStatus(
    String chatWith,
    String messageId,
    String status,
  ) async {
    var box = Hive.box(_msgBox);
    List history = getHistory(chatWith)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    bool updated = false;
    for (var msg in history) {
      if (msg['id'] == messageId) {
        msg['status'] = status;
        updated = true;
        break;
      }
    }

    if (updated) {
      await box.put(chatWith, history);
      await _updateChatMetadata(chatWith, null);
    }
  }

  Future<void> deleteChat(String chatWith) async {
    await Hive.box(_msgBox).delete(chatWith);
    await _deleteChatMetadata(chatWith);
    await Hive.box(_reactionsBox).delete(chatWith);
  }

  Future<void> deleteMessage(String chatWith, String messageId) async {
    var box = Hive.box(_msgBox);
    List history = getHistory(chatWith);
    history.removeWhere((msg) => msg is Map && msg['id'] == messageId);
    await box.put(chatWith, history);
  }

  // ============================================================
  // РЕАКЦИИ (персистентность)
  // ============================================================

  /// Загружает реакции для чата: messageId -> Set<emoji>
  Map<String, Set<String>> loadReactions(String chatWith) {
    final box = Hive.box(_reactionsBox);
    final raw = box.get(chatWith);
    if (raw == null) return {};

    try {
      final Map<dynamic, dynamic> stored = raw as Map;
      return stored.map((key, value) {
        final set = (value as List).map((e) => e.toString()).toSet();
        return MapEntry(key.toString(), set);
      });
    } catch (_) {
      return {};
    }
  }

  /// Сохраняет все реакции чата
  Future<void> saveReactions(
      String chatWith, Map<String, Set<String>> reactions) async {
    final box = Hive.box(_reactionsBox);
    final serializable = reactions.map(
      (key, value) => MapEntry(key, value.toList()),
    );
    await box.put(chatWith, serializable);
  }

  /// Добавляет одну реакцию и сохраняет
  Future<void> addReaction(
      String chatWith, String messageId, String emoji) async {
    final reactions = loadReactions(chatWith);
    reactions.putIfAbsent(messageId, () => {});
    reactions[messageId]!.add(emoji);
    await saveReactions(chatWith, reactions);
  }

  /// Удаляет одну реакцию и сохраняет
  Future<void> removeReaction(
      String chatWith, String messageId, String emoji) async {
    final reactions = loadReactions(chatWith);
    reactions[messageId]?.remove(emoji);
    if (reactions[messageId]?.isEmpty ?? false) {
      reactions.remove(messageId);
    }
    await saveReactions(chatWith, reactions);
  }

  // ============================================================
  // КОНТАКТЫ
  // ============================================================

  Future<void> addContact(String uid, {String? displayName}) async {
    var box = Hive.box(_contactsBox);
    List contacts = box.get('list', defaultValue: []);
    if (!contacts.contains(uid)) {
      contacts.add(uid);
      await box.put('list', contacts);
    }
    if (displayName != null) {
      await setContactDisplayName(uid, displayName);
    }
  }

  List<String> getContacts() {
    List raw = Hive.box(_contactsBox).get('list', defaultValue: []);
    return raw.map((e) => e.toString()).toList();
  }

  List<String> getContactsSortedByActivity() {
    final contacts = getContacts();
    final metadata = Hive.box(_metadataBox);

    contacts.sort((a, b) {
      final aData = metadata.get('chat_$a');
      final bData = metadata.get('chat_$b');

      if (aData == null && bData == null) return 0;
      if (aData == null) return 1;
      if (bData == null) return -1;

      final aTime = _parseTime(aData['lastMessageTime']);
      final bTime = _parseTime(bData['lastMessageTime']);
      return bTime.compareTo(aTime);
    });

    return contacts;
  }

  Future<void> removeContact(String uid) async {
    var box = Hive.box(_contactsBox);
    List contacts = box.get('list', defaultValue: []);
    contacts.remove(uid);
    await box.put('list', contacts);
    await _deleteChatMetadata(uid);
  }

  Future<void> setContactDisplayName(String uid, String displayName) async {
    await Hive.box(_contactsBox).put('name_$uid', displayName);
  }

  String getContactDisplayName(String uid) {
    return Hive.box(_contactsBox).get('name_$uid', defaultValue: uid);
  }

  // ============================================================
  // НЕПРОЧИТАННЫЕ СООБЩЕНИЯ
  // ============================================================

  int getUnreadCount(String chatWith) {
    List history = getHistory(chatWith);
    return history
        .where((msg) =>
            msg is Map &&
            msg['isMe'] == false &&
            msg['status'] != 'read')
        .length;
  }

  int getTotalUnreadCount() {
    int total = 0;
    for (final contact in getContacts()) {
      total += getUnreadCount(contact);
    }
    return total;
  }

  Future<void> markAllAsRead(String chatWith) async {
    var box = Hive.box(_msgBox);
    List history = getHistory(chatWith)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    bool updated = false;
    for (var msg in history) {
      if (msg['isMe'] == false && msg['status'] != 'read') {
        msg['status'] = 'read';
        updated = true;
      }
    }

    if (updated) {
      await box.put(chatWith, history);
      await _updateChatMetadata(chatWith, null);
    }
  }

  // ============================================================
  // МЕТАДАННЫЕ ЧАТОВ
  // ============================================================

  Future<void> _updateChatMetadata(
    String chatWith,
    Map<String, dynamic>? lastMessage,
  ) async {
    var box = Hive.box(_metadataBox);
    var metadata = Map<String, dynamic>.from(
        box.get('chat_$chatWith', defaultValue: {}));

    if (lastMessage != null) {
      metadata['lastMessageText'] = lastMessage['text'];
      // Нормализуем время: и int (ms), и ISO-строка → ISO-строка
      final rawTime = lastMessage['time'];
      if (rawTime is int) {
        metadata['lastMessageTime'] =
            DateTime.fromMillisecondsSinceEpoch(rawTime).toIso8601String();
      } else {
        metadata['lastMessageTime'] = rawTime;
      }
      metadata['lastMessageIsMe'] = lastMessage['isMe'];
    }

    metadata['unreadCount']    = getUnreadCount(chatWith);
    metadata['totalMessages']  = getHistory(chatWith).length;

    await box.put('chat_$chatWith', metadata);
  }

  Future<void> _deleteChatMetadata(String chatWith) async {
    await Hive.box(_metadataBox).delete('chat_$chatWith');
  }

  Map<String, dynamic> getChatMetadata(String chatWith) {
    final data = Hive.box(_metadataBox).get('chat_$chatWith', defaultValue: {});
    return Map<String, dynamic>.from(data);
  }

  // ============================================================
  // НАСТРОЙКИ
  // ============================================================

  Future<void> saveSetting(String key, dynamic value) async {
    await Hive.box(_settingsBox).put(key, value);
  }

  dynamic getSetting(String key, {dynamic defaultValue}) {
    return Hive.box(_settingsBox).get(key, defaultValue: defaultValue);
  }

  Future<void> deleteSetting(String key) async {
    await Hive.box(_settingsBox).delete(key);
  }

  // ============================================================
  // ПОИСК
  // ============================================================

  List<Map<String, dynamic>> searchMessages(String query, {int limit = 100}) {
    if (query.isEmpty) return [];
    var box = Hive.box(_msgBox);
    List<Map<String, dynamic>> results = [];
    final lowerQuery = query.toLowerCase();

    for (var chatWith in box.keys) {
      if (results.length >= limit) break;
      List history = getHistory(chatWith.toString());
      for (var msg in history) {
        if (results.length >= limit) break;
        if (msg is Map &&
            msg['text'] != null &&
            msg['text'].toString().toLowerCase().contains(lowerQuery)) {
          results.add({
            ...Map<String, dynamic>.from(msg),
            'chatWith': chatWith,
          });
        }
      }
    }

    results.sort((a, b) {
      final aTime = _parseTime(a['time']);
      final bTime = _parseTime(b['time']);
      return bTime.compareTo(aTime);
    });

    return results;
  }

  List<Map<String, dynamic>> searchInChat(String chatWith, String query) {
    if (query.isEmpty) return [];
    final history = getHistory(chatWith);
    final lowerQuery = query.toLowerCase();

    return history
        .where((msg) =>
            msg is Map &&
            msg['text'] != null &&
            msg['text'].toString().toLowerCase().contains(lowerQuery))
        .map((msg) => Map<String, dynamic>.from(msg))
        .toList();
  }

  // ============================================================
  // ЭКСПОРТ
  // ============================================================

  String exportChat(String chatWith) {
    List history = getHistory(chatWith);
    StringBuffer sb = StringBuffer();
    final displayName = getContactDisplayName(chatWith);
    sb.writeln("=== Chat with $displayName ($chatWith) ===");
    sb.writeln("Exported: ${DateTime.now().toIso8601String()}");
    sb.writeln("Total messages: ${history.length}");
    sb.writeln("");

    for (var msg in history) {
      if (msg is Map) {
        String sender = msg['isMe'] == true ? 'Me' : displayName;
        String text   = msg['text'] ?? '';

        final dt = _parseTime(msg['time']);
        final time =
            "${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}";

        sb.write("[$time] $sender: $text");
        if (msg['isMe'] == true && (msg['status'] ?? '').isNotEmpty) {
          sb.write(" (${msg['status']})");
        }
        sb.writeln();
      }
    }

    return sb.toString();
  }

  /// Экспортирует все чаты в текстовый формат
  String exportAllChats() {
    StringBuffer sb = StringBuffer();
    sb.writeln("=== DeepDrift Messenger - Full Export ===");
    sb.writeln("Exported: ${DateTime.now().toIso8601String()}");
    sb.writeln("");

    for (final contact in getContacts()) {
      sb.writeln(exportChat(contact));
      sb.writeln("");
      sb.writeln("=" * 80);
      sb.writeln("");
    }

    return sb.toString();
  }

  String exportChatAsJson(String chatWith) {
    final history = getHistory(chatWith);
    final displayName = getContactDisplayName(chatWith);
    final export = {
      'chatWith':     chatWith,
      'displayName':  displayName,
      'exportedAt':   DateTime.now().toIso8601String(),
      'messageCount': history.length,
      'messages':     history,
    };
    return jsonEncode(export);
  }

  // ============================================================
  // СТАТИСТИКА
  // ============================================================

  Map<String, dynamic> getChatStats(String chatWith) {
    final history = getHistory(chatWith);
    int myMessages    = 0;
    int theirMessages = 0;
    int totalChars    = 0;
    DateTime? firstMessageTime;
    DateTime? lastMessageTime;

    for (var msg in history) {
      if (msg is Map) {
        if (msg['isMe'] == true) {
          myMessages++;
        } else {
          theirMessages++;
        }
        if (msg['text'] != null) {
          totalChars += msg['text'].toString().length;
        }
        final t = _parseTime(msg['time']);
        if (t.year > 2000) {
          firstMessageTime ??= t;
          lastMessageTime = t;
        }
      }
    }

    return {
      'totalMessages':         history.length,
      'myMessages':            myMessages,
      'theirMessages':         theirMessages,
      'averageMessageLength':  history.isNotEmpty ? totalChars ~/ history.length : 0,
      'firstMessageTime':      firstMessageTime?.toIso8601String(),
      'lastMessageTime':       lastMessageTime?.toIso8601String(),
    };
  }

  // ============================================================
  // ОЧИСТКА
  // ============================================================

  Future<void> clearAllData() async {
    await Hive.box(_msgBox).clear();
    await Hive.box(_contactsBox).clear();
    await Hive.box(_settingsBox).clear();
    await Hive.box(_metadataBox).clear();
    await Hive.box(_reactionsBox).clear();
  }

  Future<void> deleteOldMessages(int olderThanDays) async {
    final cutoffDate = DateTime.now().subtract(Duration(days: olderThanDays));
    var box = Hive.box(_msgBox);

    for (var chatWith in box.keys) {
      List history =
          getHistory(chatWith.toString()).whereType<Map>().toList();

      history.removeWhere((msg) {
        final t = _parseTime(msg['time']);
        return t.isBefore(cutoffDate);
      });

      if (history.isEmpty) {
        await box.delete(chatWith);
      } else {
        await box.put(chatWith, history);
      }
    }
  }

  // ============================================================
  // ВНУТРЕННИЕ УТИЛИТЫ
  // ============================================================

  /// Парсит время из int (ms) или ISO-строки в DateTime.
  DateTime _parseTime(dynamic raw) {
    if (raw == null) return DateTime(2000);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return DateTime.tryParse(raw.toString()) ?? DateTime(2000);
  }
}

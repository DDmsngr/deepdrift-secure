import 'package:shared_preferences/shared_preferences.dart';

class IdentityService {
  // Ключи для хранения данных в памяти телефона
  static const String _uidKey = "user_fixed_id";
  static const String _contactsKey = "user_contacts";

  // --- МЕТОДЫ ДЛЯ UID (Которые требовал компилятор) ---

  // 1. Проверить, есть ли сохраненный ID (возвращает null, если нет)
  Future<String?> getStoredUID() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_uidKey);
  }

  // 2. Сохранить новый ID навсегда
  Future<void> saveUID(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uidKey, uid);
  }

  // --- МЕТОДЫ ДЛЯ КОНТАКТОВ (Для списка чатов) ---

  // 3. Сохранить контакт друга
  Future<void> saveContact(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> contacts = prefs.getStringList(_contactsKey) ?? [];
    
    // Добавляем, если такого еще нет
    if (!contacts.contains(uid)) {
      contacts.add(uid);
      await prefs.setStringList(_contactsKey, contacts);
    }
  }

  // 4. Получить список всех контактов
  Future<List<String>> getContacts() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_contactsKey) ?? [];
  }

  // 5. Очистка (для отладки)
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_uidKey);
    await prefs.remove(_contactsKey);
  }
}

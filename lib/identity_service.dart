import 'package:shared_preferences/shared_preferences.dart';

class IdentityService {
  static const String _uidKey      = 'user_fixed_id';
  static const String _contactsKey = 'user_contacts';

  Future<String?> getStoredUID() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_uidKey);
  }

  Future<void> saveUID(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uidKey, uid);
  }

  Future<void> saveContact(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final contacts = prefs.getStringList(_contactsKey) ?? [];
    if (!contacts.contains(uid)) {
      contacts.add(uid);
      await prefs.setStringList(_contactsKey, contacts);
    }
  }

  Future<List<String>> getContacts() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_contactsKey) ?? [];
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_uidKey);
    await prefs.remove(_contactsKey);
  }

  /// Полное удаление аккаунта — то же что clearAll(), явный алиас для читаемости.
  Future<void> deleteUID() async => clearAll();
}

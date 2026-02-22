import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';

class IdentityService {
  static const String _uidKey = "user_uin";
  static const String _contactsKey = "user_contacts";

  // Получить или создать постоянный UID
  Future<String> getMyUID() async {
    final prefs = await SharedPreferences.getInstance();
    String? uid = prefs.getString(_uidKey);
    
    if (uid == null) {
      uid = (100000 + Random().nextInt(900000)).toString();
      await prefs.setString(_uidKey, uid);
    }
    return uid;
  }

  // Сохранить контакт (список чатов)
  Future<void> saveContact(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> contacts = prefs.getStringList(_contactsKey) ?? [];
    if (!contacts.contains(uid)) {
      contacts.add(uid);
      await prefs.setStringList(_contactsKey, contacts);
    }
  }

  Future<List<String>> getContacts() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_contactsKey) ?? [];
  }
}

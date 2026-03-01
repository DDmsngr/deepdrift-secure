import 'package:flutter/foundation.dart';
import '../socket_service.dart';
import '../storage_service.dart';
import '../crypto_service.dart';

// ─── AppProviders ─────────────────────────────────────────────────────────────
//
// Тонкие обёртки над существующими синглтонами (SocketService, StorageService)
// и единственным экземпляром SecureCipher.
//
// ЗАЧЕМ:
//   • Виджеты получают сервисы через context.read<T>() / context.watch<T>()
//     вместо прямого SocketService() / StorageService() — зависимость явная
//     и заменяемая при тестировании.
//   • ChangeNotifier позволяет при необходимости реактивно перестраивать UI
//     (например, обновить список чатов после получения события сокета).
//   • Никакой логики сервисов не переписывается — только делегирование.
//
// ИСПОЛЬЗОВАНИЕ:
//   // Получить без подписки (read — не вызывает rebuild):
//   context.read<SocketProvider>().service.sendMessage(...)
//
//   // Получить с подпиской (watch — вызывает rebuild при notifyListeners):
//   context.watch<HomeProvider>().chats
//

// ── SocketProvider ────────────────────────────────────────────────────────────
class SocketProvider extends ChangeNotifier {
  final SocketService _service = SocketService(); // singleton

  SocketService get service => _service;

  /// Прокси-методы для удобства — виджет пишет
  /// context.read<SocketProvider>().sendMessage(...)
  /// вместо context.read<SocketProvider>().service.sendMessage(...)
  void sendTypingIndicator(String targetUid, bool isTyping) =>
      _service.sendTypingIndicator(targetUid, isTyping);

  void requestPublicKey(String targetUid) =>
      _service.requestPublicKey(targetUid);

  void getProfile(String targetUid) =>
      _service.getProfile(targetUid);

  Stream<Map<String, dynamic>> get messageStream => _service.messages;
}

// ── StorageProvider ───────────────────────────────────────────────────────────
class StorageProvider extends ChangeNotifier {
  final StorageService _service = StorageService(); // singleton

  StorageService get service => _service;

  /// Уведомляет подписчиков после записи, чтобы списки автоматически обновлялись.
  Future<void> saveMessage(String chatWith, Map<String, dynamic> msg) async {
    await _service.saveMessage(chatWith, msg);
    notifyListeners();
  }

  List<Map<String, dynamic>> getRecentMessages(String chatWith, {int limit = 50}) =>
      _service.getRecentMessages(chatWith, limit: limit);
}

// ── CipherProvider ────────────────────────────────────────────────────────────
// SecureCipher не является синглтоном, поэтому он инициализируется один раз
// в main.dart и помещается в дерево через CipherProvider.
class CipherProvider extends ChangeNotifier {
  final SecureCipher _cipher;
  CipherProvider(this._cipher);

  SecureCipher get cipher => _cipher;
}

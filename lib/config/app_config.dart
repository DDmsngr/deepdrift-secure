/// Конфигурация приложения.
/// Все URL и константы — в одном месте.
class AppConfig {
  AppConfig._();

  // ─── Сервер ──────────────────────────────────────────────────────────────
  /// WebSocket URL сервера.
  /// В продакшене можно менять через environment или remote config.
  static const String wsUrl = 'wss://deepdrift-backend.onrender.com/ws';

  /// HTTP URL для загрузки/скачивания файлов.
  static const String httpBaseUrl = 'https://deepdrift-backend.onrender.com';
  static const String uploadUrl   = '$httpBaseUrl/upload';
  static String downloadUrl(String fileId) => '$httpBaseUrl/download/$fileId';

  // ─── Хранилище ───────────────────────────────────────────────────────────
  /// Версия формата хранилища. Увеличивать при миграциях.
  static const int storageVersion = 2;

  /// Максимум сообщений в истории одного чата.
  static const int maxMessagesPerChat = 1000;

  // ─── Крипто ──────────────────────────────────────────────────────────────
  /// Версия формата шифрования ключей.
  /// 0x01 = legacy (без Argon2-нонса)
  /// 0x02 = текущий (Argon2-нонс + ChaCha20)
  static const int cryptoFormatVersion = 0x02;

  // ─── WebSocket ───────────────────────────────────────────────────────────
  static const int maxReconnectAttempts = 50;
  static const Duration reconnectBaseDelay = Duration(seconds: 4);
  static const Duration pingInterval       = Duration(seconds: 10);
  static const Duration connectionTimeout  = Duration(seconds: 20);
  static const Duration pendingMsgTimeout  = Duration(seconds: 30);

  // ─── Disappearing messages ───────────────────────────────────────────────
  /// Доступные варианты TTL для исчезающих сообщений (в секундах).
  static const List<int> disappearingMessageOptions = [
    0,       // отключено
    30,      // 30 секунд
    300,     // 5 минут
    3600,    // 1 час
    86400,   // 1 день
    604800,  // 1 неделя
  ];

  static String formatTtl(int seconds) {
    if (seconds == 0) return 'Выкл';
    if (seconds < 60) return '${seconds}с';
    if (seconds < 3600) return '${seconds ~/ 60}м';
    if (seconds < 86400) return '${seconds ~/ 3600}ч';
    return '${seconds ~/ 86400}д';
  }
}

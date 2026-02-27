import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ФОРМАТ ХРАНЕНИЯ ЗАШИФРОВАННЫХ КЛЮЧЕЙ (v2):
//
//   base64( argon2_nonce[16] | chacha20_nonce[12] | ciphertext | poly1305_mac[16] )
//
// Первые 16 байт — случайный KDF-нонс для Argon2id (уникален при каждом экспорте/
// смене пароля). Остальное — стандартный ChaCha20-Poly1305 SecretBox.
//
// ВАЖНО: при изменении формата увеличивать _kStorageVersion и добавлять миграцию.
// ─────────────────────────────────────────────────────────────────────────────

/// Сервис E2E-шифрования: X25519 ECDH + ChaCha20-Poly1305 + Ed25519
class SecureCipher {
  // ── Алгоритмы ──────────────────────────────────────────────────────────────
  final _algo   = Chacha20.poly1305Aead();
  final _x25519 = X25519();
  final _ed25519 = Ed25519();

  // ── Ключи текущего пользователя ────────────────────────────────────────────
  SimpleKeyPair? _myX25519KeyPair;
  SimpleKeyPair? _myEd25519KeyPair;

  // ── Кэши контактов ─────────────────────────────────────────────────────────
  final Map<String, SecretKey>      _sharedSecrets      = {};
  final Map<String, SimplePublicKey> _contactPublicKeys  = {};
  final Map<String, SimplePublicKey> _contactSignKeys    = {};

  bool _isInitialized = false;

  // ── Константы формата ──────────────────────────────────────────────────────
  /// Длина Argon2 KDF-нонса, который сохраняется перед шифртекстом.
  static const int _kArgon2NonceLength = 16;

  // ═══════════════════════════════════════════════════════════════════════════
  // ИНИЦИАЛИЗАЦИЯ
  // ═══════════════════════════════════════════════════════════════════════════

  /// Генерирует случайную соль для хранения (используется при первой регистрации).
  static String generateSalt() {
    final random = Random.secure();
    final saltBytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Encode(saltBytes);
  }

  /// Инициализирует шифровальщик.
  /// Если [encryptedX25519Key] и [encryptedEd25519Key] переданы — восстанавливает
  /// ключи из зашифрованного хранилища. Иначе генерирует новую пару ключей.
  Future<void> init(
    String password,
    String userSalt, {
    String? encryptedX25519Key,
    String? encryptedEd25519Key,
  }) async {
    try {
      if (encryptedX25519Key != null && encryptedEd25519Key != null) {
        await _importBothKeys(encryptedX25519Key, encryptedEd25519Key, password);
        debugLog('✅ [Crypto] Cipher initialized with restored key pairs');
      } else {
        _myX25519KeyPair  = await _x25519.newKeyPair();
        _myEd25519KeyPair = await _ed25519.newKeyPair();
        _isInitialized    = true;
        debugLog('✅ [Crypto] Cipher initialized with new key pairs');
      }
    } catch (e) {
      debugLog('❌ [Crypto] Initialization error: $e');
      throw CryptoException('Failed to initialize cipher: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ЭКСПОРТ / ИМПОРТ КЛЮЧЕЙ (защита паролем)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Шифрует приватные ключи паролем и возвращает base64-строки для хранения.
  ///
  /// Формат каждой строки:
  ///   base64( random_argon2_nonce[16] | chacha_nonce[12] | ciphertext | mac[16] )
  ///
  /// Argon2-нонс генерируется случайно при каждом вызове — это значит, что
  /// два пользователя с одинаковым паролем получат разные ключи шифрования.
  Future<Map<String, String>> exportBothKeys(String password) async {
    if (_myX25519KeyPair == null || _myEd25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }

    try {
      final x25519KeyBytes = await _myX25519KeyPair!.extractPrivateKeyBytes();
      final ed25519Pair    = await _myEd25519KeyPair!.extract();
      final ed25519KeyBytes = await ed25519Pair.extractPrivateKeyBytes();

      return {
        'x25519':  await _encryptWithPassword(x25519KeyBytes, password),
        'ed25519': await _encryptWithPassword(ed25519KeyBytes, password),
      };
    } catch (e) {
      debugLog('❌ [Crypto] Export error: $e');
      throw CryptoException('Failed to export keys: $e');
    }
  }

  /// Шифрует [plainBytes] с помощью пароля и случайного Argon2-нонса.
  /// Возвращает: base64( argon2_nonce[16] | chacha_nonce | ciphertext | mac )
  Future<String> _encryptWithPassword(List<int> plainBytes, String password) async {
    // 1. Генерируем случайный KDF-нонс (16 байт, криптостойкий PRNG)
    final argon2Nonce = _randomBytes(_kArgon2NonceLength);

    // 2. Выводим ключ из пароля + свежего нонса
    final passwordKey = await _derivePassKey(password, argon2Nonce);

    // 3. Шифруем данные
    final secretBox = await _algo.encrypt(plainBytes, secretKey: passwordKey);

    // 4. Сохраняем: argon2Nonce || ChaCha20-Poly1305 SecretBox
    final combined = [...argon2Nonce, ...secretBox.concatenation()];
    return base64Encode(combined);
  }

  /// Расшифровывает данные, зашифрованные через [_encryptWithPassword].
  /// Ожидает формат: base64( argon2_nonce[16] | chacha_nonce | ciphertext | mac )
  Future<List<int>> _decryptWithPassword(String b64, String password) async {
    final combined = base64Decode(b64);

    if (combined.length < _kArgon2NonceLength) {
      throw CryptoException('Corrupted key data: too short');
    }

    // 1. Читаем сохранённый Argon2-нонс
    final argon2Nonce = combined.sublist(0, _kArgon2NonceLength);
    final cipherData  = combined.sublist(_kArgon2NonceLength);

    // 2. Восстанавливаем ключ из пароля + сохранённого нонса
    final passwordKey = await _derivePassKey(password, argon2Nonce);

    // 3. Расшифровываем
    final box = SecretBox.fromConcatenation(
      cipherData,
      nonceLength: _algo.nonceLength,
      macLength:   _algo.macAlgorithm.macLength,
    );
    return _algo.decrypt(box, secretKey: passwordKey);
  }

  Future<void> _importBothKeys(
    String encryptedX25519B64,
    String encryptedEd25519B64,
    String password,
  ) async {
    try {
      final x25519KeyBytes  = await _decryptWithPassword(encryptedX25519B64, password);
      final ed25519KeyBytes = await _decryptWithPassword(encryptedEd25519B64, password);

      _myX25519KeyPair  = await _x25519.newKeyPairFromSeed(x25519KeyBytes);
      _myEd25519KeyPair = await _ed25519.newKeyPairFromSeed(ed25519KeyBytes);
      _isInitialized    = true;
    } catch (e) {
      debugLog('❌ [Crypto] Import error: $e');
      throw CryptoException('Failed to import keys (wrong password?): $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ПУБЛИЧНЫЕ КЛЮЧИ
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String> getMyPublicKey() async {
    if (_myX25519KeyPair == null) throw StateError('Cipher not initialized');
    final publicKey = await _myX25519KeyPair!.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  Future<String> getMySigningKey() async {
    if (_myEd25519KeyPair == null) throw StateError('Cipher not initialized');
    final publicKey = await _myEd25519KeyPair!.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED SECRET (ECDH)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> establishSharedSecret(
    String targetUid,
    String theirPublicKeyB64, {
    String? theirSignKeyB64,
  }) async {
    if (_myX25519KeyPair == null) throw StateError('Cipher not initialized');

    try {
      final theirPublicKey = SimplePublicKey(
        base64Decode(theirPublicKeyB64),
        type: KeyPairType.x25519,
      );
      _contactPublicKeys[targetUid] = theirPublicKey;

      if (theirSignKeyB64 != null) {
        final theirSignKey = SimplePublicKey(
          base64Decode(theirSignKeyB64),
          type: KeyPairType.ed25519,
        );
        _contactSignKeys[targetUid] = theirSignKey;
      }

      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair:         _myX25519KeyPair!,
        remotePublicKey: theirPublicKey,
      );
      _sharedSecrets[targetUid] = sharedSecret;
      debugLog('🔐 [Crypto] Established shared secret with $targetUid');
    } catch (e) {
      debugLog('❌ [Crypto] ECDH error: $e');
      throw CryptoException('Failed to establish shared secret: $e');
    }
  }

  bool hasSharedSecret(String targetUid) => _sharedSecrets.containsKey(targetUid);

  Future<bool> tryLoadCachedKeys(String targetUid, StorageService storage) async {
    if (hasSharedSecret(targetUid)) return true;

    final x25519Key  = storage.getCachedX25519Key(targetUid);
    final ed25519Key = storage.getCachedEd25519Key(targetUid);

    if (x25519Key != null && ed25519Key != null) {
      try {
        await establishSharedSecret(targetUid, x25519Key, theirSignKeyB64: ed25519Key);
        debugLog('✅ [Crypto] Loaded keys from cache for $targetUid');
        return true;
      } catch (e) {
        debugLog('❌ [Crypto] Failed to load cached keys: $e');
        return false;
      }
    }
    return false;
  }

  void clearSharedSecret(String targetUid) {
    _sharedSecrets.remove(targetUid);
    _contactPublicKeys.remove(targetUid);
    _contactSignKeys.remove(targetUid);
    debugLog('🗑️ [Crypto] Cleared shared secret for $targetUid');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECURITY FINGERPRINT
  // ═══════════════════════════════════════════════════════════════════════════

  /// Возвращает fingerprint сессии для верификации отсутствия MITM.
  ///
  /// **Алгоритм:**
  /// 1. Берём оба X25519-публичных ключа (мой и контакта).
  /// 2. Сортируем их лексикографически — обе стороны должны получить
  ///    одинаковый fingerprint, независимо от того, кто его считает.
  /// 3. SHA-256( sorted_key_A | sorted_key_B ) → 64 hex-символа.
  /// 4. Отображаем первые 40 символов в группах по 5: "XXXXX XXXXX XXXXX ..."
  ///
  /// Пользователи сравнивают fingerprint голосом/в реальной жизни —
  /// если они совпадают у обоих, MITM отсутствует.
  ///
  /// ⚠️ Метод async — необходим await при вызове.
  Future<String> getSecurityCode(String targetUid) async {
    if (!_contactPublicKeys.containsKey(targetUid) || _myX25519KeyPair == null) {
      return 'NOT_ESTABLISHED';
    }

    try {
      // 1. Мой публичный ключ
      final myPublicKey   = await _myX25519KeyPair!.extractPublicKey();
      final myBytes       = myPublicKey.bytes;
      // 2. Ключ контакта
      final theirBytes    = _contactPublicKeys[targetUid]!.bytes;

      // 3. Детерминированная сортировка — оба участника получат одинаковый хэш
      final List<int> first;
      final List<int> second;
      if (_compareByteArrays(myBytes, theirBytes) <= 0) {
        first  = myBytes;
        second = theirBytes;
      } else {
        first  = theirBytes;
        second = myBytes;
      }

      // 4. SHA-256 от конкатенации обоих ключей
      final combined  = [...first, ...second];
      final hash      = sha256.convert(combined);
      final hexString = hash.toString().toUpperCase();

      // 5. Форматируем как 8 групп по 5 символов (40 из 64 hex-символов)
      final buffer = StringBuffer();
      for (int i = 0; i < 8; i++) {
        if (i > 0) buffer.write(' ');
        buffer.write(hexString.substring(i * 5, i * 5 + 5));
      }
      return buffer.toString();
    } catch (e) {
      debugLog('❌ [Crypto] getSecurityCode error: $e');
      return 'ERROR';
    }
  }

  /// Лексикографическое сравнение двух byte-массивов одинаковой длины.
  /// Возвращает отрицательное значение, 0 или положительное — как Comparator.
  int _compareByteArrays(List<int> a, List<int> b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ШИФРОВАНИЕ ТЕКСТА
  // ═══════════════════════════════════════════════════════════════════════════

  Future<String> encryptText(String text, {required String targetUid}) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (!_sharedSecrets.containsKey(targetUid)) {
      throw StateError('No shared secret for $targetUid');
    }

    try {
      final plainBytes = utf8.encode(text);
      final secretBox  = await _algo.encrypt(
        plainBytes,
        secretKey: _sharedSecrets[targetUid]!,
      );
      return base64Encode(secretBox.concatenation());
    } catch (e) {
      debugLog('❌ [Crypto] Encryption failed: $e');
      throw CryptoException('Encryption failed: $e');
    }
  }

  Future<String> decryptText(String b64, {required String fromUid}) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (b64.isEmpty) return '[⚠️ Empty payload]';
    if (!_sharedSecrets.containsKey(fromUid)) {
      return '[⚠️ No encryption key for $fromUid]';
    }

    try {
      final combined = base64Decode(b64);
      final box = SecretBox.fromConcatenation(
        combined,
        nonceLength: _algo.nonceLength,
        macLength:   _algo.macAlgorithm.macLength,
      );
      final clearBytes = await _algo.decrypt(box, secretKey: _sharedSecrets[fromUid]!);
      return utf8.decode(clearBytes);
    } on SecretBoxAuthenticationError {
      // MAC проверка провалилась — сообщение повреждено или подделано
      return '[⚠️ Authentication failed]';
    } catch (e) {
      debugLog('❌ [Crypto] Decryption error: $e');
      return '[❌ Decryption error]';
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ШИФРОВАНИЕ ФАЙЛОВ
  // ═══════════════════════════════════════════════════════════════════════════

  /// Шифрует байты файла. Возвращает: nonce[12] | ciphertext | mac[16]
  Future<List<int>> encryptFileBytes(
    List<int> fileBytes, {
    required String targetUid,
  }) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (!_sharedSecrets.containsKey(targetUid)) {
      throw StateError('No shared secret for $targetUid');
    }

    try {
      final secretBox = await _algo.encrypt(
        fileBytes,
        secretKey: _sharedSecrets[targetUid]!,
      );
      return secretBox.concatenation();
    } catch (e) {
      debugLog('❌ [Crypto] File encryption failed: $e');
      throw CryptoException('File encryption failed: $e');
    }
  }

  /// Расшифровывает байты файла.
  Future<List<int>> decryptFileBytes(
    List<int> encryptedBytes, {
    required String fromUid,
  }) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (!_sharedSecrets.containsKey(fromUid)) {
      throw StateError('No key for $fromUid');
    }

    try {
      final box = SecretBox.fromConcatenation(
        encryptedBytes,
        nonceLength: _algo.nonceLength,
        macLength:   _algo.macAlgorithm.macLength,
      );
      return _algo.decrypt(box, secretKey: _sharedSecrets[fromUid]!);
    } catch (e) {
      debugLog('❌ [Crypto] File decryption error: $e');
      throw CryptoException('File decryption error');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ПОДПИСИ Ed25519
  // ═══════════════════════════════════════════════════════════════════════════

  /// Подписывает [text] приватным Ed25519-ключом текущего пользователя.
  Future<String> signMessage(String text) async {
    if (_myEd25519KeyPair == null) throw StateError('Cipher not initialized');
    try {
      final signature = await _ed25519.sign(
        utf8.encode(text),
        keyPair: _myEd25519KeyPair!,
      );
      return base64Encode(signature.bytes);
    } catch (e) {
      throw CryptoException('Failed to sign message: $e');
    }
  }

  /// Проверяет Ed25519-подпись сообщения от [fromUid].
  ///
  /// Возвращает `true` если подпись верна, `false` если:
  /// - подпись повреждена или не совпадает,
  /// - публичный ключ подписи для [fromUid] ещё не установлен.
  ///
  /// **Важно:** вызывающий код обязан реагировать на `false` —
  /// помечать сообщение предупреждением или отвергать его.
  Future<bool> verifySignature(
    String text,
    String signatureB64,
    String fromUid,
  ) async {
    if (!_contactSignKeys.containsKey(fromUid)) return false;
    try {
      final signature = Signature(
        base64Decode(signatureB64),
        publicKey: _contactSignKeys[fromUid]!,
      );
      return await _ed25519.verify(utf8.encode(text), signature: signature);
    } catch (e) {
      debugLog('⚠️ [Crypto] Signature verification error for $fromUid: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // LEGACY EXPORT (одиночный X25519-ключ, для совместимости бекапов)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Экспортирует только X25519-приватный ключ. Используйте [exportBothKeys]
  /// для полного резервного копирования.
  Future<String> exportPrivateKey(String password) async {
    if (_myX25519KeyPair == null) throw StateError('Cipher not initialized');
    try {
      final privateKeyBytes = await _myX25519KeyPair!.extractPrivateKeyBytes();
      return _encryptWithPassword(privateKeyBytes, password);
    } catch (e) {
      throw CryptoException('Failed to export private key: $e');
    }
  }

  /// Импортирует X25519-приватный ключ. Поддерживает как новый формат (с
  /// Argon2-нонсом), так и устаревший (со статичным нонсом — для миграции
  /// старых пользователей).
  Future<void> importPrivateKey(String encryptedKeyB64, String password) async {
    try {
      List<int> privateKeyBytes;

      final raw = base64Decode(encryptedKeyB64);
      if (_isLegacyFormat(raw)) {
        // Старый формат: без префикса Argon2-нонса, статичный нонс [0..15]
        debugLog('⚠️ [Crypto] Importing legacy key format — re-export after import!');
        privateKeyBytes = await _decryptWithPasswordLegacy(encryptedKeyB64, password);
      } else {
        // Новый формат: с случайным Argon2-нонсом
        privateKeyBytes = await _decryptWithPassword(encryptedKeyB64, password);
      }

      _myX25519KeyPair = await _x25519.newKeyPairFromSeed(privateKeyBytes);
      _isInitialized   = true;
    } catch (e) {
      throw CryptoException('Failed to import private key: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ
  // ═══════════════════════════════════════════════════════════════════════════

  /// Выводит ключ Argon2id из пароля и случайного [nonce].
  Future<SecretKey> _derivePassKey(String password, List<int> nonce) async {
    return Argon2id(
      memory:      32768,
      iterations:  3,
      parallelism: 4,
      hashLength:  32,
    ).deriveKeyFromPassword(password: password, nonce: nonce);
  }

  /// Генерирует [length] криптографически случайных байт.
  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  /// Эвристика: если длина декодированных данных не кратна ожидаемому для нового
  /// формата (≥ 16 + 12 + 0 + 16 = 44 байт) — считаем файл старым форматом.
  /// Более точно: старый формат начинается с chacha-нонса (12 байт, не 16).
  bool _isLegacyFormat(List<int> raw) {
    // Новый формат: argon2_nonce[16] + chacha_nonce[12] + ciphertext + mac[16]
    // минимум 44 байта. Но если первые 16 байт — аргон2-нонс, длина будет >= 44.
    // Старый формат: chacha_nonce[12] + ciphertext + mac[16], длина минимум 28.
    // Эвристика: если длина < 44 или первые 16 байт выглядят как [0,1,2,...,15].
    if (raw.length < _kArgon2NonceLength + _algo.nonceLength + _algo.macAlgorithm.macLength) {
      return true;
    }
    // Проверяем сигнатуру старого нонса [0,1,2,...,15] начиная с byte 0
    bool looksLikeStaticNonce = true;
    for (int i = 0; i < 12; i++) {
      if (raw[i] != i) { looksLikeStaticNonce = false; break; }
    }
    return looksLikeStaticNonce;
  }

  /// Расшифровка в старом (уязвимом) формате — только для миграции.
  Future<List<int>> _decryptWithPasswordLegacy(
    String b64,
    String password,
  ) async {
    final legacyNonce = List<int>.generate(16, (i) => i); // старый статичный нонс
    final passwordKey = await _derivePassKey(password, legacyNonce);
    final combined    = base64Decode(b64);
    final box = SecretBox.fromConcatenation(
      combined,
      nonceLength: _algo.nonceLength,
      macLength:   _algo.macAlgorithm.macLength,
    );
    return _algo.decrypt(box, secretKey: passwordKey);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // СОСТОЯНИЕ И DISPOSE
  // ═══════════════════════════════════════════════════════════════════════════

  bool get isInitialized => _isInitialized;

  void dispose() {
    _sharedSecrets.clear();
    _contactPublicKeys.clear();
    _contactSignKeys.clear();
    _myX25519KeyPair  = null;
    _myEd25519KeyPair = null;
    _isInitialized    = false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Утилиты
// ─────────────────────────────────────────────────────────────────────────────

/// Логирование только в debug-сборках (не попадает в production логи устройства).
void debugLog(String message) {
  assert(() {
    // ignore: avoid_print
    print(message);
    return true;
  }());
}

/// Исключение криптографических операций.
class CryptoException implements Exception {
  final String message;
  const CryptoException(this.message);

  @override
  String toString() => 'CryptoException: $message';
}

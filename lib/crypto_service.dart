import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import '../storage_service.dart';
import '../config/app_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ФОРМАТ ХРАНЕНИЯ ЗАШИФРОВАННЫХ КЛЮЧЕЙ (v2):
//
//   base64( version_byte[1] | argon2_nonce[16] | chacha20_nonce[12] | ciphertext | poly1305_mac[16] )
//
// version_byte = 0x02 для текущего формата.
// Первые 16 байт после version — случайный KDF-нонс для Argon2id.
// Остальное — стандартный ChaCha20-Poly1305 SecretBox.
//
// Legacy формат (v1): без version byte, без Argon2 nonce.
// ─────────────────────────────────────────────────────────────────────────────

/// Уровень безопасности Argon2id.
enum Argon2SecurityLevel {
  /// Быстрый (для слабых устройств): 16 MB, 2 итерации
  low(memory: 16384, iterations: 2, label: 'Быстрый'),

  /// Стандартный: 32 MB, 3 итерации
  standard(memory: 32768, iterations: 3, label: 'Стандартный'),

  /// Высокий (для мощных устройств): 64 MB, 4 итерации
  high(memory: 65536, iterations: 4, label: 'Высокий');

  final int memory;
  final int iterations;
  final String label;
  const Argon2SecurityLevel({
    required this.memory,
    required this.iterations,
    required this.label,
  });
}

/// Сервис E2E-шифрования: X25519 ECDH + ChaCha20-Poly1305 + Ed25519
class SecureCipher {
  // ── Алгоритмы ──────────────────────────────────────────────────────────────
  final _algo    = Chacha20.poly1305Aead();
  final _x25519  = X25519();
  final _ed25519 = Ed25519();

  // ── Ключи текущего пользователя ────────────────────────────────────────────
  SimpleKeyPair? _myX25519KeyPair;
  SimpleKeyPair? _myEd25519KeyPair;

  // ── Кэши контактов ─────────────────────────────────────────────────────────
  final Map<String, SecretKey>      _sharedSecrets      = {};
  final Map<String, SimplePublicKey> _contactPublicKeys  = {};
  final Map<String, SimplePublicKey> _contactSignKeys    = {};

  bool _isInitialized = false;

  // ── Настройки ──────────────────────────────────────────────────────────────
  Argon2SecurityLevel _securityLevel = Argon2SecurityLevel.standard;

  Argon2SecurityLevel get securityLevel => _securityLevel;
  set securityLevel(Argon2SecurityLevel level) => _securityLevel = level;

  // ── Константы формата ──────────────────────────────────────────────────────
  static const int _kVersionByteLength = 1;
  static const int _kArgon2NonceLength = 16;

  // ═══════════════════════════════════════════════════════════════════════════
  // ИНИЦИАЛИЗАЦИЯ
  // ═══════════════════════════════════════════════════════════════════════════

  static String generateSalt() {
    final random = Random.secure();
    final saltBytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Encode(saltBytes);
  }

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

  /// Шифрует [plainBytes] с помощью пароля.
  /// Формат v2: version_byte[1] | argon2_nonce[16] | chacha_nonce | ciphertext | mac
  Future<String> _encryptWithPassword(List<int> plainBytes, String password) async {
    final argon2Nonce = _randomBytes(_kArgon2NonceLength);
    final passwordKey = await _derivePassKey(password, argon2Nonce);
    final secretBox   = await _algo.encrypt(plainBytes, secretKey: passwordKey);

    // Version byte + argon2Nonce + SecretBox
    final combined = [
      AppConfig.cryptoFormatVersion,   // version byte
      ...argon2Nonce,
      ...secretBox.concatenation(),
    ];
    return base64Encode(combined);
  }

  /// Расшифровывает данные. Автоматически определяет формат.
  Future<List<int>> _decryptWithPassword(String b64, String password) async {
    final combined = base64Decode(b64);
    final format = _detectFormat(combined);

    switch (format) {
      case _CryptoFormat.v2:
        return _decryptV2(combined, password);
      case _CryptoFormat.v1:
        return _decryptV1(combined, password);
      case _CryptoFormat.legacy:
        debugLog('⚠️ [Crypto] Decrypting legacy format — re-export recommended!');
        return _decryptLegacy(combined, password);
    }
  }

  Future<List<int>> _decryptV2(List<int> combined, String password) async {
    // Skip version byte
    final argon2Nonce = combined.sublist(_kVersionByteLength, _kVersionByteLength + _kArgon2NonceLength);
    final cipherData  = combined.sublist(_kVersionByteLength + _kArgon2NonceLength);
    final passwordKey = await _derivePassKey(password, argon2Nonce);
    final box = SecretBox.fromConcatenation(
      cipherData,
      nonceLength: _algo.nonceLength,
      macLength:   _algo.macAlgorithm.macLength,
    );
    return _algo.decrypt(box, secretKey: passwordKey);
  }

  Future<List<int>> _decryptV1(List<int> combined, String password) async {
    // v1: argon2_nonce[16] | chacha_nonce | ciphertext | mac (без version byte)
    final argon2Nonce = combined.sublist(0, _kArgon2NonceLength);
    final cipherData  = combined.sublist(_kArgon2NonceLength);
    final passwordKey = await _derivePassKey(password, argon2Nonce);
    final box = SecretBox.fromConcatenation(
      cipherData,
      nonceLength: _algo.nonceLength,
      macLength:   _algo.macAlgorithm.macLength,
    );
    return _algo.decrypt(box, secretKey: passwordKey);
  }

  Future<List<int>> _decryptLegacy(List<int> combined, String password) async {
    final legacyNonce = List<int>.generate(16, (i) => i);
    final passwordKey = await _derivePassKey(password, legacyNonce);
    final box = SecretBox.fromConcatenation(
      combined,
      nonceLength: _algo.nonceLength,
      macLength:   _algo.macAlgorithm.macLength,
    );
    return _algo.decrypt(box, secretKey: passwordKey);
  }

  /// Определяет формат зашифрованных данных.
  _CryptoFormat _detectFormat(List<int> raw) {
    if (raw.isEmpty) return _CryptoFormat.legacy;

    // v2: первый байт = 0x02
    if (raw[0] == 0x02 && raw.length >= _kVersionByteLength + _kArgon2NonceLength + _algo.nonceLength + _algo.macAlgorithm.macLength) {
      return _CryptoFormat.v2;
    }

    // v1: достаточная длина для argon2_nonce + chacha + mac, но нет version byte
    if (raw.length >= _kArgon2NonceLength + _algo.nonceLength + _algo.macAlgorithm.macLength) {
      // Проверяем НЕ legacy ли это — legacy начинается с chacha nonce [0,1,2,...,11]
      bool looksLikeStaticNonce = true;
      for (int i = 0; i < 12 && i < raw.length; i++) {
        if (raw[i] != i) { looksLikeStaticNonce = false; break; }
      }
      if (!looksLikeStaticNonce) return _CryptoFormat.v1;
    }

    return _CryptoFormat.legacy;
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

  /// Возвращает auth Ed25519 pubkey (для отправки на сервер при регистрации).
  Future<String> getAuthPublicKey() async => getMySigningKey();

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

  // ──────────────────────────────────────────────────────────────────────────
  // Групповые ключи
  // ──────────────────────────────────────────────────────────────────────────

  List<int> generateGroupKey() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256));
  }

  void setGroupKey(String groupId, List<int> keyBytes) {
    _sharedSecrets[groupId] = SecretKey(keyBytes);
    debugLog('🔑 [Crypto] Group key set for $groupId');
  }

  Future<String> encryptGroupKeyFor(String memberUid, List<int> keyBytes) async {
    final keyB64 = base64Encode(keyBytes);
    return encryptText(keyB64, targetUid: memberUid);
  }

  Future<List<int>> decryptGroupKey(String fromUid, String encryptedB64) async {
    final keyB64 = await decryptText(encryptedB64, fromUid: fromUid);
    return base64Decode(keyB64);
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

  Future<String> getSecurityCode(String targetUid) async {
    if (!_contactPublicKeys.containsKey(targetUid) || _myX25519KeyPair == null) {
      return 'NOT_ESTABLISHED';
    }

    try {
      final myPublicKey = await _myX25519KeyPair!.extractPublicKey();
      final myBytes     = myPublicKey.bytes;
      final theirBytes  = _contactPublicKeys[targetUid]!.bytes;

      final List<int> first;
      final List<int> second;
      if (_compareByteArrays(myBytes, theirBytes) <= 0) {
        first  = myBytes;
        second = theirBytes;
      } else {
        first  = theirBytes;
        second = myBytes;
      }

      final combined  = [...first, ...second];
      final hash      = sha256.convert(combined);
      final hexString = hash.toString().toUpperCase();

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
      return '[⚠️ Authentication failed]';
    } catch (e) {
      debugLog('❌ [Crypto] Decryption error: $e');
      return '[❌ Decryption error]';
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ШИФРОВАНИЕ ФАЙЛОВ
  // ═══════════════════════════════════════════════════════════════════════════

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

  Future<String> signChallenge(String nonceB64) async {
    if (_myEd25519KeyPair == null) throw StateError('Cipher not initialized');
    try {
      final nonceBytes = base64Decode(nonceB64);
      final signature  = await _ed25519.sign(nonceBytes, keyPair: _myEd25519KeyPair!);
      return base64Encode(signature.bytes);
    } catch (e) {
      throw CryptoException('Failed to sign challenge: $e');
    }
  }

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

  Future<String> exportPrivateKey(String password) async {
    if (_myX25519KeyPair == null) throw StateError('Cipher not initialized');
    try {
      final privateKeyBytes = await _myX25519KeyPair!.extractPrivateKeyBytes();
      return _encryptWithPassword(privateKeyBytes, password);
    } catch (e) {
      throw CryptoException('Failed to export private key: $e');
    }
  }

  Future<void> importPrivateKey(String encryptedKeyB64, String password) async {
    try {
      final privateKeyBytes = await _decryptWithPassword(encryptedKeyB64, password);
      _myX25519KeyPair = await _x25519.newKeyPairFromSeed(privateKeyBytes);
      _isInitialized   = true;
    } catch (e) {
      throw CryptoException('Failed to import private key: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ВСПОМОГАТЕЛЬНЫЕ МЕТОДЫ
  // ═══════════════════════════════════════════════════════════════════════════

  Future<SecretKey> _derivePassKey(String password, List<int> nonce) async {
    return Argon2id(
      memory:      _securityLevel.memory,
      iterations:  _securityLevel.iterations,
      parallelism: 4,
      hashLength:  32,
    ).deriveKeyFromPassword(password: password, nonce: nonce);
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
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
// Вспомогательные типы
// ─────────────────────────────────────────────────────────────────────────────

enum _CryptoFormat { v2, v1, legacy }

void debugLog(String message) {
  assert(() {
    // ignore: avoid_print
    print(message);
    return true;
  }());
}

class CryptoException implements Exception {
  final String message;
  const CryptoException(this.message);

  @override
  String toString() => 'CryptoException: $message';
}

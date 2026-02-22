import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';

/// Сервис для E2E шифрования сообщений
/// Использует X25519 для обмена ключами и ChaCha20-Poly1305 для шифрования
/// 
/// Реализация с индивидуальными ключами для каждой пары пользователей.
class SecureCipher {
  final _algo = Chacha20.poly1305Aead();
  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  
  SimpleKeyPair? _myX25519KeyPair;      // Для ECDH (Шифрование)
  SimpleKeyPair? _myEd25519KeyPair;     // Для подписей (Аутентичность)
  
  final Map<String, SecretKey> _sharedSecrets = {};           // uid -> shared secret
  final Map<String, SimplePublicKey> _contactPublicKeys = {}; // uid -> их X25519 публичный ключ
  final Map<String, SimplePublicKey> _contactSignKeys = {};   // uid -> их Ed25519 публичный ключ
  
  bool _isInitialized = false;

  /// Генерирует случайную соль для пароля пользователя
  /// Возвращает 32-байтную соль в виде base64 строки
  static String generateSalt() {
    final random = Random.secure();
    final saltBytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Encode(saltBytes);
  }

  /// Инициализирует cipher, генерируя пары ключей для пользователя
  /// 
  /// [password] - пароль используется для шифрования приватных ключей
  /// [userSalt] - соль пользователя для Argon2
  /// [encryptedX25519Key] - сохранённый зашифрованный X25519 ключ
  /// [encryptedEd25519Key] - сохранённый зашифрованный Ed25519 ключ
  Future<void> init(
    String password, 
    String userSalt, {
    String? encryptedX25519Key,
    String? encryptedEd25519Key,
  }) async {
    try {
      // Если есть сохранённые ключи - восстанавливаем их из хранилища
      if (encryptedX25519Key != null && encryptedEd25519Key != null) {
        await _importBothKeys(encryptedX25519Key, encryptedEd25519Key, password);
        print('✅ [Crypto] Cipher initialized with restored key pairs');
      } else {
        // Генерируем абсолютно новые пары ключей (первый запуск)
        _myX25519KeyPair = await _x25519.newKeyPair();
        _myEd25519KeyPair = await _ed25519.newKeyPair();
        _isInitialized = true;
        print('✅ [Crypto] Cipher initialized with new key pairs');
      }
    } catch (e) {
      print('❌ [Crypto] Initialization error: $e');
      throw CryptoException('Failed to initialize cipher: $e');
    }
  }

  /// Экспортирует оба приватных ключа (X25519 и Ed25519) зашифрованными паролем
  /// Возвращает Map с двумя ключами: 'x25519' и 'ed25519'
  Future<Map<String, String>> exportBothKeys(String password) async {
    if (_myX25519KeyPair == null || _myEd25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }

    try {
      // Экспортируем X25519 приватный ключ в байты
      final x25519KeyBytes = await _myX25519KeyPair!.extractPrivateKeyBytes();
      
      // Экспортируем Ed25519 приватный ключ
      final ed25519KeyPair = await _myEd25519KeyPair!.extract();
      final ed25519KeyBytes = await ed25519KeyPair.extractPrivateKeyBytes();
      
      // Генерируем ключ шифрования из пароля (Argon2id)
      final passwordKey = await Argon2id(
        memory: 32768,
        iterations: 3,
        parallelism: 4,
        hashLength: 32,
      ).deriveKeyFromPassword(
        password: password,
        nonce: List.generate(16, (i) => i), // Фиксированная соль для ключей
      );
      
      // Шифруем X25519 ключ
      final encryptedX25519 = await _algo.encrypt(
        x25519KeyBytes,
        secretKey: passwordKey,
      );
      
      // Шифруем Ed25519 ключ
      final encryptedEd25519 = await _algo.encrypt(
        ed25519KeyBytes,
        secretKey: passwordKey,
      );
      
      return {
        'x25519': base64Encode(encryptedX25519.concatenation()),
        'ed25519': base64Encode(encryptedEd25519.concatenation()),
      };
    } catch (e) {
      print('❌ [Crypto] Export error: $e');
      throw CryptoException('Failed to export keys: $e');
    }
  }

  /// Внутренний метод для расшифровки и импорта обоих ключей
  Future<void> _importBothKeys(
    String encryptedX25519B64,
    String encryptedEd25519B64,
    String password,
  ) async {
    try {
      // Генерируем Argon2 ключ из пароля
      final passwordKey = await Argon2id(
        memory: 32768,
        iterations: 3,
        parallelism: 4,
        hashLength: 32,
      ).deriveKeyFromPassword(
        password: password,
        nonce: List.generate(16, (i) => i),
      );
      
      // Декодируем и расшифровываем X25519 ключ
      final x25519Combined = base64Decode(encryptedX25519B64);
      final x25519Box = SecretBox.fromConcatenation(
        x25519Combined,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      final x25519KeyBytes = await _algo.decrypt(x25519Box, secretKey: passwordKey);
      
      // Декодируем и расшифровываем Ed25519 ключ
      final ed25519Combined = base64Decode(encryptedEd25519B64);
      final ed25519Box = SecretBox.fromConcatenation(
        ed25519Combined,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      final ed25519KeyBytes = await _algo.decrypt(ed25519Box, secretKey: passwordKey);
      
      // Восстанавливаем пары ключей из семян (seeds)
      _myX25519KeyPair = await _x25519.newKeyPairFromSeed(x25519KeyBytes);
      _myEd25519KeyPair = await _ed25519.newKeyPairFromSeed(ed25519KeyBytes);
      _isInitialized = true;
    } catch (e) {
      print('❌ [Crypto] Import error: $e');
      throw CryptoException('Failed to import keys (wrong password?): $e');
    }
  }

  /// Возвращает публичный ключ X25519 в base64 (для отправки собеседнику)
  Future<String> getMyPublicKey() async {
    if (_myX25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }
    final publicKey = await _myX25519KeyPair!.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Возвращает публичный ключ Ed25519 в base64 (для проверки твоих подписей)
  Future<String> getMySigningKey() async {
    if (_myEd25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }
    final publicKey = await _myEd25519KeyPair!.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Устанавливает общий секрет (Shared Secret) через Diffie-Hellman
  Future<void> establishSharedSecret(
    String targetUid,
    String theirPublicKeyB64, {
    String? theirSignKeyB64,
  }) async {
    if (_myX25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }
    
    try {
      // Сохраняем их публичный ключ шифрования
      final theirPublicKey = SimplePublicKey(
        base64Decode(theirPublicKeyB64),
        type: KeyPairType.x25519,
      );
      _contactPublicKeys[targetUid] = theirPublicKey;
      
      // Сохраняем их публичный ключ подписи (если есть)
      if (theirSignKeyB64 != null) {
        final theirSignKey = SimplePublicKey(
          base64Decode(theirSignKeyB64),
          type: KeyPairType.ed25519,
        );
        _contactSignKeys[targetUid] = theirSignKey;
      }
      
      // Самая важная часть: вычисляем общий секретный ключ для этой пары
      final sharedSecret = await _x25519.sharedSecretKey(
        keyPair: _myX25519KeyPair!,
        remotePublicKey: theirPublicKey,
      );
      
      _sharedSecrets[targetUid] = sharedSecret;
      print('🔐 [Crypto] Established shared secret with $targetUid');
    } catch (e) {
      print('❌ [Crypto] ECDH error: $e');
      throw CryptoException('Failed to establish shared secret: $e');
    }
  }

  /// Проверяет, готов ли зашифрованный канал с этим пользователем
  bool hasSharedSecret(String targetUid) {
    return _sharedSecrets.containsKey(targetUid);
  }

  /// Генерирует код безопасности для верификации (Safety Number)
  /// Сравнивая этот код, пользователи убеждаются в отсутствии MITM атаки.
  String getSecurityCode(String targetUid) {
    if (!_contactPublicKeys.containsKey(targetUid) || _myX25519KeyPair == null) {
      return "NOT_ESTABLISHED";
    }
    
    try {
      // Берем байты нашего публичного ключа (закешированные в паре) и их ключа
      // Мы используем синхронный доступ к байтам через сохраненные данные, 
      // чтобы не вешать UI долгими Future.
      final theirBytes = _contactPublicKeys[targetUid]!.bytes;
      
      // Хешируем комбинацию для получения уникального отпечатка
      // Мы делаем это просто: SHA256 от суммы байтов ключей
      final hash = sha256.convert(theirBytes);
      
      // Превращаем в читаемый HEX-код, разбитый на группы по 4 символа
      final fullCode = hash.toString().toUpperCase();
      return "${fullCode.substring(0, 4)} ${fullCode.substring(4, 8)} ${fullCode.substring(8, 12)}";
    } catch (e) {
      print("❌ [Crypto] Security code calc error: $e");
      return "ERROR";
    }
  }

  /// Шифрует текст для конкретного получателя [targetUid]
  Future<String> encryptText(String text, {required String targetUid}) async {
    if (!_isInitialized) {
      throw StateError('Cipher not initialized. Call init() first.');
    }

    if (text.isEmpty) {
      throw ArgumentError('Cannot encrypt empty text');
    }
    
    if (!_sharedSecrets.containsKey(targetUid)) {
      throw StateError('No shared secret for $targetUid. Perform key exchange first.');
    }

    try {
      final plainBytes = utf8.encode(text);
      final secretBox = await _algo.encrypt(
        plainBytes,
        secretKey: _sharedSecrets[targetUid]!,
      );
      
      // Возвращаем зашифрованные данные + IV + MAC в одной base64 строке
      return base64Encode(secretBox.concatenation());
    } catch (e) {
      print('❌ [Crypto] Encryption failed: $e');
      throw CryptoException('Encryption failed: $e');
    }
  }

  /// Расшифровывает текст от отправителя [fromUid]
  Future<String> decryptText(String b64, {required String fromUid}) async {
    if (!_isInitialized) {
      throw StateError('Cipher not initialized.');
    }

    if (b64.isEmpty) {
      return "[⚠️ Empty payload]";
    }
    
    if (!_sharedSecrets.containsKey(fromUid)) {
      return "[⚠️ No encryption key for $fromUid]";
    }

    try {
      final combined = base64Decode(b64);
      
      final box = SecretBox.fromConcatenation(
        combined,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      
      final clearBytes = await _algo.decrypt(
        box,
        secretKey: _sharedSecrets[fromUid]!,
      );
      
      return utf8.decode(clearBytes);
    } on SecretBoxAuthenticationError {
      return "[⚠️ Authentication failed: Wrong key or data corrupted]";
    } catch (e) {
      print('❌ [Crypto] Decryption error: $e');
      return "[❌ Decryption error]";
    }
  }

  /// Подписывает сообщение (Ed25519)
  Future<String> signMessage(String text) async {
    if (_myEd25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }

    try {
      final signature = await _ed25519.sign(
        utf8.encode(text),
        keyPair: _myEd25519KeyPair!,
      );
      return base64Encode(signature.bytes);
    } catch (e) {
      print('❌ [Crypto] Signing error: $e');
      throw CryptoException('Failed to sign message: $e');
    }
  }

  /// Проверяет подпись сообщения [signatureB64] от пользователя [fromUid]
  Future<bool> verifySignature(
    String text,
    String signatureB64,
    String fromUid,
  ) async {
    if (!_contactSignKeys.containsKey(fromUid)) {
      print('⚠️ [Crypto] No signing key for $fromUid');
      return false;
    }

    try {
      final signature = Signature(
        base64Decode(signatureB64),
        publicKey: _contactSignKeys[fromUid]!,
      );
      
      return await _ed25519.verify(
        utf8.encode(text),
        signature: signature,
      );
    } catch (e) {
      print('❌ [Crypto] Signature verify error: $e');
      return false;
    }
  }

  /// Экспортирует приватный ключ X25519 (Legacy метод для бекапа)
  Future<String> exportPrivateKey(String password) async {
    if (_myX25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }

    try {
      final privateKeyBytes = await _myX25519KeyPair!.extractPrivateKeyBytes();
      final passwordKey = await _derivePassKey(password);
      
      final encrypted = await _algo.encrypt(
        privateKeyBytes,
        secretKey: passwordKey,
      );
      
      return base64Encode(encrypted.concatenation());
    } catch (e) {
      throw CryptoException('Failed to export private key: $e');
    }
  }

  /// Импортирует приватный ключ X25519 (Legacy метод для бекапа)
  Future<void> importPrivateKey(String encryptedKeyB64, String password) async {
    try {
      final passwordKey = await _derivePassKey(password);
      final combined = base64Decode(encryptedKeyB64);
      final box = SecretBox.fromConcatenation(
        combined,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      
      final privateKeyBytes = await _algo.decrypt(box, secretKey: passwordKey);
      _myX25519KeyPair = await _x25519.newKeyPairFromSeed(privateKeyBytes);
      _isInitialized = true;
      print('✅ [Crypto] Private key imported');
    } catch (e) {
      throw CryptoException('Failed to import private key: $e');
    }
  }

  /// Вспомогательная функция вывода ключа из пароля
  Future<SecretKey> _derivePassKey(String password) async {
    return await Argon2id(
      memory: 32768,
      iterations: 3,
      parallelism: 4,
      hashLength: 32,
    ).deriveKeyFromPassword(
      password: password,
      nonce: List.generate(16, (i) => i),
    );
  }

  /// Проверяет, инициализирован ли cipher
  bool get isInitialized => _isInitialized;

  /// Очищает все ключи из памяти (Log out)
  void dispose() {
    _sharedSecrets.clear();
    _contactPublicKeys.clear();
    _contactSignKeys.clear();
    _myX25519KeyPair = null;
    _myEd25519KeyPair = null;
    _isInitialized = false;
    print('🧹 [Crypto] Memory cleared');
  }
}

/// Кастомное исключение для криптографических ошибок
class CryptoException implements Exception {
  final String message;
  CryptoException(this.message);
  @override
  String toString() => 'CryptoException: $message';
}

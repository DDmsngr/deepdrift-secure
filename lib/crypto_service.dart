import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart';
import 'storage_service.dart';

/// Сервис для E2E шифрования сообщений и файлов
class SecureCipher {
  final _algo = Chacha20.poly1305Aead();
  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  
  SimpleKeyPair? _myX25519KeyPair;      
  SimpleKeyPair? _myEd25519KeyPair;     
  
  final Map<String, SecretKey> _sharedSecrets = {};           
  final Map<String, SimplePublicKey> _contactPublicKeys = {}; 
  final Map<String, SimplePublicKey> _contactSignKeys = {};   
  
  bool _isInitialized = false;

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
        print('✅ [Crypto] Cipher initialized with restored key pairs');
      } else {
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

  Future<Map<String, String>> exportBothKeys(String password) async {
    if (_myX25519KeyPair == null || _myEd25519KeyPair == null) {
      throw StateError('Cipher not initialized');
    }

    try {
      final x25519KeyBytes = await _myX25519KeyPair!.extractPrivateKeyBytes();
      
      final ed25519KeyPair = await _myEd25519KeyPair!.extract();
      final ed25519KeyBytes = await ed25519KeyPair.extractPrivateKeyBytes();
      
      final passwordKey = await Argon2id(
        memory: 32768,
        iterations: 3,
        parallelism: 4,
        hashLength: 32,
      ).deriveKeyFromPassword(
        password: password,
        nonce: List.generate(16, (i) => i),
      );
      
      final encryptedX25519 = await _algo.encrypt(x25519KeyBytes, secretKey: passwordKey);
      final encryptedEd25519 = await _algo.encrypt(ed25519KeyBytes, secretKey: passwordKey);
      
      return {
        'x25519': base64Encode(encryptedX25519.concatenation()),
        'ed25519': base64Encode(encryptedEd25519.concatenation()),
      };
    } catch (e) {
      print('❌ [Crypto] Export error: $e');
      throw CryptoException('Failed to export keys: $e');
    }
  }

  Future<void> _importBothKeys(String encryptedX25519B64, String encryptedEd25519B64, String password) async {
    try {
      final passwordKey = await Argon2id(
        memory: 32768,
        iterations: 3,
        parallelism: 4,
        hashLength: 32,
      ).deriveKeyFromPassword(
        password: password,
        nonce: List.generate(16, (i) => i),
      );
      
      final x25519Combined = base64Decode(encryptedX25519B64);
      final x25519Box = SecretBox.fromConcatenation(
        x25519Combined,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      final x25519KeyBytes = await _algo.decrypt(x25519Box, secretKey: passwordKey);
      
      final ed25519Combined = base64Decode(encryptedEd25519B64);
      final ed25519Box = SecretBox.fromConcatenation(
        ed25519Combined,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      final ed25519KeyBytes = await _algo.decrypt(ed25519Box, secretKey: passwordKey);
      
      _myX25519KeyPair = await _x25519.newKeyPairFromSeed(x25519KeyBytes);
      _myEd25519KeyPair = await _ed25519.newKeyPairFromSeed(ed25519KeyBytes);
      _isInitialized = true;
    } catch (e) {
      print('❌ [Crypto] Import error: $e');
      throw CryptoException('Failed to import keys (wrong password?): $e');
    }
  }

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

  Future<void> establishSharedSecret(
    String targetUid,
    String theirPublicKeyB64, {
    String? theirSignKeyB64,
  }) async {
    if (_myX25519KeyPair == null) throw StateError('Cipher not initialized');
    
    try {
      final theirPublicKey = SimplePublicKey(base64Decode(theirPublicKeyB64), type: KeyPairType.x25519);
      _contactPublicKeys[targetUid] = theirPublicKey;
      
      if (theirSignKeyB64 != null) {
        final theirSignKey = SimplePublicKey(base64Decode(theirSignKeyB64), type: KeyPairType.ed25519);
        _contactSignKeys[targetUid] = theirSignKey;
      }
      
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

  bool hasSharedSecret(String targetUid) => _sharedSecrets.containsKey(targetUid);

  Future<bool> tryLoadCachedKeys(String targetUid, StorageService storage) async {
    if (hasSharedSecret(targetUid)) return true;

    final x25519Key = storage.getCachedX25519Key(targetUid);
    final ed25519Key = storage.getCachedEd25519Key(targetUid);

    if (x25519Key != null && ed25519Key != null) {
      try {
        await establishSharedSecret(targetUid, x25519Key, theirSignKeyB64: ed25519Key);
        print('✅ [Crypto] Loaded keys from cache for $targetUid');
        return true;
      } catch (e) {
        print('❌ [Crypto] Failed to load cached keys: $e');
        return false;
      }
    }
    return false;
  }

  void clearSharedSecret(String targetUid) {
    _sharedSecrets.remove(targetUid);
    _contactPublicKeys.remove(targetUid);
    _contactSignKeys.remove(targetUid);
    print('🗑️ [Crypto] Cleared shared secret for $targetUid');
  }

  String getSecurityCode(String targetUid) {
    if (!_contactPublicKeys.containsKey(targetUid) || _myX25519KeyPair == null) {
      return "NOT_ESTABLISHED";
    }
    try {
      final theirBytes = _contactPublicKeys[targetUid]!.bytes;
      final hash = sha256.convert(theirBytes);
      final fullCode = hash.toString().toUpperCase();
      return "${fullCode.substring(0, 4)} ${fullCode.substring(4, 8)} ${fullCode.substring(8, 12)}";
    } catch (e) {
      return "ERROR";
    }
  }

  // ============================================================
  // ШИФРОВАНИЕ ТЕКСТА
  // ============================================================

  Future<String> encryptText(String text, {required String targetUid}) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (!_sharedSecrets.containsKey(targetUid)) throw StateError('No shared secret for $targetUid');

    try {
      final plainBytes = utf8.encode(text);
      final secretBox = await _algo.encrypt(plainBytes, secretKey: _sharedSecrets[targetUid]!);
      return base64Encode(secretBox.concatenation());
    } catch (e) {
      print('❌ [Crypto] Encryption failed: $e');
      throw CryptoException('Encryption failed: $e');
    }
  }

  Future<String> decryptText(String b64, {required String fromUid}) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (b64.isEmpty) return "[⚠️ Empty payload]";
    if (!_sharedSecrets.containsKey(fromUid)) return "[⚠️ No encryption key for $fromUid]";

    try {
      final combined = base64Decode(b64);
      final box = SecretBox.fromConcatenation(
        combined,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      final clearBytes = await _algo.decrypt(box, secretKey: _sharedSecrets[fromUid]!);
      return utf8.decode(clearBytes);
    } on SecretBoxAuthenticationError {
      return "[⚠️ Authentication failed]";
    } catch (e) {
      print('❌ [Crypto] Decryption error: $e');
      return "[❌ Decryption error]";
    }
  }

  // ============================================================
  // ШИФРОВАНИЕ ФАЙЛОВ (НОВОЕ)
  // ============================================================

  /// Шифрует файл (байты)
  Future<List<int>> encryptFileBytes(List<int> fileBytes, {required String targetUid}) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (!_sharedSecrets.containsKey(targetUid)) throw StateError('No shared secret for $targetUid');

    try {
      // Шифруем байты файла так же, как текст
      final secretBox = await _algo.encrypt(
        fileBytes,
        secretKey: _sharedSecrets[targetUid]!,
      );
      // Возвращаем (nonce + ciphertext + mac)
      return secretBox.concatenation();
    } catch (e) {
      print('❌ [Crypto] File encryption failed: $e');
      throw CryptoException('File encryption failed: $e');
    }
  }

  /// Расшифровывает файл (байты)
  Future<List<int>> decryptFileBytes(List<int> encryptedBytes, {required String fromUid}) async {
    if (!_isInitialized) throw StateError('Cipher not initialized');
    if (!_sharedSecrets.containsKey(fromUid)) throw StateError('No key for $fromUid');

    try {
      final box = SecretBox.fromConcatenation(
        encryptedBytes,
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );
      
      final clearBytes = await _algo.decrypt(
        box,
        secretKey: _sharedSecrets[fromUid]!,
      );
      
      return clearBytes;
    } catch (e) {
      print('❌ [Crypto] File decryption error: $e');
      throw CryptoException('File decryption error');
    }
  }

  // ============================================================
  // ПОДПИСИ
  // ============================================================

  Future<String> signMessage(String text) async {
    if (_myEd25519KeyPair == null) throw StateError('Cipher not initialized');
    try {
      final signature = await _ed25519.sign(utf8.encode(text), keyPair: _myEd25519KeyPair!);
      return base64Encode(signature.bytes);
    } catch (e) {
      throw CryptoException('Failed to sign message: $e');
    }
  }

  Future<bool> verifySignature(String text, String signatureB64, String fromUid) async {
    if (!_contactSignKeys.containsKey(fromUid)) return false;
    try {
      final signature = Signature(base64Decode(signatureB64), publicKey: _contactSignKeys[fromUid]!);
      return await _ed25519.verify(utf8.encode(text), signature: signature);
    } catch (e) {
      return false;
    }
  }

  // ============================================================
  // LEGACY EXPORT (для бекапа)
  // ============================================================

  Future<String> exportPrivateKey(String password) async {
    if (_myX25519KeyPair == null) throw StateError('Cipher not initialized');
    try {
      final privateKeyBytes = await _myX25519KeyPair!.extractPrivateKeyBytes();
      final passwordKey = await _derivePassKey(password);
      final encrypted = await _algo.encrypt(privateKeyBytes, secretKey: passwordKey);
      return base64Encode(encrypted.concatenation());
    } catch (e) {
      throw CryptoException('Failed to export private key: $e');
    }
  }

  Future<void> importPrivateKey(String encryptedKeyB64, String password) async {
    try {
      final passwordKey = await _derivePassKey(password);
      final combined = base64Decode(encryptedKeyB64);
      final box = SecretBox.fromConcatenation(combined, nonceLength: _algo.nonceLength, macLength: _algo.macAlgorithm.macLength);
      final privateKeyBytes = await _algo.decrypt(box, secretKey: passwordKey);
      _myX25519KeyPair = await _x25519.newKeyPairFromSeed(privateKeyBytes);
      _isInitialized = true;
    } catch (e) {
      throw CryptoException('Failed to import private key: $e');
    }
  }

  Future<SecretKey> _derivePassKey(String password) async {
    return await Argon2id(memory: 32768, iterations: 3, parallelism: 4, hashLength: 32)
        .deriveKeyFromPassword(password: password, nonce: List.generate(16, (i) => i));
  }

  bool get isInitialized => _isInitialized;

  void dispose() {
    _sharedSecrets.clear();
    _contactPublicKeys.clear();
    _contactSignKeys.clear();
    _myX25519KeyPair = null;
    _myEd25519KeyPair = null;
    _isInitialized = false;
  }
}

/// Кастомное исключение для криптографических ошибок
class CryptoException implements Exception {
  final String message;
  CryptoException(this.message);
  @override
  String toString() => 'CryptoException: $message';
}

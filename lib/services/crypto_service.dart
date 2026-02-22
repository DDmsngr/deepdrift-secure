import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:argon2/argon2.dart';
import 'package:crypto/crypto.dart';

class CryptoService {
  final _algo = Chacha20.poly1305Aead();

  // 1. Генерация ключа через Argon2id (Стандарт)
  Future<SecretKey> deriveKey(String password) async {
    // В MVP соль фиксированная, в идеале — разная для каждого чата
    var parameters = Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      utf8.encode("deepdrift_static_salt"),
      version: Argon2Parameters.ARGON2_VERSION_13,
      iterations: 2,
      memory: 32768,
      lanes: 4,
    );
    var argon2 = Argon2();
    var hash = argon2.hashPasswordBytes(utf8.encode(password), parameters: parameters);
    return SecretKey(hash.slice(0, 32));
  }

  // 2. FHRG Сигнатура (Поведенческий маркер)
  String generateFHRGSignature(String text) {
    // Упрощенная модель FHRG из твоих наработок
    double z = 1.0;
    double lambda = 3.00001;
    double omega = (2 * pi) / log(lambda);
    
    // Хешируем текст для фазы
    var h = sha256.convert(utf8.encode(text)).bytes;
    double phi = (h[0] / 255) * 2 * pi;

    // Генерируем 4 байта хаоса
    List<int> sig = [];
    for (int i = 0; i < 4; i++) {
      double val = cos(omega * log(z) + phi);
      sig.add(((val + 1) * 127).floor());
      z += 0.1;
    }
    return base64Encode(sig);
  }

  // 3. Шифрование ChaCha20
  Future<String> encrypt(String text, SecretKey key) async {
    final secretBox = await _algo.encrypt(utf8.encode(text), secretKey: key);
    return base64Encode(secretBox.concatenation());
  }

  // 4. Дешифровка
  Future<String> decrypt(String b64Data, SecretKey key) async {
    try {
      final box = SecretBox.fromConcatenation(base64Decode(b64Data), 
        nonceLength: _algo.nonceLength, 
        macLength: _algo.macAlgorithm.macLength
      );
      final clearText = await _algo.decrypt(box, secretKey: key);
      return utf8.decode(clearText);
    } catch (e) { return "[DECRYPTION FAILED]"; }
  }
}

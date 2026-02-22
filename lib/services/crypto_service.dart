import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:argon2_flutter/argon2_flutter.dart';
import 'package:crypto/crypto.dart';

class CryptoService {
  final _algo = Chacha20.poly1305Aead();

  // 1. Генерация ключа через Argon2id (Flutter-safe)
  Future<SecretKey> deriveKey(String password) async {
    const salt = "deepdrift_static_salt"; // ⚠️ лучше потом сделать уникальной

    final result = await Argon2.hashPasswordString(
      password,
      salt: salt,
      iterations: 2,
      memory: 32768,
      parallelism: 4,
      length: 32,
    );

    final keyBytes = utf8.encode(result.hash).sublist(0, 32);
    return SecretKey(keyBytes);
  }

  // 2. FHRG сигнатура (твоя логика сохранена)
  String generateFHRGSignature(String text) {
    double z = 1.0;
    double lambda = 3.00001;
    double omega = (2 * pi) / log(lambda);

    var h = sha256.convert(utf8.encode(text)).bytes;
    double phi = (h[0] / 255) * 2 * pi;

    List<int> sig = [];
    for (int i = 0; i < 4; i++) {
      double val = cos(omega * log(z) + phi);
      sig.add(((val + 1) * 127).floor());
      z += 0.1;
    }

    return base64Encode(sig);
  }

  // 3. Шифрование
  Future<String> encrypt(String text, SecretKey key) async {
    final secretBox = await _algo.encrypt(
      utf8.encode(text),
      secretKey: key,
    );
    return base64Encode(secretBox.concatenation());
  }

  // 4. Дешифровка
  Future<String> decrypt(String b64Data, SecretKey key) async {
    try {
      final box = SecretBox.fromConcatenation(
        base64Decode(b64Data),
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );

      final clearText = await _algo.decrypt(box, secretKey: key);
      return utf8.decode(clearText);
    } catch (e) {
      return "[DECRYPTION FAILED]";
    }
  }
}

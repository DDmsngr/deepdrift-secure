import 'dart:convert';
import 'dart:math';

// 👇 алиасы решают конфликт
import 'package:cryptography/cryptography.dart' as crypto_lib;
import 'package:crypto/crypto.dart' as hash_lib;

class CryptoService {
  final _algo = crypto_lib.Chacha20.poly1305Aead();

  final _kdf = crypto_lib.Pbkdf2(
    macAlgorithm: crypto_lib.Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );

  // 1. Генерация ключа
  Future<crypto_lib.SecretKey> deriveKey(String password) async {
    final salt = utf8.encode("deepdrift_static_salt");

    final secretKey = await _kdf.deriveKey(
      secretKey: crypto_lib.SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    return secretKey;
  }

  // 2. FHRG сигнатура
  String generateFHRGSignature(String text) {
    double z = 1.0;
    double lambda = 3.00001;
    double omega = (2 * pi) / log(lambda);

    var h = hash_lib.sha256.convert(utf8.encode(text)).bytes;
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
  Future<String> encrypt(String text, crypto_lib.SecretKey key) async {
    final secretBox = await _algo.encrypt(
      utf8.encode(text),
      secretKey: key,
    );

    return base64Encode(secretBox.concatenation());
  }

  // 4. Дешифровка
  Future<String> decrypt(String b64Data, crypto_lib.SecretKey key) async {
    try {
      final box = crypto_lib.SecretBox.fromConcatenation(
        base64Decode(b64Data),
        nonceLength: _algo.nonceLength,
        macLength: _algo.macAlgorithm.macLength,
      );

      final clearText = await _algo.decrypt(box, secretKey: key);
      return utf8.decode(clearText);
    } catch (_) {
      return "[DECRYPTION FAILED]";
    }
  }
}

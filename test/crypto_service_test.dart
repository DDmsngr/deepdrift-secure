import 'package:flutter_test/flutter_test.dart';
import 'package:DDchat/crypto_service.dart';
import 'dart:convert';

void main() {
  group('SecureCipher', () {
    test('generateSalt returns base64 of 32 bytes', () {
      final salt = SecureCipher.generateSalt();
      final bytes = base64Decode(salt);
      expect(bytes.length, 32);
    });

    test('encrypt/decrypt roundtrip with password', () async {
      final cipher = SecureCipher();
      await cipher.init('test_password', SecureCipher.generateSalt());
      final exported = await cipher.exportBothKeys('test_password');

      final restored = SecureCipher();
      await restored.init(
        'test_password',
        SecureCipher.generateSalt(),
        encryptedX25519Key: exported['x25519'],
        encryptedEd25519Key: exported['ed25519'],
      );

      expect(await restored.getMyPublicKey(), await cipher.getMyPublicKey());
      expect(await restored.getMySigningKey(), await cipher.getMySigningKey());
    });

    test('wrong password throws CryptoException', () async {
      final cipher = SecureCipher();
      await cipher.init('correct_password', SecureCipher.generateSalt());
      final exported = await cipher.exportBothKeys('correct_password');

      final restored = SecureCipher();
      await expectLater(
        restored.init(
          'wrong_password',
          SecureCipher.generateSalt(),
          encryptedX25519Key: exported['x25519'],
          encryptedEd25519Key: exported['ed25519'],
        ),
        throwsA(isA<CryptoException>()),
      );
    });

    test('E2E text encryption roundtrip', () async {
      final alice = SecureCipher();
      final bob = SecureCipher();
      await alice.init('alice_pass', SecureCipher.generateSalt());
      await bob.init('bob_pass', SecureCipher.generateSalt());

      final alicePub = await alice.getMyPublicKey();
      final bobPub = await bob.getMyPublicKey();
      final aliceSign = await alice.getMySigningKey();
      final bobSign = await bob.getMySigningKey();

      await alice.establishSharedSecret('bob', bobPub, theirSignKeyB64: bobSign);
      await bob.establishSharedSecret('alice', alicePub, theirSignKeyB64: aliceSign);

      const message = 'Hello, Bob! This is a secret message.';
      final encrypted = await alice.encryptText(message, targetUid: 'bob');
      final decrypted = await bob.decryptText(encrypted, fromUid: 'alice');

      expect(decrypted, message);
    });
  });
}

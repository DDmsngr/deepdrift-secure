import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto_lib;
import 'package:crypto/crypto.dart' as hash_lib;

import 'storage_service.dart';

/// Full-featured E2E cipher used throughout the app.
///
/// Key pairs:
///   • X25519  – ECDH for shared-secret derivation (encryption)
///   • Ed25519 – signing / verification
///
/// All state is kept in memory. Keys are persisted (encrypted) via
/// [StorageService] so that they survive app restarts.
class SecureCipher {
  // ── Algorithms ────────────────────────────────────────────────────────────
  final _chacha   = crypto_lib.Chacha20.poly1305Aead();
  final _x25519   = crypto_lib.X25519();
  final _ed25519  = crypto_lib.Ed25519();
  final _pbkdf2   = crypto_lib.Pbkdf2(
    macAlgorithm: crypto_lib.Hmac.sha256(),
    iterations:   100000,
    bits:         256,
  );

  // ── State ─────────────────────────────────────────────────────────────────
  bool _initialized = false;
  bool get isInitialized => _initialized;

  crypto_lib.SimpleKeyPair?   _x25519KeyPair;
  crypto_lib.SimpleKeyPair?   _ed25519KeyPair;

  /// uid → derived shared secret key (ChaCha20 key)
  final _sharedSecrets = <String, crypto_lib.SecretKey>{};

  /// uid → their Ed25519 public key bytes (for signature verification)
  final _theirSignKeys = <String, crypto_lib.SimplePublicKey>{};

  /// groupId → group AES/ChaCha key bytes
  final _groupKeys = <String, List<int>>{};

  // ── Initialisation ────────────────────────────────────────────────────────

  /// Derives a wrapping key from [password]+[salt], then either
  /// generates fresh key pairs or decrypts the supplied ones.
  Future<void> init(
    String password,
    String salt, {
    String? encryptedX25519Key,
    String? encryptedEd25519Key,
  }) async {
    _initialized = false;
    final wrapKey = await _deriveWrapKey(password, salt);

    if (encryptedX25519Key != null && encryptedEd25519Key != null) {
      // Restore existing keys
      try {
        final x25519Bytes  = await _decryptBytes(encryptedX25519Key,  wrapKey);
        final ed25519Bytes = await _decryptBytes(encryptedEd25519Key, wrapKey);
        _x25519KeyPair  = await _x25519.newKeyPairFromSeed(x25519Bytes);
        _ed25519KeyPair = await _ed25519.newKeyPairFromSeed(ed25519Bytes);
        _initialized = true;
      } catch (_) {
        // Wrong password → stay un-initialized so the caller can detect it
        _initialized = false;
        return;
      }
    } else {
      // Fresh identity
      _x25519KeyPair  = await _x25519.newKeyPair();
      _ed25519KeyPair = await _ed25519.newKeyPair();
      _initialized = true;
    }
  }

  // ── Public key accessors ──────────────────────────────────────────────────

  Future<String> getMyPublicKey() async {
    final pub = await _x25519KeyPair!.extractPublicKey();
    return base64Encode(pub.bytes);
  }

  Future<String> getMySigningKey() async {
    final pub = await _ed25519KeyPair!.extractPublicKey();
    return base64Encode(pub.bytes);
  }

  // ── Key export (password-encrypted) ──────────────────────────────────────

  Future<Map<String, String>> exportBothKeys(String password) async {
    final salt    = generateSalt();
    final wrapKey = await _deriveWrapKey(password, salt);

    final x25519Seed  = await _x25519KeyPair!.extractPrivateKeyBytes();
    final ed25519Seed = await _ed25519KeyPair!.extractPrivateKeyBytes();

    return {
      'x25519':  await _encryptBytes(x25519Seed,  wrapKey),
      'ed25519': await _encryptBytes(ed25519Seed, wrapKey),
      'salt':    salt,
    };
  }

  // ── Shared-secret establishment ───────────────────────────────────────────

  Future<void> establishSharedSecret(
    String peerUid,
    String theirX25519B64, {
    String? theirSignKeyB64,
  }) async {
    final theirPublic = crypto_lib.SimplePublicKey(
      base64Decode(theirX25519B64),
      type: crypto_lib.KeyPairType.x25519,
    );
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair:   _x25519KeyPair!,
      remotePublicKey: theirPublic,
    );
    _sharedSecrets[peerUid] = sharedSecret;

    if (theirSignKeyB64 != null) {
      _theirSignKeys[peerUid] = crypto_lib.SimplePublicKey(
        base64Decode(theirSignKeyB64),
        type: crypto_lib.KeyPairType.ed25519,
      );
    }
  }

  bool hasSharedSecret(String uid) => _sharedSecrets.containsKey(uid);

  void clearSharedSecret(String uid) {
    _sharedSecrets.remove(uid);
    _theirSignKeys.remove(uid);
  }

  /// Load cached public keys from storage and re-establish the shared secret.
  Future<bool> tryLoadCachedKeys(String uid, StorageService storage) async {
    final x25519B64  = storage.getCachedX25519Key(uid);
    final ed25519B64 = storage.getCachedEd25519Key(uid);
    if (x25519B64 == null) return false;
    await establishSharedSecret(uid, x25519B64, theirSignKeyB64: ed25519B64);
    return true;
  }

  // ── Text encryption / decryption ──────────────────────────────────────────

  Future<String> encryptText(String plaintext, {required String targetUid}) async {
    final key = _sharedSecrets[targetUid];
    if (key == null) return '[NO_SHARED_SECRET]';
    final box = await _chacha.encrypt(utf8.encode(plaintext), secretKey: key);
    return base64Encode(box.concatenation());
  }

  Future<String> decryptText(String cipherB64, {required String fromUid}) async {
    try {
      final key = _sharedSecrets[fromUid];
      if (key == null) return '[NO_SHARED_SECRET]';
      final box = crypto_lib.SecretBox.fromConcatenation(
        base64Decode(cipherB64),
        nonceLength: _chacha.nonceLength,
        macLength:   _chacha.macAlgorithm.macLength,
      );
      final clear = await _chacha.decrypt(box, secretKey: key);
      return utf8.decode(clear);
    } catch (_) {
      return '[DECRYPTION_FAILED]';
    }
  }

  // ── File bytes encryption / decryption ───────────────────────────────────

  Future<Uint8List> encryptFileBytes(Uint8List bytes, {required String targetUid}) async {
    final key = _sharedSecrets[targetUid];
    if (key == null) return bytes;
    final box = await _chacha.encrypt(bytes, secretKey: key);
    return Uint8List.fromList(box.concatenation());
  }

  Future<Uint8List?> decryptFileBytes(Uint8List bytes, {required String fromUid}) async {
    try {
      final key = _sharedSecrets[fromUid];
      if (key == null) return null;
      final box = crypto_lib.SecretBox.fromConcatenation(
        bytes,
        nonceLength: _chacha.nonceLength,
        macLength:   _chacha.macAlgorithm.macLength,
      );
      final clear = await _chacha.decrypt(box, secretKey: key);
      return Uint8List.fromList(clear);
    } catch (_) {
      return null;
    }
  }

  // ── Signing ───────────────────────────────────────────────────────────────

  Future<String> signMessage(String text) async {
    final sig = await _ed25519.sign(
      utf8.encode(text),
      keyPair: _ed25519KeyPair!,
    );
    return base64Encode(sig.bytes);
  }

  Future<bool> verifySignature(String text, String signatureB64, String fromUid) async {
    final theirKey = _theirSignKeys[fromUid];
    if (theirKey == null) return false;
    try {
      final sig = crypto_lib.Signature(
        base64Decode(signatureB64),
        publicKey: theirKey,
      );
      return await _ed25519.verify(utf8.encode(text), signature: sig);
    } catch (_) {
      return false;
    }
  }

  /// Sign a server-issued nonce (used for auth challenge).
  Future<String> signChallenge(String nonce) => signMessage(nonce);

  // ── Group keys ────────────────────────────────────────────────────────────

  List<int> generateGroupKey() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256));
  }

  void setGroupKey(String groupId, List<int> key) {
    _groupKeys[groupId] = key;
  }

  Future<String> encryptGroupKeyFor(String uid, List<int> groupKeyBytes) async {
    final wrappedKey = crypto_lib.SecretKey(groupKeyBytes);
    // Encrypt the raw group-key bytes with the peer's shared secret
    final peerKey = _sharedSecrets[uid];
    if (peerKey == null) throw StateError('No shared secret for $uid');
    final box = await _chacha.encrypt(groupKeyBytes, secretKey: peerKey);
    return base64Encode(box.concatenation());
  }

  Future<List<int>> decryptGroupKey(String fromUid, String encryptedB64) async {
    final peerKey = _sharedSecrets[fromUid];
    if (peerKey == null) throw StateError('No shared secret for $fromUid');
    final box = crypto_lib.SecretBox.fromConcatenation(
      base64Decode(encryptedB64),
      nonceLength: _chacha.nonceLength,
      macLength:   _chacha.macAlgorithm.macLength,
    );
    return await _chacha.decrypt(box, secretKey: peerKey);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Generate a random 32-byte salt, base64-encoded.
  static String generateSalt() {
    final rng   = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Encode(bytes);
  }

  Future<crypto_lib.SecretKey> _deriveWrapKey(String password, String salt) {
    return _pbkdf2.deriveKey(
      secretKey: crypto_lib.SecretKey(utf8.encode(password)),
      nonce:     base64Decode(salt),
    );
  }

  Future<String> _encryptBytes(List<int> data, crypto_lib.SecretKey key) async {
    final box = await _chacha.encrypt(data, secretKey: key);
    return base64Encode(box.concatenation());
  }

  Future<List<int>> _decryptBytes(String b64, crypto_lib.SecretKey key) async {
    final box = crypto_lib.SecretBox.fromConcatenation(
      base64Decode(b64),
      nonceLength: _chacha.nonceLength,
      macLength:   _chacha.macAlgorithm.macLength,
    );
    return await _chacha.decrypt(box, secretKey: key);
  }
}

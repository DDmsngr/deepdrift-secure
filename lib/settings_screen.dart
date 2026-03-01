import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'storage_service.dart';
import 'crypto_service.dart';

class SettingsScreen extends StatefulWidget {
  final StorageService storage;
  final SecureCipher   cipher;
  final String         myUid;

  const SettingsScreen({
    super.key,
    required this.storage,
    required this.cipher,
    required this.myUid,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool    _autoSavePhotos      = false;
  bool    _notificationsSound  = true;
  String? _myPublicKeyFingerprint;
  bool    _loadingFingerprint  = false;

  @override
  void initState() {
    super.initState();
    _autoSavePhotos     = widget.storage.getSetting('auto_save_photos',    defaultValue: false);
    _notificationsSound = widget.storage.getSetting('notifications_sound', defaultValue: true);
    _loadFingerprint();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Identity fingerprint (только МОИ ключи)
  //
  // Это отпечаток идентичности УСТРОЙСТВА — хэш обоих моих публичных ключей
  // (X25519 + Ed25519). Он НЕ меняется при смене собеседника.
  //
  // Отличие от getSecurityCode() в ChatScreen:
  //   • getSecurityCode() — fingerprint конкретной E2E-сессии (оба ключа обоих
  //     участников), нужен для обнаружения MITM в конкретном чате.
  //   • _loadFingerprint() здесь — "кто я", можно публично поделиться
  //     для подтверждения своей идентичности на другом канале.
  //
  // Алгоритм: SHA-256( base64decode(myX25519PubKey) | base64decode(myEd25519PubKey) )
  // → 64 hex-символа → 8 групп по 5: "XXXXX XXXXX XXXXX ..."
  // ──────────────────────────────────────────────────────────────────────────
  Future<void> _loadFingerprint() async {
    if (!mounted) return;
    setState(() => _loadingFingerprint = true);
    try {
      final x25519B64  = await widget.cipher.getMyPublicKey();
      final ed25519B64 = await widget.cipher.getMySigningKey();

      // Декодируем из base64 → сырые байты, затем SHA-256 конкатенации
      final x25519Bytes  = base64Decode(x25519B64);
      final ed25519Bytes = base64Decode(ed25519B64);
      final combined     = [...x25519Bytes, ...ed25519Bytes];
      final hash         = sha256.convert(combined);
      final hex          = hash.toString().toUpperCase();

      // Форматируем: 8 групп по 5 символов (первые 40 из 64)
      final buffer = StringBuffer();
      for (int i = 0; i < 8; i++) {
        if (i > 0) buffer.write(' ');
        buffer.write(hex.substring(i * 5, i * 5 + 5));
      }

      if (mounted) {
        setState(() {
          _myPublicKeyFingerprint = buffer.toString();
          _loadingFingerprint     = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _myPublicKeyFingerprint = 'Error loading key';
          _loadingFingerprint     = false;
        });
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────────────────────

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: const Color(0xFF1A4A2E)),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Смена пароля
  //
  // 🔴-1 dependency FIX: exportBothKeys() теперь генерирует свежий случайный
  // Argon2-нонс при каждом вызове. Старые ключи в Hive перезаписываются
  // новым шифртекстом с новым нонсом — каждая смена пароля производит
  // уникальный KDF-производный ключ даже если новый пароль совпадает со старым.
  // ──────────────────────────────────────────────────────────────────────────

  void _showChangePasswordDialog() {
    final oldCtrl     = TextEditingController();
    final newCtrl     = TextEditingController();
    final confirmCtrl = TextEditingController();
    // Loading state внутри диалога предотвращает двойное нажатие
    var isLoading = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1F3C),
          title: Text('Смена пароля', style: GoogleFonts.orbitron(fontSize: 14)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '⚠️ После смены пароля все сессии на других устройствах потребуют новый пароль.',
                style: TextStyle(color: Colors.orange, fontSize: 11),
              ),
              const SizedBox(height: 16),
              _passField(oldCtrl,     'Текущий пароль'),
              const SizedBox(height: 10),
              _passField(newCtrl,     'Новый пароль'),
              const SizedBox(height: 10),
              _passField(confirmCtrl, 'Повтори новый пароль'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(dialogContext),
              child: const Text('ОТМЕНА'),
            ),
            ElevatedButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      // ── Валидация ──────────────────────────────────────
                      final savedPwd = widget.storage.getSetting('user_password') as String?;
                      if (oldCtrl.text != savedPwd) {
                        _showError('Неверный текущий пароль');
                        return;
                      }
                      if (newCtrl.text.length < 8) {
                        _showError('Новый пароль должен быть не менее 8 символов');
                        return;
                      }
                      if (newCtrl.text != confirmCtrl.text) {
                        _showError('Новые пароли не совпадают');
                        return;
                      }

                      // ── Перешифровка ────────────────────────────────────
                      setDialogState(() => isLoading = true);
                      try {
                        // exportBothKeys() генерирует свежий Argon2-нонс —
                        // новый пароль + новый нонс = новый ключ шифрования.
                        final newKeys = await widget.cipher.exportBothKeys(newCtrl.text);

                        await widget.storage.saveSetting('user_password',       newCtrl.text);
                        await widget.storage.saveSetting('encrypted_x25519_key', newKeys['x25519']!);
                        await widget.storage.saveSetting('encrypted_ed25519_key', newKeys['ed25519']!);

                        if (mounted) Navigator.pop(dialogContext);
                        _showSuccess('Пароль успешно изменён');
                      } catch (e) {
                        setDialogState(() => isLoading = false);
                        _showError('Ошибка смены пароля: $e');
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyan,
                foregroundColor: Colors.black,
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : const Text('СМЕНИТЬ'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _passField(TextEditingController ctrl, String label) {
    return TextField(
      controller:  ctrl,
      obscureText: true,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText:  label,
        labelStyle: const TextStyle(color: Colors.white54),
        filled:     true,
        fillColor:  const Color(0xFF0A0E27),
        border:     const OutlineInputBorder(),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Identity fingerprint диалог
  // ──────────────────────────────────────────────────────────────────────────

  void _showFingerprintDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Row(
          children: [
            const Icon(Icons.fingerprint, color: Colors.cyan, size: 20),
            const SizedBox(width: 8),
            Text('Отпечаток устройства', style: GoogleFonts.orbitron(fontSize: 13)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Это идентификатор твоего устройства. Поделись им через другой канал, чтобы контакты могли убедиться, что общаются именно с тобой.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            // Поясняем отличие от session fingerprint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.cyan.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.cyan.withValues(alpha: 0.2)),
              ),
              child: const Text(
                '💡 Для проверки конкретного чата (защита от MITM) используй Код безопасности в том чате.',
                style: TextStyle(color: Colors.white54, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E27),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.cyan.withValues(alpha: 0.3)),
              ),
              child: Text(
                _myPublicKeyFingerprint ?? '...',
                style: GoogleFonts.sourceCodePro(
                  color: Colors.cyan, fontSize: 15, letterSpacing: 2,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Мой ID: ${widget.myUid}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _myPublicKeyFingerprint ?? ''));
              _showSuccess('Отпечаток скопирован');
              Navigator.pop(context);
            },
            child: const Text('КОПИРОВАТЬ'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ЗАКРЫТЬ'),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Настройки', style: GoogleFonts.orbitron(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [

          // ── УВЕДОМЛЕНИЯ ────────────────────────────────────────────────────
          _sectionHeader('УВЕДОМЛЕНИЯ'),

          _switchTile(
            icon:     Icons.volume_up_outlined,
            title:    'Звук',
            subtitle: 'Воспроизводить звук для входящих сообщений',
            value:    _notificationsSound,
            onChanged: (val) async {
              setState(() => _notificationsSound = val);
              await widget.storage.saveSetting('notifications_sound', val);
            },
          ),

          // ── МЕДИА ──────────────────────────────────────────────────────────
          _sectionHeader('МЕДИА'),

          _switchTile(
            icon:     Icons.save_alt_outlined,
            title:    'Автосохранение фото',
            subtitle: 'Автоматически сохранять входящие фото в галерею',
            value:    _autoSavePhotos,
            onChanged: (val) async {
              setState(() => _autoSavePhotos = val);
              await widget.storage.saveSetting('auto_save_photos', val);
            },
          ),

          // ── БЕЗОПАСНОСТЬ ───────────────────────────────────────────────────
          _sectionHeader('БЕЗОПАСНОСТЬ'),

          _actionTile(
            icon:     Icons.lock_outline,
            title:    'Сменить пароль шифрования',
            subtitle: 'Перешифровать ключи новым паролем',
            onTap:    _showChangePasswordDialog,
          ),

          _actionTile(
            icon:      Icons.fingerprint,
            iconColor: Colors.cyan,
            title:     'Отпечаток устройства',
            subtitle:  _loadingFingerprint
                ? 'Загрузка...'
                : (_myPublicKeyFingerprint != null
                    ? '${_myPublicKeyFingerprint!.substring(0, 11)}...'
                    : 'Нажми для просмотра'),
            onTap: _loadingFingerprint ? null : _showFingerprintDialog,
          ),

          // ── О ПРИЛОЖЕНИИ ───────────────────────────────────────────────────
          _sectionHeader('О ПРИЛОЖЕНИИ'),

          _infoTile(
            icon:  Icons.badge_outlined,
            title: 'Мой ID',
            value: widget.myUid,
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.myUid));
              _showSuccess('ID скопирован');
            },
          ),

          _infoTile(
            icon:  Icons.info_outline,
            title: 'Версия',
            value: 'DDChat 1.0.0',
          ),

          _infoTile(
            icon:  Icons.security,
            title: 'Шифрование',
            value: 'X25519 + Ed25519 + ChaCha20',
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Вспомогательные виджеты
  // ──────────────────────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.cyan, fontSize: 11,
          fontWeight: FontWeight.bold, letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _switchTile({
    required IconData         icon,
    required String           title,
    required String           subtitle,
    required bool             value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SwitchListTile(
        secondary: Icon(icon, color: Colors.white54, size: 22),
        title:     Text(title,    style: const TextStyle(color: Colors.white,   fontSize: 15)),
        subtitle:  Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        value:     value,
        onChanged: onChanged,
        activeColor: Colors.cyan,
      ),
    );
  }

  Widget _actionTile({
    required IconData  icon,
    Color              iconColor = Colors.white54,
    required String    title,
    required String    subtitle,
    VoidCallback?      onTap,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading:  Icon(icon, color: iconColor, size: 22),
        title:    Text(title,    style: const TextStyle(color: Colors.white,   fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        trailing: onTap != null
            ? const Icon(Icons.chevron_right, color: Colors.white38, size: 20)
            : null,
        onTap: onTap,
      ),
    );
  }

  Widget _infoTile({
    required IconData  icon,
    required String    title,
    required String    value,
    VoidCallback?      onTap,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: Colors.white54, size: 22),
        title:   Text(title, style: const TextStyle(color: Colors.white, fontSize: 15)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value, style: const TextStyle(color: Colors.white38, fontSize: 13)),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              const Icon(Icons.copy_outlined, color: Colors.white24, size: 14),
            ],
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

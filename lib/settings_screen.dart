import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'storage_service.dart';
import 'crypto_service.dart';

class SettingsScreen extends StatefulWidget {
  final StorageService  storage;
  final SecureCipher    cipher;
  final String          myUid;
  /// Callback для открытия диалога "Восстановить / Сменить аккаунт" из HomeScreen
  final VoidCallback?   onSwitchAccount;
  /// Callback для полного удаления аккаунта
  final VoidCallback?   onDeleteAccount;

  const SettingsScreen({
    super.key,
    required this.storage,
    required this.cipher,
    required this.myUid,
    this.onSwitchAccount,
    this.onDeleteAccount,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool    _autoSavePhotos      = false;
  bool    _notificationsSound  = true;
  bool    _appLockEnabled      = false;
  String? _myPublicKeyFingerprint;
  bool    _loadingFingerprint  = false;

  @override
  void initState() {
    super.initState();
    _autoSavePhotos     = widget.storage.getSetting('auto_save_photos',    defaultValue: false);
    _notificationsSound = widget.storage.getSetting('notifications_sound', defaultValue: true);
    _appLockEnabled     = widget.storage.getSetting('app_lock_enabled',    defaultValue: false);
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
      // Читаем из Hive-кэша (сохраняется при первой инициализации ключей).
      // Это гарантирует, что fingerprint НЕ меняется при каждом запуске / APK-обновлении.
      final cached = widget.storage.getSetting('cached_key_fingerprint') as String?;

      final String x25519B64;
      final String ed25519B64;

      if (cached != null && cached.contains(':')) {
        final parts = cached.split(':');
        x25519B64  = parts[0];
        ed25519B64 = parts[1];
      } else {
        // Fallback: вычисляем из текущих ключей (первый запуск после обновления)
        x25519B64  = await widget.cipher.getMyPublicKey();
        ed25519B64 = await widget.cipher.getMySigningKey();
      }

      // SHA-256(x25519_pubkey || ed25519_pubkey)
      final x25519Bytes  = base64Decode(x25519B64);
      final ed25519Bytes = base64Decode(ed25519B64);
      final combined     = [...x25519Bytes, ...ed25519Bytes];
      final hash         = sha256.convert(combined);
      final hex          = hash.toString().toUpperCase();

      // 8 групп по 5 символов
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
          _myPublicKeyFingerprint = 'Ошибка загрузки ключа';
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

          // ── АККАУНТ ────────────────────────────────────────────────────────
          _sectionHeader('АККАУНТ'),

          ListTile(
            leading: const Icon(Icons.switch_account, color: Color(0xFF00D9FF)),
            title: const Text('Сменить аккаунт',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text('Восстановить другой аккаунт из файла резервной копии',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white24),
            onTap: () {
              if (widget.onSwitchAccount != null) {
                Navigator.pop(context); // Закрываем настройки
                Future.delayed(const Duration(milliseconds: 300), () {
                  widget.onSwitchAccount!();
                });
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Вернитесь на главный экран для смены аккаунта'),
                  ),
                );
              }
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

          ListTile(
            leading: const Icon(Icons.new_releases_outlined, color: Colors.cyan),
            title: const Text('Что нового', style: TextStyle(color: Colors.white)),
            subtitle: const Text('История обновлений', style: TextStyle(color: Colors.white38, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white24),
            onTap: () => _showChangelog(context),
          ),

          _infoTile(
            icon:  Icons.security,
            title: 'Шифрование',
            value: 'X25519 + Ed25519 + ChaCha20',
          ),

          const SizedBox(height: 8),

          // ── БЛОКИРОВКА ─────────────────────────────────────────────────────
          _sectionHeader('БЛОКИРОВКА'),

          _switchTile(
            icon:     Icons.lock_clock_outlined,
            title:    'Блокировать при уходе в фон',
            subtitle: _appLockEnabled
                ? 'PIN установлен — нажми чтобы изменить'
                : 'Придумай PIN для блокировки экрана',
            value:    _appLockEnabled,
            onChanged: (val) async {
              if (val) {
                // Включаем → сначала задать PIN
                final pinSet = await _showSetPinDialog();
                if (!pinSet) return; // отменил — не включаем
              } else {
                // Выключаем → спрашиваем текущий PIN для подтверждения
                final ok = await _showConfirmPinDialog();
                if (!ok) return;
                await widget.storage.deleteSetting('app_lock_pin');
              }
              setState(() => _appLockEnabled = val);
              await widget.storage.saveSetting('app_lock_enabled', val);
            },
          ),

          // Кнопка смены PIN (видна только если блокировка включена)
          if (_appLockEnabled)
            ListTile(
              leading: const Icon(Icons.dialpad, color: Color(0xFF00D9FF)),
              title: const Text('Изменить PIN-код',
                  style: TextStyle(color: Colors.white70)),
              subtitle: const Text('Задать новый PIN для блокировки',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right, color: Colors.white24),
              onTap: () async {
                final ok = await _showConfirmPinDialog();
                if (!ok) return;
                await _showSetPinDialog();
              },
            ),

          // ── ОПАСНАЯ ЗОНА ───────────────────────────────────────────────────
          _sectionHeader('ОПАСНАЯ ЗОНА'),

          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Удалить аккаунт',
                style: TextStyle(color: Colors.red)),
            subtitle: const Text('Удалить все данные и ключи с устройства',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, color: Colors.red),
            onTap: () => _showDeleteAccountDialog(),
          ),

          const SizedBox(height: 8),

          // ── Правовая информация ───────────────────────────────────────────
          _sectionHeader('⚖️  ПРАВОВАЯ ИНФОРМАЦИЯ'),

          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined, color: Colors.cyan),
            title: const Text('Политика конфиденциальности',
                style: TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white24),
            onTap: () => _showLegalDoc(
              context,
              title: 'Политика конфиденциальности',
              assetPath: 'assets/privacy_policy.md',
            ),
          ),

          ListTile(
            leading: const Icon(Icons.gavel_outlined, color: Colors.cyan),
            title: const Text('Условия использования',
                style: TextStyle(color: Colors.white)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white24),
            onTap: () => _showLegalDoc(
              context,
              title: 'Условия использования',
              assetPath: 'assets/terms_of_service.md',
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Вспомогательные виджеты
  // ──────────────────────────────────────────────────────────────────────────

  /// Диалог установки нового PIN-кода (4–12 цифр).
  /// Возвращает true если PIN успешно сохранён.
  Future<bool> _showSetPinDialog() async {
    final pin1Ctrl = TextEditingController();
    final pin2Ctrl = TextEditingController();
    String? errorText;
    bool saved = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF1A1F3C),
          title: Text('Установить PIN-код',
              style: GoogleFonts.orbitron(
                  color: const Color(0xFF00D9FF), fontSize: 14)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Придумай числовой PIN от 4 до 12 цифр.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller:   pin1Ctrl,
                keyboardType: TextInputType.number,
                obscureText:  true,
                maxLength:    12,
                style: const TextStyle(color: Colors.white, letterSpacing: 6),
                decoration: InputDecoration(
                  labelText:     'Новый PIN',
                  labelStyle:    const TextStyle(color: Colors.white54),
                  counterStyle:  const TextStyle(color: Colors.white38),
                  filled:        true,
                  fillColor:     const Color(0xFF0A0E27),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF00D9FF)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller:   pin2Ctrl,
                keyboardType: TextInputType.number,
                obscureText:  true,
                maxLength:    12,
                style: const TextStyle(color: Colors.white, letterSpacing: 6),
                onSubmitted: (_) async {
                  final p1 = pin1Ctrl.text;
                  final p2 = pin2Ctrl.text;
                  if (p1.length < 4) {
                    setS(() => errorText = 'Минимум 4 цифры');
                    return;
                  }
                  if (p1 != p2) {
                    setS(() => errorText = 'PIN-коды не совпадают');
                    return;
                  }
                  await widget.storage.saveSetting('app_lock_pin', p1);
                  saved = true;
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                decoration: InputDecoration(
                  labelText:     'Повтори PIN',
                  labelStyle:    const TextStyle(color: Colors.white54),
                  counterStyle:  const TextStyle(color: Colors.white38),
                  errorText:     errorText,
                  filled:        true,
                  fillColor:     const Color(0xFF0A0E27),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF00D9FF)),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ОТМЕНА',
                  style: TextStyle(color: Colors.white38)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D9FF),
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                final p1 = pin1Ctrl.text;
                final p2 = pin2Ctrl.text;
                if (p1.length < 4) {
                  setS(() => errorText = 'Минимум 4 цифры');
                  return;
                }
                if (p1 != p2) {
                  setS(() => errorText = 'PIN-коды не совпадают');
                  return;
                }
                await widget.storage.saveSetting('app_lock_pin', p1);
                saved = true;
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('СОХРАНИТЬ'),
            ),
          ],
        ),
      ),
    );

    pin1Ctrl.dispose();
    pin2Ctrl.dispose();
    return saved;
  }

  /// Диалог подтверждения текущего PIN (для смены или отключения блокировки).
  Future<bool> _showConfirmPinDialog() async {
    final pinCtrl   = TextEditingController();
    String? errText;
    bool confirmed  = false;
    final savedPin  = widget.storage.getSetting('app_lock_pin') as String? ?? '';

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF1A1F3C),
          title: Text('Подтверди PIN',
              style: GoogleFonts.orbitron(
                  color: const Color(0xFF00D9FF), fontSize: 14)),
          content: TextField(
            controller:   pinCtrl,
            keyboardType: TextInputType.number,
            obscureText:  true,
            maxLength:    12,
            autofocus:    true,
            style: const TextStyle(color: Colors.white, letterSpacing: 6),
            decoration: InputDecoration(
              labelText:     'Текущий PIN',
              labelStyle:    const TextStyle(color: Colors.white54),
              counterStyle:  const TextStyle(color: Colors.white38),
              errorText:     errText,
              filled:        true,
              fillColor:     const Color(0xFF0A0E27),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF00D9FF)),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ОТМЕНА',
                  style: TextStyle(color: Colors.white38)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D9FF),
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                if (pinCtrl.text == savedPin) {
                  confirmed = true;
                  Navigator.pop(ctx);
                } else {
                  setS(() => errText = 'Неверный PIN');
                  pinCtrl.clear();
                }
              },
              child: const Text('ПОДТВЕРДИТЬ'),
            ),
          ],
        ),
      ),
    );

    pinCtrl.dispose();
    return confirmed;
  }

  void _showDeleteAccountDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        bool confirmed = false;
        return StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            backgroundColor: const Color(0xFF1A1F3C),
            title: Row(
              children: [
                const Icon(Icons.warning_amber, color: Colors.red, size: 22),
                const SizedBox(width: 8),
                Text('Удалить аккаунт',
                    style: GoogleFonts.orbitron(color: Colors.red, fontSize: 13)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '⚠️ Это действие необратимо. Будут удалены:',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                const Text('• Все сообщения и медиафайлы',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const Text('• Ключи шифрования',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const Text('• Список контактов и настройки',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: const Text(
                    '🔑 Восстановление невозможно без файла резервной копии. '
                    'Убедись, что ты сделал бэкап.',
                    style: TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Checkbox(
                      value: confirmed,
                      activeColor: Colors.red,
                      onChanged: (v) => setS(() => confirmed = v ?? false),
                    ),
                    const Expanded(
                      child: Text('Я понимаю, что данные нельзя восстановить',
                          style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                onPressed: confirmed
                    ? () {
                        Navigator.pop(ctx);
                        if (widget.onDeleteAccount != null) {
                          widget.onDeleteAccount!();
                        }
                      }
                    : null,
                child: const Text('УДАЛИТЬ ВСЁ'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showChangelog(BuildContext context) {
    const changes = [
      (icon: '🎥', text: 'Видео-заметки в формате бокс вместо кружочков'),
      (icon: '👥', text: 'Групповые чаты с E2E-шифрованием'),
      (icon: '🔑', text: 'Стабильный Fingerprint — не меняется при обновлении APK'),
      (icon: '☁️', text: 'Хранилище медиафайлов переехало на Cloudflare R2'),
      (icon: '🛡️', text: 'Ed25519 аутентификация — UID нельзя угнать'),
      (icon: '🔐', text: 'Резервная копия ключей при регистрации'),
      (icon: '📥', text: 'Сохранение фото/видео в галерею по долгому нажатию'),
      (icon: '🌐', text: 'Интерфейс полностью на русском языке'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, ctrl) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  const Icon(Icons.new_releases_outlined, color: Color(0xFF00D9FF)),
                  const SizedBox(width: 10),
                  Text('Что нового',
                      style: GoogleFonts.orbitron(
                          color: const Color(0xFF00D9FF), fontSize: 16)),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: changes.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(changes[i].icon, style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          changes[i].text,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Открывает markdown-документ (ToS / Privacy Policy) в DraggableBottomSheet.
  void _showLegalDoc(BuildContext context, {
    required String title,
    required String assetPath,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0A0E27),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (_, ctrl) => Column(
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 4),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Title bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 16, 12),
              child: Row(
                children: [
                  const Icon(Icons.article_outlined,
                      color: Color(0xFF00D9FF), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: GoogleFonts.orbitron(
                        color: const Color(0xFF00D9FF),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white38, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            // Markdown content
            Expanded(
              child: FutureBuilder<String>(
                future: rootBundle.loadString(assetPath),
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: Color(0xFF00D9FF)),
                    );
                  }
                  if (snap.hasError || !snap.hasData) {
                    return const Center(
                      child: Text('Не удалось загрузить документ',
                          style: TextStyle(color: Colors.white54)),
                    );
                  }
                  return Markdown(
                    controller: ctrl,
                    data: snap.data!,
                    styleSheet: MarkdownStyleSheet(
                      p:           const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
                      h1:          TextStyle(color: const Color(0xFF00D9FF),
                                       fontSize: 18, fontWeight: FontWeight.bold,
                                       fontFamily: GoogleFonts.orbitron().fontFamily),
                      h2:          const TextStyle(color: Colors.white,
                                       fontSize: 15, fontWeight: FontWeight.bold),
                      h3:          const TextStyle(color: Colors.white70,
                                       fontSize: 13, fontWeight: FontWeight.bold),
                      strong:      const TextStyle(color: Colors.white,
                                       fontWeight: FontWeight.bold),
                      em:          const TextStyle(color: Colors.white54,
                                       fontStyle: FontStyle.italic),
                      code:        const TextStyle(color: Color(0xFF00D9FF),
                                       backgroundColor: Color(0xFF0A1A2A),
                                       fontFamily: 'monospace', fontSize: 12),
                      blockquote:  const TextStyle(color: Colors.white54, fontSize: 12),
                      tableBody:   const TextStyle(color: Colors.white70, fontSize: 12),
                      tableHead:   const TextStyle(color: Colors.white,
                                       fontWeight: FontWeight.bold, fontSize: 12),
                      listBullet:  const TextStyle(color: Color(0xFF00D9FF)),
                      horizontalRuleDecoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: Color(0xFF1A2A4A), width: 1),
                        ),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

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

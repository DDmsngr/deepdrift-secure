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
  bool _autoSavePhotos     = false;
  bool _notificationsSound = true;
  String? _myPublicKeyFingerprint;
  bool _loadingFingerprint = false;

  @override
  void initState() {
    super.initState();
    _autoSavePhotos     = widget.storage.getSetting('auto_save_photos', defaultValue: false);
    _notificationsSound = widget.storage.getSetting('notifications_sound', defaultValue: true);
    _loadFingerprint();
  }

  Future<void> _loadFingerprint() async {
    setState(() => _loadingFingerprint = true);
    try {
      final x25519Key  = await widget.cipher.getMyPublicKey();
      final ed25519Key = await widget.cipher.getMySigningKey();
      // Fingerprint = первые 8 байт каждого ключа в hex-формате
      final combined   = '${x25519Key.substring(0, 8)}${ed25519Key.substring(0, 8)}';
      // Форматируем как группы по 4: XXXX XXXX XXXX XXXX
      final cleaned    = combined.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
      final groups     = <String>[];
      for (int i = 0; i < cleaned.length && groups.length < 8; i += 4) {
        final end = (i + 4 < cleaned.length) ? i + 4 : cleaned.length;
        groups.add(cleaned.substring(i, end));
      }
      setState(() {
        _myPublicKeyFingerprint = groups.join(' ');
        _loadingFingerprint     = false;
      });
    } catch (e) {
      setState(() {
        _myPublicKeyFingerprint = 'Error loading key';
        _loadingFingerprint     = false;
      });
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: const Color(0xFF1A4A2E)));
  }

  // ── Смена пароля ──────────────────────────────────────────────────────────

  void _showChangePasswordDialog() {
    final oldCtrl     = TextEditingController();
    final newCtrl     = TextEditingController();
    final confirmCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Change password', style: GoogleFonts.orbitron(fontSize: 14)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '⚠️ After changing, all sessions on other devices will need the new password.',
              style: TextStyle(color: Colors.orange, fontSize: 11),
            ),
            const SizedBox(height: 16),
            _passField(oldCtrl, 'Current password'),
            const SizedBox(height: 10),
            _passField(newCtrl, 'New password'),
            const SizedBox(height: 10),
            _passField(confirmCtrl, 'Confirm new password'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () async {
              final savedPwd = widget.storage.getSetting('user_password');
              if (oldCtrl.text != savedPwd) {
                _showError('Current password is incorrect');
                return;
              }
              if (newCtrl.text.length < 8) {
                _showError('New password must be at least 8 characters');
                return;
              }
              if (newCtrl.text != confirmCtrl.text) {
                _showError('New passwords do not match');
                return;
              }
              try {
                // Перешифровываем ключи с новым паролем
                final newKeys = await widget.cipher.exportBothKeys(newCtrl.text);
                await widget.storage.saveSetting('user_password', newCtrl.text);
                await widget.storage.saveSetting('encrypted_x25519_key', newKeys['x25519']!);
                await widget.storage.saveSetting('encrypted_ed25519_key', newKeys['ed25519']!);
                Navigator.pop(context);
                _showSuccess('Password changed successfully');
              } catch (e) {
                _showError('Error changing password: $e');
              }
            },
            child: const Text('CHANGE'),
          ),
        ],
      ),
    );
  }

  Widget _passField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      obscureText: true,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        filled: true, fillColor: const Color(0xFF0A0E27),
        border: const OutlineInputBorder(),
      ),
    );
  }

  // ── Fingerprint диалог ────────────────────────────────────────────────────

  void _showFingerprintDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Row(children: [
          const Icon(Icons.fingerprint, color: Colors.cyan, size: 20),
          const SizedBox(width: 8),
          Text('Security fingerprint', style: GoogleFonts.orbitron(fontSize: 13)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Compare this code with your contact in person or via another channel to verify no one is intercepting your messages.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
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
                    color: Colors.cyan, fontSize: 16, letterSpacing: 2),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Text('Your ID: ${widget.myUid}',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _myPublicKeyFingerprint ?? ''));
              _showSuccess('Fingerprint copied');
              Navigator.pop(context);
            },
            child: const Text('COPY'),
          ),
          ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CLOSE')),
        ],
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Settings', style: GoogleFonts.orbitron(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [

          // ── УВЕДОМЛЕНИЯ ─────────────────────────────────────────────────
          _sectionHeader('NOTIFICATIONS'),

          _switchTile(
            icon: Icons.volume_up_outlined,
            title: 'Sound',
            subtitle: 'Play sound for incoming messages',
            value: _notificationsSound,
            onChanged: (val) async {
              setState(() => _notificationsSound = val);
              await widget.storage.saveSetting('notifications_sound', val);
            },
          ),

          // ── МЕДИА ────────────────────────────────────────────────────────
          _sectionHeader('MEDIA'),

          _switchTile(
            icon: Icons.save_alt_outlined,
            title: 'Auto-save photos',
            subtitle: 'Automatically save incoming photos to gallery',
            value: _autoSavePhotos,
            onChanged: (val) async {
              setState(() => _autoSavePhotos = val);
              await widget.storage.saveSetting('auto_save_photos', val);
            },
          ),

          // ── БЕЗОПАСНОСТЬ ─────────────────────────────────────────────────
          _sectionHeader('SECURITY'),

          _actionTile(
            icon: Icons.lock_outline,
            title: 'Change encryption password',
            subtitle: 'Re-encrypt your keys with a new password',
            onTap: _showChangePasswordDialog,
          ),

          _actionTile(
            icon: Icons.fingerprint,
            iconColor: Colors.cyan,
            title: 'Security fingerprint',
            subtitle: _loadingFingerprint
                ? 'Loading...'
                : (_myPublicKeyFingerprint != null
                    ? '${_myPublicKeyFingerprint!.substring(0, 9)}...'
                    : 'Tap to view'),
            onTap: _loadingFingerprint ? null : _showFingerprintDialog,
          ),

          // ── О ПРИЛОЖЕНИИ ─────────────────────────────────────────────────
          _sectionHeader('ABOUT'),

          _infoTile(
            icon: Icons.badge_outlined,
            title: 'My ID',
            value: widget.myUid,
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.myUid));
              _showSuccess('ID copied');
            },
          ),

          _infoTile(
            icon: Icons.info_outline,
            title: 'Version',
            value: 'DDChat 1.0.0',
          ),

          _infoTile(
            icon: Icons.security,
            title: 'Encryption',
            value: 'X25519 + Ed25519 + AES-256',
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Вспомогательные виджеты ───────────────────────────────────────────────

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(title,
          style: const TextStyle(
              color: Colors.cyan, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
    );
  }

  Widget _switchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
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
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        value: value,
        onChanged: onChanged,
        activeColor: Colors.cyan,
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    Color iconColor = Colors.white54,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: iconColor, size: 22),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        trailing: onTap != null
            ? const Icon(Icons.chevron_right, color: Colors.white38, size: 20)
            : null,
        onTap: onTap,
      ),
    );
  }

  Widget _infoTile({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2D),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Icon(icon, color: Colors.white54, size: 22),
        title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 15)),
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

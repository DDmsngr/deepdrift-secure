import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:local_auth/local_auth.dart';

import '../storage_service.dart';

/// Экран блокировки с числовым PIN-кодом (4–12 цифр).
/// PIN хранится отдельно от пароля шифрования.
/// Показывается при возврате из фона если включена настройка 'app_lock_enabled'.
class LockScreen extends StatefulWidget {
  final StorageService storage;
  final VoidCallback   onUnlocked;

  const LockScreen({
    super.key,
    required this.storage,
    required this.onUnlocked,
  });

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen>
    with SingleTickerProviderStateMixin {

  String _entered = '';
  int    _failCount = 0;

  // Biometric
  final _localAuth     = LocalAuthentication();
  bool  _canBiometric  = false;
  bool  _bioChecked    = false;

  late AnimationController _shakeCtrl;
  late Animation<double>   _shakeAnim;

  // Длина ожидаемого PIN берётся из хранилища
  int get _pinLength {
    final pin = widget.storage.getSetting('app_lock_pin') as String? ?? '';
    return pin.length.clamp(4, 12);
  }

  String get _savedPin =>
      widget.storage.getSetting('app_lock_pin') as String? ?? '';

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _shakeAnim = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10.0, end: -10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 0.0),  weight: 1),
    ]).animate(_shakeCtrl);

    // Проверяем поддержку биометрии и запускаем автоматически если включена
    _checkBiometricAndAuthenticate();
  }

  Future<void> _checkBiometricAndAuthenticate() async {
    try {
      final canCheck  = await _localAuth.canCheckBiometrics;
      final supported = await _localAuth.isDeviceSupported();
      if (!mounted) return;
      setState(() => _canBiometric = canCheck && supported);
      if (_canBiometric) {
        // Небольшая задержка чтобы дать UI время отрисоваться
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted || _bioChecked) return;
        await _authenticateBiometric();
      }
    } catch (e) {
      debugPrint('Biometric check error: $e');
    }
  }

  Future<void> _authenticateBiometric() async {
    if (_bioChecked) return;
    _bioChecked = true;
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Разблокируй DDChat',
        options: const AuthenticationOptions(
          stickyAuth:  true,
          biometricOnly: false,
        ),
      );
      if (authenticated && mounted) {
        widget.onUnlocked();
      } else {
        if (mounted) setState(() => _bioChecked = false); // allow retry
      }
    } catch (e) {
      debugPrint('Biometric auth error: $e');
      if (mounted) setState(() => _bioChecked = false);
    }
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    super.dispose();
  }

  void _onDigit(String d) {
    if (_entered.length >= _pinLength) return;
    setState(() => _entered += d);
    if (_entered.length == _pinLength) {
      Future.delayed(const Duration(milliseconds: 100), _check);
    }
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _check() async {
    if (_entered == _savedPin) {
      widget.onUnlocked();
    } else {
      setState(() {
        _failCount++;
        _entered = '';
      });
      _shakeCtrl.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pinLen = _pinLength;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),

            // Иконка
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1A1F3C),
                border: Border.all(
                  color: const Color(0xFF00D9FF).withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: const Icon(Icons.lock_outline,
                  color: Color(0xFF00D9FF), size: 40),
            ),

            const SizedBox(height: 24),

            Text(
              'DDChat заблокирован',
              style: GoogleFonts.orbitron(
                color: Colors.white,
                fontSize: 16,
                letterSpacing: 1,
              ),
            ),

            const SizedBox(height: 6),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _failCount > 0
                    ? 'Неверный PIN — попытка $_failCount'
                    : (_canBiometric ? 'Введи PIN-код или используй биометрию' : 'Введи PIN-код'),
                key: ValueKey(_failCount),
                style: TextStyle(
                  color: _failCount > 0 ? Colors.red[300] : Colors.white38,
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
            ),

            const SizedBox(height: 32),

            // Точки ввода
            AnimatedBuilder(
              animation: _shakeAnim,
              builder: (ctx, child) => Transform.translate(
                offset: Offset(_shakeAnim.value, 0),
                child: child,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(pinLen, (i) {
                  final filled = i < _entered.length;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width:  16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled
                          ? const Color(0xFF00D9FF)
                          : Colors.white12,
                      border: Border.all(
                        color: filled
                            ? const Color(0xFF00D9FF)
                            : Colors.white24,
                        width: 1.5,
                      ),
                    ),
                  );
                }),
              ),
            ),

            const Spacer(flex: 1),

            // Клавиатура
            _buildKeypad(),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        children: [
          _keyRow(['1', '2', '3']),
          const SizedBox(height: 12),
          _keyRow(['4', '5', '6']),
          const SizedBox(height: 12),
          _keyRow(['7', '8', '9']),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Биометрия (если доступна) или пустое место
              SizedBox(
                width: 72,
                height: 72,
                child: _canBiometric
                    ? TextButton(
                        onPressed: () {
                          setState(() => _bioChecked = false);
                          _authenticateBiometric();
                        },
                        style: TextButton.styleFrom(
                          shape: const CircleBorder(),
                          foregroundColor: const Color(0xFF00D9FF),
                        ),
                        child: const Icon(Icons.fingerprint,
                            color: Color(0xFF00D9FF), size: 34),
                      )
                    : const SizedBox.shrink(),
              ),
              _digitKey('0'),
              // Стереть
              SizedBox(
                width: 72,
                height: 72,
                child: TextButton(
                  onPressed: _onBackspace,
                  style: TextButton.styleFrom(
                    shape: const CircleBorder(),
                    foregroundColor: Colors.white54,
                  ),
                  child: const Icon(Icons.backspace_outlined,
                      color: Colors.white54, size: 26),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _keyRow(List<String> digits) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: digits.map(_digitKey).toList(),
  );

  Widget _digitKey(String d) => SizedBox(
    width: 72,
    height: 72,
    child: TextButton(
      onPressed: () => _onDigit(d),
      style: TextButton.styleFrom(
        shape: const CircleBorder(),
        backgroundColor: const Color(0xFF1A1F3C),
        foregroundColor: Colors.white,
        overlayColor: const Color(0xFF00D9FF),
      ),
      child: Text(
        d,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w500,
          color: Colors.white,
        ),
      ),
    ),
  );
}

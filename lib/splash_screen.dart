import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'home_screen.dart';
import 'storage_service.dart';

// ── LockScreen — показывается только если app_lock_enabled == true ────────────
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _storage = StorageService();
  final _pinCtrl = TextEditingController();
  bool  _wrongPin = false;
  bool  _obscure  = true;

  void _tryUnlock() {
    final savedPwd = _storage.getSetting('user_password') as String?;
    if (_pinCtrl.text == savedPwd) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } else {
      setState(() { _wrongPin = true; _pinCtrl.clear(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, color: Color(0xFF00D9FF), size: 64),
                const SizedBox(height: 24),
                Text('DDChat', style: GoogleFonts.orbitron(
                  color: const Color(0xFF00D9FF), fontSize: 28, fontWeight: FontWeight.bold,
                )),
                const SizedBox(height: 8),
                const Text('Введи пароль для входа',
                    style: TextStyle(color: Colors.white54, fontSize: 14)),
                const SizedBox(height: 32),
                TextField(
                  controller: _pinCtrl,
                  obscureText: _obscure,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white, fontSize: 18, letterSpacing: 4),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF1A1F3C),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    hintText: '••••••••',
                    hintStyle: const TextStyle(color: Colors.white24),
                    errorText: _wrongPin ? 'Неверный пароль' : null,
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, color: Colors.white38),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) => _tryUnlock(),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _tryUnlock,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00D9FF),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('ВОЙТИ', style: GoogleFonts.orbitron(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── SplashScreen — проверяет нужен ли lock, потом переходит ──────────────────
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _storage = StorageService();

  @override
  void initState() {
    super.initState();
    _navigate();
  }

  Future<void> _navigate() async {
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;

    await _storage.init();
    final lockEnabled = _storage.getSetting('app_lock_enabled', defaultValue: false) as bool;
    final hasPwd = (_storage.getSetting('user_password') as String?) != null;

    Widget next;
    if (lockEnabled && hasPwd) {
      next = const LockScreen();
    } else {
      next = const HomeScreen();
    }

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, __, ___) => next,
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.chat_bubble, color: Color(0xFF00D9FF), size: 80),
            const SizedBox(height: 20),
            Text('DDChat', style: GoogleFonts.orbitron(
              color: const Color(0xFF00D9FF), fontSize: 32, fontWeight: FontWeight.bold,
            )),
            const SizedBox(height: 8),
            const Text('Secure Messenger',
                style: TextStyle(color: Colors.white38, fontSize: 14, letterSpacing: 2)),
            const SizedBox(height: 40),
            const SizedBox(
              width: 30, height: 30,
              child: CircularProgressIndicator(color: Color(0xFF00D9FF), strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

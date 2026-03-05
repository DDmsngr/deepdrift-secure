import 'dart:async';
import 'package:flutter/material.dart';
import 'home_screen.dart'; // Путь к твоему главному экрану

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    
    // Таймер на 3 секунды. 
    // Подбери время так, чтобы GIF успел проиграться до конца.
    Timer(const Duration(seconds: 3), () {
      // Плавно переходим на HomeScreen и удаляем Splash из истории (чтобы по кнопке "Назад" не вернуться сюда)
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 800), // Плавное затухание
          pageBuilder: (_, __, ___) => const HomeScreen(),
          transitionsBuilder: (_, animation, __, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Тот самый глубокий темный фон из промпта
      backgroundColor: const Color(0xFF0A0E27),
      body: Center(
        // Картинка подстроится под размер экрана
        child: Image.asset(
          'assets/splash.gif',
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          // Если гифка маленькая и нужно ее просто по центру, используй это вместо строк выше:
          // width: 300, 
        ),
      ),
    );
  }
}

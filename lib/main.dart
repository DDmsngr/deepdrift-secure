import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_core/firebase_core.dart';

import 'crypto_service.dart';
import 'notification_service.dart';
import 'providers/app_providers.dart';
import 'splash_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  try {
    await Firebase.initializeApp();
  } catch (_) {}

  await NotificationService().init();

  final cipher = SecureCipher();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CipherProvider(cipher)),
        ChangeNotifierProvider(create: (_) => SocketProvider()),
        ChangeNotifierProvider(create: (_) => StorageProvider()),
      ],
      child: MaterialApp(
        title: 'DDChat',
        debugShowCheckedModeBanner: false,
        navigatorKey: NotificationService.navigatorKey,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF0A0E27),
          colorScheme: const ColorScheme.dark(primary: Color(0xFF00D9FF)),
        ),
        home: const SplashScreen(),
      ),
    ),
  );
}

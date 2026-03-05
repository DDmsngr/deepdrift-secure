import 'package:flutter/material.dart';

/// Global theme mode notifier.
/// Change [appThemeMode.value] to switch the app theme dynamically.
/// Initialized to dark; main.dart reads the persisted setting on startup.
final ValueNotifier<ThemeMode> appThemeMode =
    ValueNotifier<ThemeMode>(ThemeMode.dark);

import 'package:flutter/material.dart';

/// App theme (spec §18 Appearance: light/dark/system).
ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4F6D7A));
  return ThemeData(colorScheme: scheme, useMaterial3: true);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4F6D7A),
    brightness: Brightness.dark,
  );
  return ThemeData(colorScheme: scheme, useMaterial3: true);
}

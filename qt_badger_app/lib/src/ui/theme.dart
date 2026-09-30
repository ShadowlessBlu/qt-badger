import 'package:flutter/material.dart';

/// Section colours - the same ones the badge's own TFT tiles use, so a screen on
/// the badge and its page in the app read as the same thing.
class Palette {
  static const cyan = Color(0xFF22D3EE); // Map
  static const green = Color(0xFF4ADE80); // Peers
  static const amber = Color(0xFFFBBF24); // Tasks
  static const purple = Color(0xFFC084FC); // Voice
  static const coral = Color(0xFFFB7185); // Alert
  static const slate = Color(0xFF94A3B8); // Settings
  static const gold = Color(0xFFFACC15); // Name tag
  static const sky = Color(0xFF7DD3FC); // Inbox
  static const danger = Color(0xFFEF4444);

  static const darkBg = Color(0xFF0B1220);
  static const darkCard = Color(0xFF16213A);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Palette.cyan,
    brightness: brightness,
  ).copyWith(surface: dark ? Palette.darkBg : null, surfaceContainerLow: dark ? Palette.darkCard : null);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? Palette.darkBg : null,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: dark ? Palette.darkCard : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.35 : 0.6)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF0F1A30) : null,
      indicatorColor: Palette.cyan.withValues(alpha: 0.22),
      labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? Colors.black.withValues(alpha: 0.25) : null,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    snackBarTheme: SnackBarThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 12)),
  );
}

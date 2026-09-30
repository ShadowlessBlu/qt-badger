import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'connect_page.dart';
import 'shell.dart';
import 'theme.dart';

final _lightTheme = buildTheme(Brightness.light);
final _darkTheme = buildTheme(Brightness.dark);

class BadgeApp extends StatelessWidget {
  const BadgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Only the theme mode and the "configured" flag matter here - the polling state changes every 1.5 s
    // and each page watches what it needs itself, so the root shouldn't rebuild for it.
    final themeMode = context.select<AppState, ThemeMode>((a) => a.themeMode);
    final configured = context.select<AppState, bool>((a) => a.settings.configured);
    final messengerKey = context.read<AppState>().messengerKey;
    return MaterialApp(
      title: 'QT BADGEr',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: themeMode,
      home: configured ? const Shell() : const ConnectPage(firstRun: true),
    );
  }
}

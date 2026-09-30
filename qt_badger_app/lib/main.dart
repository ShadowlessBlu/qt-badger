import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/services/app_settings.dart';
import 'src/state/app_state.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final app = AppState(settings, GlobalKey<ScaffoldMessengerState>());
  runApp(ChangeNotifierProvider<AppState>.value(value: app, child: const BadgeApp()));
  unawaited(app.start());
}

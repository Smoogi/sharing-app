import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'ui/home_screen.dart';
import 'ui/post_card.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  runApp(SmoogiApp(controller: controller, init: controller.init()));
}

class SmoogiApp extends StatelessWidget {
  const SmoogiApp({super.key, required this.controller, required this.init});
  final AppController controller;
  final Future<void> init;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smoogi Share',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light, BoardColors.light),
      darkTheme: _theme(Brightness.dark, BoardColors.dark),
      home: FutureBuilder<void>(
        future: init,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(
                body: Center(
                    child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText('Failed to start: ${snap.error}'),
            )));
          }
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          return HomeScreen(controller: controller);
        },
      ),
    );
  }
}

/// Imageboard look: flat bars, no rounded corners, Yotsuba-style colours.
ThemeData _theme(Brightness b, BoardColors c) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF34345C),
    brightness: b,
  ).copyWith(surface: c.page, primary: c.backlink);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.page,
    appBarTheme: AppBarTheme(
      backgroundColor: c.header,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: const CardThemeData(shape: RoundedRectangleBorder()),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.backlink,
        foregroundColor: b == Brightness.dark ? Colors.black : Colors.white,
        shape: const RoundedRectangleBorder(),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

import 'app/app_controller.dart';
import 'ui/home_screen.dart';

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
      theme: ThemeData(
          colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
          useMaterial3: true),
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
